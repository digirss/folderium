import Foundation
import Combine

// MARK: - RcloneDaemon: App 自有 rclone 背景程序管理
// PRD v1.3 §5:管理 App 自有背景程序、身分辨識、HTTP 呼叫、停止確認與退出。
// 僅綁定 127.0.0.1 + App 產生的認證;不開 Web GUI、遠端存取或指標服務。
// 連接埠被不明服務占用就換埠,不接管。認證不寫入一般日誌或 queue.json。

struct RCResponse {
    let httpStatus: Int
    let body: Data
    let json: [String: Any]?

    var errorText: String? {
        guard let json, let err = json["error"] as? String, !err.isEmpty else { return nil }
        return err
    }
}

final class RcloneDaemon: NSObject, ObservableObject {
    enum DaemonError: LocalizedError {
        case noBinary
        case notRunning
        case startFailed(String)
        case portExhausted

        var errorDescription: String? {
            switch self {
            case .noBinary: return "找不到 rclone 執行檔"
            case .notRunning: return "rclone 引擎未啟動"
            case .startFailed(let msg): return "rclone 啟動失敗:\(msg)"
            case .portExhausted: return "找不到可用連接埠"
            }
        }
    }

    struct EngineIdentity: Codable {
        let port: Int
        let user: String
        let password: String
        let pid: Int32
        let startedAt: Date
    }

    struct JobList {
        let running: [Int]
        let finished: [Int]
    }

    enum PreviousEngineState: Equatable {
        case none                        // 無身分檔或程序已退出
        case aliveOurs(PidAlive: Bool)   // 身分核對通過(port+認證),仍在寫入
        case ambiguous                   // 無法確認身分或存活狀態 → 狀態待確認
    }

    static let shared = RcloneDaemon()

    @Published private(set) var isRunning: Bool = false
    @Published var lastError: String?

    private var process: Process?
    private var identity: EngineIdentity?
    private let identityFileURL: URL

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = support.appendingPathComponent("Folderium/engine", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        identityFileURL = dir.appendingPathComponent("engine.json")
        super.init()
    }

    // MARK: Binary

    /// 打包優先 App bundle 內 rclone;開發環境退回 homebrew。
    private static func bundledRcloneURL() -> URL? {
        let candidates: [URL] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/rclone"),
            Bundle.main.resourceURL?.appendingPathComponent("rclone") ?? URL(fileURLWithPath: "/nonexistent-rclone-resource"),
            URL(fileURLWithPath: "/opt/homebrew/bin/rclone"),
            URL(fileURLWithPath: "/usr/local/bin/rclone"),
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: Lifecycle

    func ensureRunning() throws {
        if process?.isRunning == true, identity != nil { return }
        try start()
    }

    private func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            bytes = Array(UUID().uuidString.utf8)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "x")
            .replacingOccurrences(of: "/", with: "y")
            .replacingOccurrences(of: "=", with: "")
            .lowercased()
    }

    private func start() throws {
        guard let binary = Self.bundledRcloneURL() else { throw DaemonError.noBinary }

        let user = "fld_" + randomToken().prefix(10)
        let password = randomToken() + randomToken()

        var lastStartError = "unknown"
        for port in 5573...(5573 + 40) {
            if portHasListener(port) { continue } // 占用者非我方 → 換埠,不接管不明服務

            let p = Process()
            p.executableURL = binary
            p.arguments = [
                "rcd",
                "--rc-addr", "127.0.0.1:\(port)",
                "--rc-user", user,
                "--rc-pass", password,
                "--rc-job-expire-duration", "24h",
            ]
            let sink = Pipe()
            p.standardOutput = sink
            p.standardError = sink
            do { try p.run() } catch {
                lastStartError = error.localizedDescription
                continue
            }

            let probe = EngineIdentity(port: port, user: user, password: password, pid: p.processIdentifier, startedAt: Date())
            var ready = false
            for _ in 0..<40 {
                if !p.isRunning { break }
                if post(path: "core/version", params: [:], to: probe).json?["version"] != nil {
                    ready = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            if ready {
                process = p
                identity = probe
                persistIdentity(probe)
                DispatchQueue.main.async {
                    self.isRunning = true
                    self.lastError = nil
                }
                return
            }
            if p.isRunning { p.terminate(); p.waitUntilExit() }
            lastStartError = "daemon 未在 10 秒內就緒"
        }
        throw DaemonError.startFailed(lastStartError)
    }

    private func portHasListener(_ port: Int) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var writeSet = fd_set()
        withUnsafeMutablePointer(to: &writeSet) { ptr in
            withUnsafeMutableBytes(of: &ptr.pointee.fds_bits) { raw in
                // fds_bits 是 int32 陣列;以 Int32 視圖設 bit
                let int32View = raw.bindMemory(to: Int32.self)
                let idx = Int(fd) / 32
                if int32View.count > idx {
                    int32View[idx] |= Int32(1 << (Int(fd) % 32))
                }
            }
        }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        guard select(fd + 1, nil, &writeSet, nil, &tv) > 0 else { return false }
        // writable 不代表連上:連線被拒也會 writable。檢查 SO_ERROR。
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        return soError == 0
    }

    // MARK: Identity persistence (PRD §3.4 rule 6)

    private func persistIdentity(_ id: EngineIdentity) {
        if let data = try? JSONEncoder().encode(id) {
            try? data.write(to: identityFileURL, options: [.atomic])
        }
    }

    private func loadPersistedIdentity() -> EngineIdentity? {
        guard let data = try? Data(contentsOf: identityFileURL) else { return nil }
        return try? JSONDecoder().decode(EngineIdentity.self, from: data)
    }

    private func clearPersistedIdentity() {
        try? FileManager.default.removeItem(at: identityFileURL)
    }

    /// App 重開後檢查前次自有 rclone 是否仍存活。
    /// 區分自身程序與使用者其他 rclone:port + 認證核對,不只憑 PID 或程序名稱。
    func checkPreviousEngine() -> PreviousEngineState {
        guard let previous = loadPersistedIdentity() else { return .none }

        let pidAlive = kill(previous.pid, 0) == 0
        var authOK = false
        if portHasListener(previous.port) {
            authOK = post(path: "core/version", params: [:], to: previous).json?["version"] != nil
        }

        if authOK {
            // port 通 + 認證通過 → 是我們前次啟動的引擎,仍在寫入
            return .aliveOurs(PidAlive: pidAlive)
        }
        if pidAlive {
            // PID 在但 port 認證不通:無法確認是否仍寫入 → 狀態待確認
            return .ambiguous
        }
        if portHasListener(previous.port) {
            // 埠被不明服務占用且非我方 → 待確認(不接管)
            return .ambiguous
        }
        return .none
    }

    /// 恢復前處理前次引擎:請求停止所有執行中 job、確認終止、結束前次程序。
    /// 回傳 nil = 已安全處理;回傳錯誤 = 保留狀態待確認,不允許恢復。
    func reconcilePreviousEngine() -> PreviousEngineState? {
        guard let previous = loadPersistedIdentity() else {
            clearPersistedIdentity()
            return nil
        }
        guard portHasListener(previous.port),
              post(path: "core/version", params: [:], to: previous).json?["version"] != nil else {
            // 引擎已不在(或埠已被別人接管):刪身分檔,重開新引擎即可
            if kill(previous.pid, 0) == 0 && !portHasListener(previous.port) {
                // PID 活著但 port 不通:非 rclone rcd 或掛死;無法證明仍在寫入我們的檔案
                // 保守:不殺非核對程序,標記待確認
                return .ambiguous
            }
            clearPersistedIdentity()
            return nil
        }

        // 身分核對通過:停止所有 running jobs
        let jobs = post(path: "job/list", params: [:], to: previous)
        let running = (jobs.json?["runningIds"] as? [Int]) ?? []
        for jobID in running {
            _ = post(path: "job/stop", params: ["jobid": jobID], to: previous)
        }
        var allStopped = true
        for jobID in running {
            if !confirmTerminated(jobID: Int64(jobID), via: previous, timeout: 8) { allStopped = false }
        }
        guard allStopped else { return .ambiguous }

        // 結束前次程序(身分已用 port+認證核對,非僅程序名稱比對)
        kill(previous.pid, SIGTERM)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && kill(previous.pid, 0) == 0 {
            Thread.sleep(forTimeInterval: 0.1)
        }
        clearPersistedIdentity()
        return nil
    }

    // MARK: HTTP (序列化所有 RC 呼叫)

    private let httpSerialQueue = DispatchQueue(label: "folderium.rc.http")

    func currentIdentity() -> EngineIdentity? {
        guard process?.isRunning == true else { return nil }
        return identity
    }

    func post(_ path: String, params: [String: Any], async: Bool = false) throws -> RCResponse {
        guard let id = currentIdentity() else { throw DaemonError.notRunning }
        return post(path: path, params: params, to: id, async: async)
    }

    private func post(path: String, params: [String: Any], to id: EngineIdentity, async: Bool = false) -> RCResponse {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(id.port)/\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let login = "\(id.user):\(id.password)".data(using: .utf8)!.base64EncodedString()
        request.setValue("Basic \(login)", forHTTPHeaderField: "Authorization")

        var parts: [String] = []
        for (key, value) in params.sorted(by: { $0.key < $1.key }) {
            let encoded: String
            if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value), let s = String(data: data, encoding: .utf8) {
                encoded = s
            } else if let b = value as? Bool {
                encoded = b ? "true" : "false"
            } else if let i = value as? Int {
                encoded = String(i)
            } else {
                encoded = "\(value)"
            }
            parts.append("\(key)=\(encoded.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        }
        if async { parts.append("_async=true") }
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = parts.joined(separator: "&").data(using: .utf8)

        var out = RCResponse(httpStatus: 0, body: Data(), json: nil)
        let semaphore = DispatchSemaphore(value: 0)
        // 注意:不在 serial queue 內 wait(會自鎖);dataTask callback 直接 signal
        var capturedData: Data?
        var capturedResponse: URLResponse?
        var capturedError: Error?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            capturedData = data
            capturedResponse = response
            capturedError = error
            semaphore.signal()
        }
        // 序列化起點:在 serial queue 上 resume,但不 wait(queue 不阻塞)
        httpSerialQueue.async {
            task.resume()
        }
        _ = semaphore.wait(timeout: .now() + 35)
        if capturedError == nil {
            let http = (capturedResponse as? HTTPURLResponse)?.statusCode ?? 0
            let json = (capturedData.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]
            out = RCResponse(httpStatus: http, body: capturedData ?? Data(), json: json)
        }
        return out
    }

    // MARK: Job control (PRD §3.3)

    func listJobs() throws -> JobList {
        let resp = try post("job/list", params: [:])
        guard let json = resp.json else { throw DaemonError.notRunning }
        return JobList(
            running: (json["runningIds"] as? [Int]) ?? [],
            finished: (json["finishedIds"] as? [Int]) ?? []
        )
    }

    func jobStatus(jobID: Int64) -> (finished: Bool, success: Bool, error: String?, stats: [String: Any]?)? {
        guard let id = currentIdentity() else { return nil }
        let resp = post(path: "job/status", params: ["jobid": Int(jobID)], to: id)
        guard let json = resp.json, resp.errorText == nil else { return nil }
        let finished = json["finished"] as? Bool ?? false
        let success = json["success"] as? Bool ?? false
        let error = json["error"] as? String ?? ""
        return (finished, success, error.isEmpty ? nil : error, json["stats"] as? [String: Any])
    }

    func requestJobStop(jobID: Int64) -> Bool {
        guard let id = currentIdentity() else { return false }
        return post(path: "job/stop", params: ["jobid": Int(jobID)], to: id).errorText == nil
    }

    /// 確認 job 已終止(finished)或引擎程序已退出;不能僅以 timeout/找不到 job ID 判定已停止。
    func confirmTerminated(jobID: Int64, via id: EngineIdentity? = nil, timeout: TimeInterval = 10) -> Bool {
        let target = id ?? currentIdentity()
        guard let target else { return process?.isRunning != true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let resp = post(path: "job/status", params: ["jobid": Int(jobID)], to: target)
            if let json = resp.json {
                if let finished = json["finished"] as? Bool, finished { return true }
                // 找不到 job(id 過期)且引擎仍在 → 未確認終止
            }
            if id == nil && process?.isRunning != true { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// 目的地為指定 stats group 的進度(core/stats group=job/N)
    func stats(forGroup group: String) -> [String: Any]? {
        guard let id = currentIdentity() else { return nil }
        let resp = post(path: "core/stats", params: ["group": group], to: id)
        return resp.json
    }

    // MARK: App exit (PRD §4.4)

    /// 傳輸中結束 App:先請求正常停止、確認終止,再結束自己啟動的 rclone。
    /// 回傳 false = 停止無法確認(呼叫端顯示阻礙,不假報已停止)。
    @discardableResult
    func shutdown(currentJobID: Int64?) -> Bool {
        var confirmed = true
        if let jobID = currentJobID {
            _ = requestJobStop(jobID: jobID)
            confirmed = confirmTerminated(jobID: jobID, timeout: 8)
        }
        if let p = process, p.isRunning {
            p.terminate()
            p.waitUntilExit()
        }
        process = nil
        identity = nil
        clearPersistedIdentity()
        DispatchQueue.main.async { self.isRunning = false }
        return confirmed
    }
}
