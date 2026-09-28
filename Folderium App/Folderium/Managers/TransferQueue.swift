import Foundation
import Combine

// MARK: - TransferQueue: 依序批次、N 上限、狀態、JSON 保存與恢復
// PRD v1.3 §3.2/§3.3/§3.4/§3.5, §5 TransferQueue 責任。
// 單一 writer;同一時間只執行一個傳輸作業;不建立通用工作流引擎。

/// 目前作業的進度資訊(綁定該作業 stats group,不是 daemon 累計數字)
struct TransferProgress {
    var fileName: String?
    var percent: Double?
    var speedBytesPerSec: Int64?
    var etaSeconds: Int?
    var totalBytes: Int64?
    var transferredBytes: Int64?
    var transfersNow: Int = 0
    var totalTransfers: Int = 0
}

@MainActor
final class TransferQueue: ObservableObject {
    static let shared = TransferQueue()

    // MARK: Published

    @Published private(set) var batches: [QueueBatch] = []
    @Published private(set) var transfersLimit: Int = 2
    @Published private(set) var queuePaused: Bool = false
    @Published private(set) var storeError: String?
    /// 非 nil = 狀態待確認,全域派發封鎖(PRD §3.3:不可重送或派發下一作業)
    @Published private(set) var dispatchBlockedReason: String?
    @Published private(set) var currentProgress: TransferProgress?
    @Published private(set) var progressNote: String?
    @Published var engineError: String?

    private var pollTimer: Timer?
    private let store = QueueStore()
    private var currentJobID: Int64?
    private var currentJobGroup: String?
    private var currentBatchID: UUID?

    private init() {
        loadAtStartup()
    }

    // MARK: Startup (PRD §3.4 rules 4–6)

    private func loadAtStartup() {
        do {
            let doc = try store.load()
            batches = doc.batches
            transfersLimit = min(max(doc.transfersLimit, 1), 4)
            queuePaused = doc.queuePaused
            for i in batches.indices {
                switch batches[i].state {
                case .running, .stopping:
                    // 舊「執行中/停止中」一律降級為待恢復,不自動開始寫入
                    batches[i].state = .waiting
                    batches[i].runtimeJobID = nil
                    batches[i].runtimeJobGroup = nil
                    batches[i].lastError = "上次 App 結束時未完成,已列為待恢復(依執行時來源內容處理)"
                default:
                    break
                }
            }
        } catch {
            // 損毀/不支援 schema:保留原檔、提示、停止派發,不覆寫
            storeError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            dispatchBlockedReason = "queue.json 讀取失敗,佇列已停止派發"
        }
        schedulePreviousEngineCheck()
    }

    /// 啟動時先檢查前次 App 自有 rclone 是否仍存活(PRD §3.4 規則 6)。
    /// 存活/無法確認 → 封鎖派發,待使用者確認;不可自動接管或直接恢復。
    private func schedulePreviousEngineCheck() {
        Task.detached { [weak self] in
            guard let self else { return }
            let state = RcloneDaemon.shared.checkPreviousEngine()
            await MainActor.run {
                switch state {
                case .none:
                    break
                case .aliveOurs, .ambiguous:
                    if self.dispatchBlockedReason == nil {
                        self.dispatchBlockedReason = "偵測到前次引擎可能仍在寫入,請先確認引擎狀態後再繼續"
                    }
                }
            }
        }
    }

    var hasRecoverableWork: Bool {
        batches.contains { $0.state == .waiting || $0.state == .paused || $0.state == .needsAttention }
    }

    /// 使用者明確「繼續」:恢復未完成工作(重新執行,不是原地續傳)
    func userResume() {
        if dispatchBlockedReason != nil {
            engineError = "佇列仍處於「狀態待確認」:\(dispatchBlockedReason ?? "")"
            return
        }
        queuePaused = false
        for i in batches.indices where batches[i].state == .paused {
            batches[i].state = .waiting
        }
        persistLocked(reason: "user-resume") { ok in
            if ok { self.maybeDispatch() } else {
                self.engineError = "保存失敗,未開始派發"
            }
        }
    }

    // MARK: Add batch (PRD §3.2:加入時固定來源/目的地/項目/策略)

    /// 回傳 nil = 成功;非 nil = 使用者可見錯誤
    func addBatch(sourceParent: URL,
                  items: [(url: URL, isDirectory: Bool)],
                  destination: URL,
                  strategy: ConflictStrategy) -> String? {
        guard items.contains(where: { !$0.isDirectory }) || items.contains(where: { $0.isDirectory }) else {
            return "沒有可複製的項目"
        }

        // §4.3 寫入保護:以實際位置判斷
        for item in items {
            if let err = PathProtection.validate(source: item.url, destination: destination) {
                return err.localizedDescription
            }
        }

        // §4.2 符號連結:不跟隨、不靜默;列為不支援
        var batchItems: [BatchItem] = []
        for item in items {
            let resolved = item.url.resolvingSymlinksInPath()
            let isSymlink = resolved.path != item.url.standardizedFileURL.path
                || (try? item.url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            if isSymlink {
                batchItems.append(BatchItem(
                    id: UUID(), sourcePath: item.url.path,
                    itemName: item.url.lastPathComponent, isDirectory: item.isDirectory,
                    itemState: .unsupported, lastError: "符號連結不支援複製"))
                continue
            }
            batchItems.append(BatchItem(
                id: UUID(), sourcePath: item.url.path,
                itemName: item.url.lastPathComponent, isDirectory: item.isDirectory,
                itemState: .pending, lastError: nil))
        }

        let batch = QueueBatch(
            batchId: UUID(),
            createdAt: Date(),
            sourceParent: sourceParent.standardizedFileURL.path,
            destination: destination.standardizedFileURL.path,
            strategy: strategy,
            state: .waiting,
            items: batchItems,
            lastError: nil,
            sourceVolumeToken: PathProtection.volumeToken(for: sourceParent),
            destVolumeToken: PathProtection.volumeToken(for: destination),
            runtimeJobID: nil,
            runtimeJobGroup: nil,
            results: BatchResults(),
            runtimeNotedAtAdd: true
        )

        // 保存成功才入列;保存失敗不把新工作當成已記住
        var candidate = batches
        candidate.append(batch)
        do {
            try store.save(document(with: candidate))
        } catch {
            storeError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return "佇列保存失敗,此批次未加入:\(storeError ?? "")"
        }
        batches = candidate
        storeError = nil
        maybeDispatch()
        return nil
    }

    // MARK: Settings

    /// N 調整(1~4):從下一個作業生效
    func setTransfersLimit(_ n: Int) {
        let clamped = min(max(n, 1), 4)
        guard clamped != transfersLimit else { return }
        transfersLimit = clamped
        persistLocked(reason: "set-n") { _ in }
    }

    // MARK: Pause (PRD §3.3:停止派發 + 請求停止目前作業)

    func pauseQueue() {
        guard !queuePaused else { return }
        queuePaused = true
        if let idx = indexOfRunningBatch() {
            batches[idx].state = .stopping
            let jobID = currentJobID
            persistLocked(reason: "pause-request") { _ in }
            Task.detached { [weak self] in
                guard let self, let jobID else { return }
                let confirmed = RcloneDaemon.shared.requestJobStop(jobID: jobID)
                    && RcloneDaemon.shared.confirmTerminated(jobID: jobID, timeout: 12)
                await MainActor.run {
                    self.finishPause(confirmed: confirmed)
                }
            }
        } else {
            persistLocked(reason: "pause-idle") { _ in }
        }
    }

    private func finishPause(confirmed: Bool) {
        guard let idx = indexOfStoppingBatch() else { return }
        if confirmed {
            batches[idx].state = .paused
            batches[idx].runtimeJobID = nil
            batches[idx].runtimeJobGroup = nil
            stopPolling()
            currentJobID = nil
            currentJobGroup = nil
            currentBatchID = nil
            currentProgress = nil
            persistLocked(reason: "paused") { _ in }
        } else {
            batches[idx].state = .needsAttention
            batches[idx].lastError = "停止要求無法確認終止,狀態待確認"
            dispatchBlockedReason = "停止後無法確認引擎作業終止"
            stopPolling()
            persistLocked(reason: "stop-unconfirmed") { _ in }
        }
    }

    // MARK: 需處理 → 重試(PRD §3.3:手動重試,不自製重試排程器)

    func retryBatch(_ batchID: UUID) {
        guard dispatchBlockedReason == nil else {
            engineError = "佇列處於「狀態待確認」,請先確認引擎狀態"
            return
        }
        guard let idx = batches.firstIndex(where: { $0.batchId == batchID }) else { return }
        guard batches[idx].state == .needsAttention || batches[idx].state == .paused else { return }
        batches[idx].state = .waiting
        batches[idx].lastError = nil
        persistLocked(reason: "retry") { ok in
            if ok { self.maybeDispatch() }
        }
    }

    // MARK: 移除/清空(不刪除已複製檔案)

    func removeWaitingBatch(_ batchID: UUID) {
        guard let idx = batches.firstIndex(where: { $0.batchId == batchID }),
              batches[idx].state == .waiting || batches[idx].state == .paused || batches[idx].state == .needsAttention || batches[idx].state == .done else { return }
        var next = batches
        next.remove(at: idx)
        do {
            try store.save(document(with: next))
            batches = next
        } catch {
            storeError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        // 狀態待確認時,移除等待批次不解除派發封鎖(PRD §3.3)
    }

    func clearFinished() {
        var next = batches
        next.removeAll { $0.state == .done }
        do {
            try store.save(document(with: next))
            batches = next
        } catch {
            storeError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: 狀態待確認解除(PRD §3.3:查得原作業已終止或引擎已退出)

    /// 查 job/list:引擎無 running job → 所有作業已終止 → 解除封鎖。
    /// 前次引擎存在時先 reconcile(停止 jobs → 確認終止 → 結束前次程序)。
    func resolveBlockedState() {
        guard dispatchBlockedReason != nil else { return }
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                // 前次引擎仍存活 → 先請求停止與終止確認
                if let leftover = RcloneDaemon.shared.reconcilePreviousEngine() {
                    let reason: String
                    switch leftover {
                    case .ambiguous:
                        reason = "前次引擎無法確認身分或存活狀態;已保留待確認狀態,不接管"
                    case .aliveOurs, .none:
                        reason = "前次引擎停止確認失敗"
                    }
                    await MainActor.run { self.engineError = reason }
                    return
                }
                try RcloneDaemon.shared.ensureRunning()
                let jobs = try RcloneDaemon.shared.listJobs()
                await MainActor.run {
                    if jobs.running.isEmpty {
                        self.dispatchBlockedReason = nil
                        self.engineError = nil
                        // 停止中/待處理批次回等待
                        for i in self.batches.indices where self.batches[i].state == .stopping {
                            self.batches[i].state = .paused
                        }
                        self.persistLocked(reason: "unblock") { ok in
                            if ok { self.maybeDispatch() }
                        }
                    } else {
                        self.engineError = "引擎仍有 \(jobs.running.count) 個執行中作業,無法解除"
                    }
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                await MainActor.run { self.engineError = msg }
            }
        }
    }

    // MARK: Dispatch(單一作業;啟動前檢查全部通過才派發)

    private func indexOfRunningBatch() -> Int? {
        batches.firstIndex(where: { $0.state == .running || $0.state == .stopping })
    }

    private func indexOfStoppingBatch() -> Int? {
        batches.firstIndex(where: { $0.state == .stopping })
    }

    private func maybeDispatch() {
        guard dispatchBlockedReason == nil else { return }
        guard !queuePaused else { return }
        guard indexOfRunningBatch() == nil else { return }
        guard currentJobID == nil else { return }
        guard let idx = batches.firstIndex(where: { $0.state == .waiting && !$0.pendingItems.isEmpty || $0.state == .waiting && !$0.items.isEmpty }) else { return }

        let batch = batches[idx]
        guard !batch.pendingItems.isEmpty else {
            // 全部項目已完成或不支援 → 直接結算
            finalize(batchID: batch.batchId, jobError: nil)
            return
        }

        // 啟動前檢查(PRD §4.3):來源/目的地仍可存取 + 卷宗核對
        if let problem = preflight(batch: batch) {
            batches[idx].state = .needsAttention
            batches[idx].lastError = problem
            persistLocked(reason: "preflight-fail") { _ in }
            return
        }

        batches[idx].state = .running
        let saved = persistLocked(reason: "dispatch") { _ in }
        guard saved else {
            // 保存失敗 → 不可啟動該作業
            if let i = batches.firstIndex(where: { $0.batchId == batch.batchId }) {
                batches[i].state = .needsAttention
                batches[i].lastError = "派發前保存失敗,未啟動"
            }
            return
        }

        let limit = transfersLimit
        let jobSpec = buildJobSpec(batch: batch)
        Task.detached { [weak self] in
            guard let self else { return }
            await self.runJob(batchID: batch.batchId, spec: jobSpec, transfersLimit: limit)
        }
    }

    /// 啟動/恢復前路徑與掛載核對
    private func preflight(batch: QueueBatch) -> String? {
        let srcParent = URL(fileURLWithPath: batch.sourceParent)
        let dst = URL(fileURLWithPath: batch.destination)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: srcParent.path, isDirectory: &isDir), isDir.boolValue else {
            return "來源目錄無法存取:\(srcParent.path)"
        }
        guard FileManager.default.fileExists(atPath: dst.path, isDirectory: &isDir), isDir.boolValue else {
            return "目的地無法存取(不自動建立替代目錄):\(dst.path)"
        }
        // 卷宗核對:同路徑再次存在不代表原裝置
        if let token = batch.destVolumeToken, PathProtection.volumeToken(for: dst) != token {
            return "目的地卷宗識別與加入時不同,請重新確認位置"
        }
        if let token = batch.sourceVolumeToken, PathProtection.volumeToken(for: srcParent) != token {
            return "來源卷宗識別與加入時不同,請重新確認位置"
        }
        // 再套用路徑保護(§4.3:恢復前重新套用)
        for item in batch.items where item.itemState == .pending {
            if let err = PathProtection.validate(source: URL(fileURLWithPath: item.sourcePath), destination: dst) {
                return err.localizedDescription
            }
        }
        return nil
    }

    // MARK: Job 規格組裝(PRD §3.5:合併單作業;只複製選取項目)

    struct JobSpec {
        var srcFs: String
        var dstFs: String
        var includeRules: [String]   // rclone filter IncludeRule
        var ignoreExisting: Bool
        var pendingDirs: [String]    // 相對路徑(空目錄補建用)
        var pendingFiles: [String]
    }

    private func buildJobSpec(batch: QueueBatch) -> JobSpec {
        let srcParent = batch.sourceParent
        var includes: [String] = []
        var dirs: [String] = []
        var files: [String] = []
        for item in batch.items where item.itemState == .pending {
            let rel = item.sourcePath.hasPrefix(srcParent + "/")
                ? String(item.sourcePath.dropFirst(srcParent.count + 1))
                : item.itemName
            if item.isDirectory {
                includes.append("/" + rel)        // 目錄本身
                includes.append("/" + rel + "/**") // 目錄內容
                dirs.append(rel)
            } else {
                includes.append("/" + rel)
                files.append(rel)
            }
        }
        return JobSpec(
            srcFs: srcParent,
            dstFs: batch.destination,
            includeRules: includes,
            ignoreExisting: batch.strategy == .addOnly,
            pendingDirs: dirs,
            pendingFiles: files
        )
    }

    // MARK: Job 執行(背景;nonisolated,透過 await MainActor.run 更新狀態)

    nonisolated private func runJob(batchID: UUID, spec: JobSpec, transfersLimit: Int) async {
        do {
            try RcloneDaemon.shared.ensureRunning()

            // 記錄啟動前 job 快照(啟動回應遺失時比對用;App 專屬引擎單 writer)
            let before = try RcloneDaemon.shared.listJobs()
            let beforeIDs = Set(before.running).union(before.finished)

            var config: [String: Any] = [
                "Transfers": transfersLimit,
                "CreateEmptySrcDirs": true,   // 打包版本若不支援則由 App 補建(見 createMissingEmptyDirs)
            ]
            if spec.ignoreExisting {
                config["IgnoreExisting"] = true
            }
            let filter: [String: Any] = [
                "IncludeRule": spec.includeRules,
                "ExcludeRule": ["*"],
            ]
            let params: [String: Any] = [
                "srcFs": spec.srcFs,
                "dstFs": spec.dstFs,
                "_config": config,
                "_filter": filter,
            ]

            let resp = try RcloneDaemon.shared.post("sync/copy", params: params, async: true)

            var jobID: Int64?
            if let json = resp.json, let id = json["jobid"] as? Int {
                jobID = Int64(id)
            } else {
                // 啟動要求已送出但回應遺失/失敗:不得當成「未開始」。
                // 比對 job 快照找出新作業;找不到才視為未啟動。
                try? await Task.sleep(nanoseconds: 500_000_000)
                let after = try RcloneDaemon.shared.listJobs()
                let newIDs = Set(after.running).union(after.finished).subtracting(beforeIDs)
                if let first = newIDs.sorted().first {
                    jobID = Int64(first)
                }
                if jobID == nil, let err = resp.errorText {
                    throw NSError(domain: "folderium.job", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "啟動失敗:\(err)"])
                }
                if jobID == nil && resp.httpStatus == 0 {
                    // 連線層失敗:無法證明引擎沒收到 → 狀態待確認
                    await MainActor.run {
                        self.markUnconfirmed(batchID: batchID, reason: "啟動請求回應遺失,無法確認引擎是否已開始")
                    }
                    return
                }
            }

            guard let jobID else { return }
            let group = "job/\(jobID)"
            await MainActor.run {
                self.currentJobID = jobID
                self.currentJobGroup = group
                self.currentBatchID = batchID
                if let i = self.batches.firstIndex(where: { $0.batchId == batchID }) {
                    self.batches[i].runtimeJobID = jobID
                    self.batches[i].runtimeJobGroup = group
                }
                self.startPolling()
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            await MainActor.run {
                self.markJobFailed(batchID: batchID, message: msg, terminal: true)
            }
        }
    }

    // MARK: 輪詢(約 500ms;沒工作時停止)

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 0.5, target: self, selector: #selector(pollTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @objc private func pollTick() {
        guard let jobID = currentJobID,
              let batchID = currentBatchID else {
            stopPolling()
            return
        }
        let jobGroup = currentJobGroup
        Task.detached { [weak self] in
            guard let self else { return }
            let status = RcloneDaemon.shared.jobStatus(jobID: jobID)
            let stats = jobGroup.flatMap { RcloneDaemon.shared.stats(forGroup: $0) }
            await MainActor.run {
                if let status {
                    self.updateProgress(stats: stats)
                    if status.finished {
                        self.finalize(batchID: batchID, jobError: status.error)
                    }
                } else if RcloneDaemon.shared.currentIdentity() == nil {
                    // 引擎程序退出:作業已終止
                    self.finalize(batchID: batchID, jobError: "引擎程序已退出,作業未完成")
                }
            }
        }
    }

    private func updateProgress(stats: [String: Any]?) {
        guard let stats else {
            progressNote = "掃描中"
            return
        }
        var p = TransferProgress()
        p.totalBytes = (stats["totalBytes"] as? Int64) ?? (stats["totalBytes"] as? Double).map(Int64.init)
        p.transferredBytes = (stats["bytes"] as? Int64) ?? (stats["bytes"] as? Double).map(Int64.init)
        p.speedBytesPerSec = (stats["speed"] as? Int64) ?? (stats["speed"] as? Double).map(Int64.init)
        p.totalTransfers = (stats["totalTransfers"] as? Int) ?? 0
        p.transfersNow = (stats["transfers"] as? Int) ?? 0
        if let eta = stats["eta"] as? Double { p.etaSeconds = Int(eta) }
        if let total = p.totalBytes, total > 0, let done = p.transferredBytes {
            p.percent = Double(done) / Double(total) * 100.0
        }
        // 目前傳輸檔名:stats 的 transferring 欄位(若有)
        if let transferring = stats["transferring"] as? [[String: Any]],
           let firstName = transferring.first?["name"] as? String {
            p.fileName = firstName
        }
        if p.totalTransfers == 0 && p.transferredBytes == nil {
            progressNote = "掃描中"
            currentProgress = nil
        } else {
            progressNote = nil
            currentProgress = p
        }
    }

    // MARK: 終態結算

    private func markUnconfirmed(batchID: UUID, reason: String) {
        guard let i = batches.firstIndex(where: { $0.batchId == batchID }) else { return }
        batches[i].state = .needsAttention
        batches[i].lastError = "需處理:狀態待確認 — \(reason)"
        dispatchBlockedReason = reason
        stopPolling()
        persistLocked(reason: "unconfirmed") { _ in }
    }

    private func markJobFailed(batchID: UUID, message: String, terminal: Bool) {
        guard let i = batches.firstIndex(where: { $0.batchId == batchID }) else { return }
        batches[i].state = .needsAttention
        batches[i].lastError = message
        if terminal {
            stopPolling()
            currentJobID = nil
            currentJobGroup = nil
            currentBatchID = nil
            currentProgress = nil
        }
        persistLocked(reason: "job-failed") { _ in }
    }

    private func finalize(batchID: UUID, jobError: String?) {
        stopPolling()
        currentJobID = nil
        currentJobGroup = nil
        currentProgress = nil
        progressNote = nil
        guard let i = batches.firstIndex(where: { $0.batchId == batchID }) else { return }

        if let jobError {
            // 引擎錯誤:不宣稱成功;項目保持 pending 供重試
            batches[i].state = .needsAttention
            batches[i].lastError = jobError
            batches[i].runtimeJobID = nil
            batches[i].runtimeJobGroup = nil
            persistLocked(reason: "finalize-error") { _ in }
            return
        }

        // 成功:結算項目狀態
        let batch = batches[i]
        var results = BatchResults()
        results.unsupported = batch.items.filter { $0.itemState == .unsupported }.count
        let dstURL = URL(fileURLWithPath: batch.destination)

        for j in batches[i].items.indices {
            switch batches[i].items[j].itemState {
            case .unsupported:
                continue
            case .done, .failed, .skippedSameName:
                continue
            case .pending:
                let item = batches[i].items[j]
                let destPath = dstURL.appendingPathComponent(item.itemName)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: destPath.path, isDirectory: &isDir) {
                    batches[i].items[j].itemState = .done
                } else {
                    batches[i].items[j].itemState = .failed
                    batches[i].items[j].lastError = "引擎成功但目的地未出現此項目"
                }
            }
        }
        results.copied = batches[i].items.filter { $0.itemState == .done }.count
        results.failed = batches[i].items.filter { $0.itemState == .failed }.count

        // 只新增策略的略過計數:目的地已存在者(引擎 IgnoreExisting 略過)= done 但無新位元組;
        // 無法從引擎取得精確略過數 → 如實標示(§3.5)
        if batch.strategy == .addOnly {
            let preexisting = batches[i].items.filter { item in
                guard item.itemState == .done else { return false }
                let destPath = dstURL.appendingPathComponent(item.itemName)
                return FileManager.default.fileExists(atPath: destPath.path)
            }.count
            // 引擎不回報哪些被略過;顯示引擎判定無須傳輸的總數(誠實上限)
            results.engineNoTransfer = preexisting
        }

        batches[i].results = results
        batches[i].runtimeJobID = nil
        batches[i].runtimeJobGroup = nil

        // 空目錄補建(RC CreateEmptySrcDirs 實測不生效,App 自行建立)
        createMissingEmptyDirs(batch: batches[i])

        if results.failed > 0 {
            batches[i].state = .needsAttention
            batches[i].lastError = "\(results.failed) 個項目未出現在目的地"
        } else {
            batches[i].state = .done
            batches[i].lastError = nil
        }
        currentBatchID = nil
        persistLocked(reason: "finalize") { ok in
            _ = ok
            self.maybeDispatch()
        }
    }

    /// 遞迴找出選取目錄內的空目錄(含隱藏),在目的地對應建立。
    /// 背景佇列執行,不阻塞主執行緒。
    private func createMissingEmptyDirs(batch: QueueBatch) {
        let fm = FileManager.default
        let srcParent = URL(fileURLWithPath: batch.sourceParent)
        let dst = URL(fileURLWithPath: batch.destination)
        for item in batch.items where item.isDirectory && item.itemState != .unsupported {
            let srcDir = srcParent.appendingPathComponent(item.itemName)
            let dstDir = dst.appendingPathComponent(item.itemName)
            createEmptyDirsRecursively(src: srcDir, dst: dstDir, fm: fm)
            // 選取目錄本身若為空也補建
            if let contents = try? fm.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil), contents.isEmpty {
                try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
            }
        }
    }

    private func createEmptyDirsRecursively(src: URL, dst: URL, fm: FileManager) {
        guard let children = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for child in children {
            guard let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory, isDir else { continue }
            let childDst = dst.appendingPathComponent(child.lastPathComponent)
            try? fm.createDirectory(at: childDst, withIntermediateDirectories: true)
            createEmptyDirsRecursively(src: child, dst: childDst, fm: fm)
        }
    }

    // MARK: Persistence helpers

    private func document(with list: [QueueBatch]) -> QueueDocument {
        QueueDocument(
            schemaVersion: QueueStore.schemaVersion,
            transfersLimit: transfersLimit,
            queuePaused: queuePaused,
            batches: list
        )
    }

    /// 序列化保存;回傳是否成功
    @discardableResult
    private func persistLocked(reason: String, then: @escaping (Bool) -> Void) -> Bool {
        let doc = document(with: batches)
        do {
            try store.save(doc)
            storeError = nil
            then(true)
            return true
        } catch {
            storeError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            then(false)
            return false
        }
    }

    // MARK: App 退出(PRD §4.4)

    func prepareForAppExit() -> Bool {
        if let jobID = currentJobID {
            let confirmed = RcloneDaemon.shared.shutdown(currentJobID: jobID)
            // 停止未確認仍保存現況(不宣稱已停止)
            persistLocked(reason: "app-exit") { _ in }
            return confirmed
        }
        RcloneDaemon.shared.shutdown(currentJobID: nil)
        persistLocked(reason: "app-exit") { _ in }
        return true
    }
}
