import Foundation
import Combine

// MARK: - TransferQueue: 依序批次、N 上限、狀態、JSON 保存與恢復
// PRD v1.3 §3.2/§3.3/§3.4/§3.5 + Leon 2026-09-29 需求:
//   1) 加入佇列不自動開始;按「啟動」才派發,「暫停」停止。
//   2) 停止/中斷時偵測「只傳一半」的檔案並明確提醒。
//   3) 再次啟動從未完成處接續:已完成/已略過不重傳,partial 檔重傳。
//   4) N(同時傳輸檔案數 1~4)可設定,下一個作業生效。
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
    /// 使用者是否已按「啟動」。App 重開後一律 false(不自動開始寫入)。
    @Published private(set) var queueStarted: Bool = false
    @Published private(set) var storeError: String?
    /// 非 nil = 狀態待確認,全域派發封鎖(PRD §3.3:不可重送或派發下一作業)
    @Published private(set) var dispatchBlockedReason: String?
    @Published private(set) var currentProgress: TransferProgress?
    @Published private(set) var progressNote: String?
    @Published var engineError: String?
    /// 停止/中斷後的「只傳一半」提醒(檔名列表,供 UI 顯著提示)
    @Published private(set) var partialNotice: String?

    private let store = QueueStore()
    private var currentJobID: Int64?
    private var currentJobGroup: String?
    private var currentBatchID: UUID?
    /// 停止當下引擎正在傳的檔名(core/stats transferring;停止後 rclone 會清掉自己的 .partial 暫存,須先記住)
    private var inFlightNames: Set<String> = []

    private init() {
        loadAtStartup()
    }

    // MARK: Startup (PRD §3.4 rules 4–6)

    private func loadAtStartup() {
        do {
            let doc = try store.load()
            batches = doc.batches
            transfersLimit = min(max(doc.transfersLimit, 1), 4)
            for i in batches.indices {
                switch batches[i].state {
                case .running, .stopping:
                    // 舊「執行中/停止中」一律降級為待恢復,不自動開始寫入
                    batches[i].state = .waiting
                    batches[i].runtimeJobID = nil
                    batches[i].runtimeJobGroup = nil
                    batches[i].lastError = "上次 App 結束時未完成,按「啟動」接續(已完成檔案不重傳)"
                default:
                    break
                }
            }
            // 重開後:若有只傳一半的項目,組提醒
            refreshPartialNotice()
        } catch {
            // 損毀/不支援 schema:保留原檔、提示、停止派發,不覆寫
            storeError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            dispatchBlockedReason = "queue.json 讀取失敗,佇列已停止派發"
        }
        queueStarted = false
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
                        self.dispatchBlockedReason = "偵測到前次引擎可能仍在寫入,請先確認引擎狀態後再啟動"
                    }
                }
            }
        }
    }

    // MARK: Work availability

    /// 有可派發工作(等待/暫停批次含 pending 或 partial 項目)
    var hasDispatchableWork: Bool {
        batches.contains { batch in
            guard batch.state == .waiting else { return false }
            return batch.items.contains { $0.itemState == .pending || $0.itemState == .partial }
        }
    }

    var hasAnyUndoneWork: Bool {
        batches.contains { batch in
            batch.state != .done && batch.items.contains { $0.itemState == .pending || $0.itemState == .partial }
        }
    }

    // MARK: 啟動 / 暫停(Leon 需求:手動啟動;暫停可接續)

    /// 「啟動」:開始派發。暫停批次回等待;只傳一半的項目接續重傳。
    func startQueue() {
        if dispatchBlockedReason != nil {
            engineError = "佇列仍處於「狀態待確認」:\(dispatchBlockedReason ?? "")"
            return
        }
        for i in batches.indices where batches[i].state == .paused {
            batches[i].state = .waiting
        }
        queueStarted = true
        persistLocked(reason: "start") { ok in
            if ok { self.maybeDispatch() } else {
                self.engineError = "保存失敗,未開始派發"
            }
        }
    }

    /// 「暫停」:停止派發後續工作,並請求停止目前作業;確認前顯示「停止中」。
    func pauseQueue() {
        guard queueStarted else { return }
        queueStarted = false
        if let idx = indexOfRunningBatch() {
            batches[idx].state = .stopping
            let jobID = currentJobID
            persistLocked(reason: "pause-request") { _ in }
            Task.detached { [weak self] in
                guard let self else { return }
                // Swift 6: compute into a local let, no captured var mutation.
                let confirmed: Bool
                if let jobID {
                    confirmed = RcloneDaemon.shared.requestJobStop(jobID: jobID)
                        && RcloneDaemon.shared.confirmTerminated(jobID: jobID, timeout: 12)
                } else {
                    confirmed = true
                }
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
            currentJobID = nil
            currentJobGroup = nil
            currentBatchID = nil
            currentProgress = nil
            progressNote = nil
            // 停止結算:標記只傳一半 + 已完成項目
            let outcome = markOutcomesAfterStop(batchIndex: idx)
            batches[idx].lastError = outcome.summaryText ?? "已暫停;再按「啟動」可接續(已完成檔案不重傳)"
            partialNotice = outcome.noticeText
            persistLocked(reason: "paused") { _ in }
        } else {
            batches[idx].state = .needsAttention
            batches[idx].lastError = "停止要求無法確認終止,狀態待確認"
            dispatchBlockedReason = "停止後無法確認引擎作業終止"
            persistLocked(reason: "stop-unconfirmed") { _ in }
        }
    }

    // MARK: Add batch(PRD §3.2:加入時固定來源/目的地/項目/策略;不自動啟動)

    /// 回傳 nil = 成功;非 nil = 使用者可見錯誤
    func addBatch(sourceParent: URL,
                  items: [(url: URL, isDirectory: Bool)],
                  destination: URL,
                  strategy: ConflictStrategy) -> String? {
        guard !items.isEmpty else {
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
            preExistingRelPaths: nil,
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
        // 不自動啟動;若佇列已在執行中,新批次自然依序派發
        if queueStarted {
            maybeDispatch()
        }
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
            if ok, self.queueStarted { self.maybeDispatch() }
        }
    }

    // MARK: 移除/清空(不刪除已複製檔案)

    func removeWaitingBatch(_ batchID: UUID) {
        guard let idx = batches.firstIndex(where: { $0.batchId == batchID }),
              batches[idx].state != .running && batches[idx].state != .stopping else { return }
        var next = batches
        next.remove(at: idx)
        do {
            try store.save(document(with: next))
            batches = next
            refreshPartialNotice()
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
            refreshPartialNotice()
        } catch {
            storeError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: 狀態待確認解除(PRD §3.3:查得原作業已終止或引擎已退出)

    func resolveBlockedState() {
        guard dispatchBlockedReason != nil else { return }
        Task.detached { [weak self] in
            guard let self else { return }
            do {
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
                        for i in self.batches.indices where self.batches[i].state == .stopping {
                            self.batches[i].state = .paused
                        }
                        self.persistLocked(reason: "unblock") { _ in }
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

    // MARK: Dispatch(單一作業鏈;啟動前檢查全部通過才派發)

    private func indexOfRunningBatch() -> Int? {
        batches.firstIndex(where: { $0.state == .running || $0.state == .stopping })
    }

    private func indexOfStoppingBatch() -> Int? {
        batches.firstIndex(where: { $0.state == .stopping })
    }

    private func maybeDispatch() {
        guard dispatchBlockedReason == nil else { return }
        guard queueStarted else { return }   // 未按啟動 → 不派發
        guard indexOfRunningBatch() == nil else { return }
        guard currentJobID == nil else { return }
        guard let idx = batches.firstIndex(where: {
            $0.state == .waiting && $0.items.contains { $0.itemState == .pending || $0.itemState == .partial }
        }) else { return }

        let batch = batches[idx]

        // 啟動前檢查(PRD §4.3):來源/目的地仍可存取 + 卷宗核對
        if let problem = preflight(batch: batch) {
            batches[idx].state = .needsAttention
            batches[idx].lastError = problem
            persistLocked(reason: "preflight-fail") { _ in }
            return
        }

        // 記錄「派發時目的地已存在」的項目:之後停止時只把「不在清單但出現」的當成我們的半成品
        let dstURL = URL(fileURLWithPath: batch.destination)
        batches[idx].preExistingRelPaths = batch.items
            .filter { FileManager.default.fileExists(atPath: dstURL.appendingPathComponent($0.itemName).path) }
            .map { $0.itemName }
        batches[idx].state = .running
        let saved = persistLocked(reason: "dispatch") { _ in }
        guard saved else {
            if let i = batches.firstIndex(where: { $0.batchId == batch.batchId }) {
                batches[i].state = .needsAttention
                batches[i].lastError = "派發前保存失敗,未啟動"
            }
            return
        }

        let limit = transfersLimit
        let phases = buildJobPhases(batch: batches[idx])
        Task.detached { [weak self] in
            guard let self else { return }
            await self.runJob(batchID: batch.batchId, phases: phases, transfersLimit: limit)
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
        if let token = batch.destVolumeToken, PathProtection.volumeToken(for: dst) != token {
            return "目的地卷宗識別與加入時不同,請重新確認位置"
        }
        if let token = batch.sourceVolumeToken, PathProtection.volumeToken(for: srcParent) != token {
            return "來源卷宗識別與加入時不同,請重新確認位置"
        }
        for item in batch.items where item.itemState == .pending || item.itemState == .partial {
            if let err = PathProtection.validate(source: URL(fileURLWithPath: item.sourcePath), destination: dst) {
                return err.localizedDescription
            }
        }
        return nil
    }

    // MARK: Job 規格組裝(PRD §3.5 + 接續需求)
    // 拆相:pending 正常走策略;partial(我們的半成品)必須重傳 → 不可被 IgnoreExisting 略過

    struct JobSpec {
        var srcFs: String
        var dstFs: String
        var includeRules: [String]
        var ignoreExisting: Bool
        var pendingDirs: [String]
    }

    private func buildJobPhases(batch: QueueBatch) -> [JobSpec] {
        let srcParent = batch.sourceParent
        func specFor(_ items: [BatchItem], ignoreExisting: Bool) -> JobSpec {
            var includes: [String] = []
            var dirs: [String] = []
            for item in items {
                let rel = item.sourcePath.hasPrefix(srcParent + "/")
                    ? String(item.sourcePath.dropFirst(srcParent.count + 1))
                    : item.itemName
                if item.isDirectory {
                    includes.append("/" + rel)
                    includes.append("/" + rel + "/**")
                    dirs.append(rel)
                } else {
                    includes.append("/" + rel)
                }
            }
            return JobSpec(srcFs: srcParent, dstFs: batch.destination,
                           includeRules: includes, ignoreExisting: ignoreExisting, pendingDirs: dirs)
        }

        let normal = batch.items.filter { $0.itemState == .pending }
        let partials = batch.items.filter { $0.itemState == .partial }

        if batch.strategy == .addOnly, !partials.isEmpty {
            // 相 1:正常項目(同名略過);相 2:半成品重傳(預設比較 → 大小/時間不同 → 重傳)
            var phases: [JobSpec] = []
            if !normal.isEmpty {
                phases.append(specFor(normal, ignoreExisting: true))
            }
            phases.append(specFor(partials, ignoreExisting: false))
            return phases
        }
        // 覆蓋策略本來就無 IgnoreExisting;單一作業含全部
        return [specFor(normal + partials, ignoreExisting: batch.strategy == .addOnly)]
    }

    // MARK: Job 執行(背景;多相依序;每相一個引擎作業)

    nonisolated private func startEngineJob(spec: JobSpec, transfersLimit: Int) throws -> Int64 {
        try RcloneDaemon.shared.ensureRunning()
        let before = try RcloneDaemon.shared.listJobs()
        let beforeIDs = Set(before.running).union(before.finished)

        var config: [String: Any] = [
            "Transfers": transfersLimit,
            "CreateEmptySrcDirs": true,   // 打包版本實測不生效 → App 補建(見 createMissingEmptyDirs)
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
        NSLog("[FX] copy resp status=%d body=%@", resp.httpStatus, String(data: resp.body, encoding: .utf8) ?? "")
        if let json = resp.json, let id = json["jobid"] as? Int {
            return Int64(id)
        }
        // 啟動要求已送出但回應遺失/失敗:不得當成「未開始」;比對 job 快照找新作業
        Thread.sleep(forTimeInterval: 0.5)
        let after = try RcloneDaemon.shared.listJobs()
        let newIDs = Set(after.running).union(after.finished).subtracting(beforeIDs)
        if let first = newIDs.sorted().first {
            return Int64(first)
        }
        if let err = resp.errorText {
            throw NSError(domain: "folderium.job", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "啟動失敗:\(err)"])
        }
        if resp.httpStatus == 0 {
            throw NSError(domain: "folderium.job", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "啟動請求回應遺失(連線層失敗)"])
        }
        throw NSError(domain: "folderium.job", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "引擎未回報作業 ID"])
    }

    nonisolated private func runJob(batchID: UUID, phases: [JobSpec], transfersLimit: Int) async {
        do {
            for phase in phases {
                let jobID = try startEngineJob(spec: phase, transfersLimit: transfersLimit)
                let group = "job/\(jobID)"
                await MainActor.run {
                    self.currentJobID = jobID
                    self.currentJobGroup = group
                    self.currentBatchID = batchID
                    if let i = self.batches.firstIndex(where: { $0.batchId == batchID }) {
                        self.batches[i].runtimeJobID = jobID
                        self.batches[i].runtimeJobGroup = group
                    }
                }
                // 輪詢此相至終態(約 500ms;進度綁定該作業 stats group)
                while true {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let status = RcloneDaemon.shared.jobStatus(jobID: jobID)
                    let stats = RcloneDaemon.shared.stats(forGroup: group)
                    // Swift 6: read actor state into a local let, no captured var.
                    let stopping: Bool = await MainActor.run {
                        self.updateProgress(stats: stats)
                        if let i = self.batches.firstIndex(where: { $0.batchId == batchID }) {
                            return self.batches[i].state == .stopping
                        }
                        return false
                    }
                    if status == nil && RcloneDaemon.shared.currentIdentity() == nil {
                        // 引擎程序退出:作業未完成
                        await MainActor.run {
                            self.finalize(batchID: batchID, jobError: "引擎程序已退出,作業未完成", stoppedByUser: stopping)
                        }
                        return
                    }
                    guard let status else { continue }
                    if status.finished {
                        if stopping {
                            // 使用者暫停:由 finishPause 結算(partial 標記在那裡做)
                            return
                        }
                        if let err = status.error {
                            await MainActor.run {
                                self.finalize(batchID: batchID, jobError: err, stoppedByUser: false)
                            }
                            return
                        }
                        break // 此相完成,繼續下一相
                    }
                }
            }
            // 全部相完成
            await MainActor.run {
                self.finalize(batchID: batchID, jobError: nil, stoppedByUser: false)
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            await MainActor.run {
                self.finalize(batchID: batchID, jobError: msg, stoppedByUser: false)
            }
        }
    }

    // MARK: 進度顯示

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
        if let transferring = stats["transferring"] as? [[String: Any]] {
            let names = transferring.compactMap { $0["name"] as? String }
            if !names.isEmpty {
                inFlightNames = Set(names)   // 停止時的「只傳一半」偵測依據
                p.fileName = names.first
            }
        }
        if p.totalTransfers == 0 && p.transferredBytes == nil {
            progressNote = "掃描中"
            currentProgress = nil
        } else {
            progressNote = nil
            currentProgress = p
        }
    }

    // MARK: 停止/錯誤結算:偵測「只傳一半」

    struct StopOutcome {
        var partialNames: [String] = []
        var completedNow: Int = 0
        var skippedPreExisting: Int = 0

        var summaryText: String? {
            if !partialNames.isEmpty {
                let shown = partialNames.prefix(5).joined(separator: ", ")
                let extra = partialNames.count > 5 ? " 等 \(partialNames.count) 個" : ""
                return "已暫停;只傳一半待重傳:\(shown)\(extra)。按「啟動」接續(已完成檔案不重傳)"
            }
            return nil
        }

        var noticeText: String? {
            guard !partialNames.isEmpty else { return nil }
            return "以下檔案只傳一半,啟動後將從頭重傳:\n" + partialNames.joined(separator: "\n")
        }
    }

    /// 停止後逐項比對來源/目的地(rclone 同語意:大小+修改時間),標記完成或 partial。
    /// in-flight 檔(停止時正在傳)即使 rclone 清掉暫存、目的地無殘留,也標記只傳一半。
    private func markOutcomesAfterStop(batchIndex i: Int) -> StopOutcome {
        let batch = batches[i]
        let dst = URL(fileURLWithPath: batch.destination)
        let srcParent = URL(fileURLWithPath: batch.sourceParent)
        let preExisting = Set(batch.preExistingRelPaths ?? [])
        var outcome = StopOutcome()

        for j in batches[i].items.indices {
            let item = batches[i].items[j]
            guard item.itemState == .pending else { continue }
            let srcURL = srcParent.appendingPathComponent(item.itemName)
            let destURL = dst.appendingPathComponent(item.itemName)

            var isDir: ObjCBool = false
            let srcExists = FileManager.default.fileExists(atPath: srcURL.path, isDirectory: &isDir)
            let destExists = FileManager.default.fileExists(atPath: destURL.path)

            if !srcExists {
                // 來源消失:誠實列失敗(PRD §3.2),不默默當完成
                batches[i].items[j].itemState = .failed
                batches[i].items[j].lastError = "來源項目已消失"
                continue
            }
            if inFlightNames.contains(item.itemName) && !fileFullyMatches(item: item, at: destURL) {
                // 停止當下正在傳的檔:即使目的地無殘留(rclone 清了暫存),也是只傳一半
                batches[i].items[j].itemState = .partial
                batches[i].items[j].lastError = "只傳一半"
                outcome.partialNames.append(item.itemName)
                continue
            }
            if !destExists {
                continue // 尚未開始 → 保持 pending,啟動後照傳
            }
            if preExisting.contains(item.itemName) {
                // 派發前就存在:不是我們寫的 → 保持 pending(引擎下輪自行判定)
                if batch.strategy == .addOnly {
                    batches[i].items[j].itemState = .skippedSameName
                    outcome.skippedPreExisting += 1
                }
                continue
            }
            // 我們寫出現在目的地:比對是否完整
            if !item.isDirectory && !isDir.boolValue {
                if Self.fileMatches(src: srcURL, dst: destURL) {
                    batches[i].items[j].itemState = .done
                    outcome.completedNow += 1
                } else {
                    batches[i].items[j].itemState = .partial
                    batches[i].items[j].lastError = "只傳一半"
                    outcome.partialNames.append(item.itemName)
                }
            } else {
                let (innerMissing, innerPartial) = Self.compareDirectories(src: srcURL, dst: destURL, limit: 10)
                if innerMissing.isEmpty && innerPartial.isEmpty {
                    batches[i].items[j].itemState = .done
                    outcome.completedNow += 1
                } else {
                    batches[i].items[j].itemState = .partial
                    let detail = (innerPartial + innerMissing).prefix(3).joined(separator: ", ")
                    batches[i].items[j].lastError = "目錄只傳一半\(detail.isEmpty ? "" : "(\(detail)…)")"
                    outcome.partialNames.append(item.itemName + (detail.isEmpty ? "" : "(\(detail)…)"))
                }
            }
        }
        var results = batches[i].results
        results.partial = batches[i].items.filter { $0.itemState == .partial }.count
        batches[i].results = results
        refreshPartialNotice()
        return outcome
    }

    /// 檔案比對:rclone copy 預設語意(大小 + 修改時間,容差 2 秒)
    static func fileMatches(src: URL, dst: URL) -> Bool {
        guard let s = try? src.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]),
              let d = try? dst.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]),
              s.isDirectory != true, d.isDirectory != true,
              let ss = s.fileSize, let ds = d.fileSize, ss == ds else { return false }
        guard let sm = s.contentModificationDate, let dm = d.contentModificationDate else { return false }
        return abs(sm.timeIntervalSince(dm)) <= 2
    }

    /// in-flight 檔停止後是否已完整(檔案:大小+mtime;目錄:遞迴無缺漏)
    private func fileFullyMatches(item: BatchItem, at destURL: URL) -> Bool {
        let srcURL = URL(fileURLWithPath: item.sourcePath)
        if item.isDirectory {
            let (missing, partial) = Self.compareDirectories(src: srcURL, dst: destURL, limit: 10)
            return missing.isEmpty && partial.isEmpty
        }
        return Self.fileMatches(src: srcURL, dst: destURL)
    }

    /// 目錄比對:遞迴收集「目的地缺漏」與「大小不符」的相對路徑(上限 limit)
    static func compareDirectories(src: URL, dst: URL, limit: Int) -> (missing: [String], partial: [String]) {
        var missing: [String] = []
        var partialFiles: [String] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else {
            return ([], [])
        }
        for case let url as URL in enumerator {
            guard let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory else { continue }
            let rel = url.path.hasPrefix(src.path + "/") ? String(url.path.dropFirst(src.path.count + 1)) : url.lastPathComponent
            let counter = dst.appendingPathComponent(rel)
            if isDir {
                var isD: ObjCBool = false
                if !fm.fileExists(atPath: counter.path, isDirectory: &isD) || !isD.boolValue {
                    missing.append(rel + "/")
                }
            } else {
                var isD: ObjCBool = false
                if !fm.fileExists(atPath: counter.path, isDirectory: &isD) || isD.boolValue {
                    missing.append(rel)
                } else if !fileMatches(src: url, dst: counter) {
                    partialFiles.append(rel)
                }
            }
            if missing.count + partialFiles.count >= limit { break }
        }
        return (missing, partialFiles)
    }

    /// 彙整所有批次的 partial 提醒
    private func refreshPartialNotice() {
        var names: [String] = []
        for batch in batches {
            for item in batch.items where item.itemState == .partial {
                names.append(item.itemName)
            }
        }
        partialNotice = names.isEmpty ? nil : "⚠️ 只傳一半(\(names.count)):啟動後將重傳 — " + names.prefix(8).joined(separator: ", ") + (names.count > 8 ? "…" : "")
    }

    // MARK: 終態結算

    private func markUnconfirmed(batchID: UUID, reason: String) {
        guard let i = batches.firstIndex(where: { $0.batchId == batchID }) else { return }
        batches[i].state = .needsAttention
        batches[i].lastError = "需處理:狀態待確認 — \(reason)"
        dispatchBlockedReason = reason
        persistLocked(reason: "unconfirmed") { _ in }
    }

    private func finalize(batchID: UUID, jobError: String?, stoppedByUser: Bool) {
        currentJobID = nil
        currentJobGroup = nil
        currentProgress = nil
        progressNote = nil
        guard let i = batches.firstIndex(where: { $0.batchId == batchID }) else { return }

        if let jobError {
            // 引擎錯誤/中斷:不宣稱成功;結算已完成與 partial,保持可接續
            batches[i].runtimeJobID = nil
            batches[i].runtimeJobGroup = nil
            let outcome = markOutcomesAfterStop(batchIndex: i)
            batches[i].state = stoppedByUser ? .paused : .needsAttention
            let partialPart = outcome.noticeText.map { "\n" + $0 } ?? ""
            batches[i].lastError = "\(jobError)\(partialPart)"
            partialNotice = outcome.noticeText ?? partialNotice
            currentBatchID = nil
            persistLocked(reason: "finalize-error") { _ in }
            return
        }

        // 成功:結算項目狀態
        // 空目錄補建必須在結算之前:引擎不會回傳空目錄,若先結算再補建,
        // 只含空目錄的項目會被誤判「引擎成功但目的地未出現此項目」→ failed。
        createMissingEmptyDirs(batch: batches[i])

        let batch = batches[i]
        var results = BatchResults()
        results.unsupported = batch.items.filter { $0.itemState == .unsupported }.count
        let dstURL = URL(fileURLWithPath: batch.destination)
        let srcParent = URL(fileURLWithPath: batch.sourceParent)

        for j in batches[i].items.indices {
            switch batches[i].items[j].itemState {
            case .unsupported, .done, .failed, .skippedSameName:
                continue
            case .pending, .partial:
                let item = batches[i].items[j]
                let srcURL = srcParent.appendingPathComponent(item.itemName)
                let destPath = dstURL.appendingPathComponent(item.itemName)
                var isDir: ObjCBool = false
                if !FileManager.default.fileExists(atPath: srcURL.path, isDirectory: &isDir) {
                    batches[i].items[j].itemState = .failed
                    batches[i].items[j].lastError = "來源項目已消失"
                } else if FileManager.default.fileExists(atPath: destPath.path) {
                    if !item.isDirectory && !isDir.boolValue {
                        batches[i].items[j].itemState = Self.fileMatches(src: srcURL, dst: destPath) ? .done : .partial
                        if batches[i].items[j].itemState == .partial {
                            batches[i].items[j].lastError = "重傳後仍不完整"
                        }
                    } else {
                        let (m, p) = Self.compareDirectories(src: srcURL, dst: destPath, limit: 5)
                        batches[i].items[j].itemState = (m.isEmpty && p.isEmpty) ? .done : .partial
                        if batches[i].items[j].itemState == .partial {
                            batches[i].items[j].lastError = "重傳後仍不完整"
                        }
                    }
                } else {
                    batches[i].items[j].itemState = .failed
                    batches[i].items[j].lastError = "引擎成功但目的地未出現此項目"
                }
            }
        }
        results.copied = batches[i].items.filter { $0.itemState == .done }.count
        results.failed = batches[i].items.filter { $0.itemState == .failed }.count
        results.partial = batches[i].items.filter { $0.itemState == .partial }.count

        if batch.strategy == .addOnly {
            let preexisting = batches[i].items.filter { item in
                item.itemState == .skippedSameName
            }.count
            results.engineNoTransfer = preexisting
        }

        batches[i].results = results
        batches[i].runtimeJobID = nil
        batches[i].runtimeJobGroup = nil

        if results.failed > 0 {
            batches[i].state = .needsAttention
            batches[i].lastError = "\(results.failed) 個項目失敗"
        } else if results.partial > 0 {
            batches[i].state = .needsAttention
            let names = batches[i].items.filter { $0.itemState == .partial }.map { $0.itemName }
            batches[i].lastError = "\(results.partial) 個項目重傳後仍不完整:" + names.prefix(5).joined(separator: ", ")
        } else {
            batches[i].state = .done
            batches[i].lastError = nil
        }
        refreshPartialNotice()
        currentBatchID = nil
        persistLocked(reason: "finalize") { _ in
            self.maybeDispatch()
        }
    }

    /// 遞迴找出選取目錄內的空目錄(含隱藏),在目的地對應建立。
    private func createMissingEmptyDirs(batch: QueueBatch) {
        let fm = FileManager.default
        let srcParent = URL(fileURLWithPath: batch.sourceParent)
        let dst = URL(fileURLWithPath: batch.destination)
        for item in batch.items where item.isDirectory && item.itemState != .unsupported {
            let srcDir = srcParent.appendingPathComponent(item.itemName)
            let dstDir = dst.appendingPathComponent(item.itemName)
            createEmptyDirsRecursively(src: srcDir, dst: dstDir, fm: fm)
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
            queuePaused: !queueStarted,   // 相容 schema:啟動狀態以 paused=false 表示
            batches: list
        )
    }

    /// 序列化保存;回傳是否成功
    @discardableResult
    private func persistLocked(reason: String, then: @escaping (Bool) -> Void = { _ in }) -> Bool {
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
            persistLocked(reason: "app-exit") { _ in }
            return confirmed
        }
        RcloneDaemon.shared.shutdown(currentJobID: nil)
        persistLocked(reason: "app-exit") { _ in }
        return true
    }
}
