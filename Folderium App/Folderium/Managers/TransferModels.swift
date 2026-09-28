import Foundation

// MARK: - Queue data models (queue.json schema v1)
// PRD v1.3 §3.3, §3.4, §3.5

/// 衝突策略:每批加入時固定,之後不可變。
enum ConflictStrategy: String, Codable, CaseIterable, Identifiable {
    /// 只新增(預設):目的地同名檔案一律略過,即使內容不同。
    case addOnly
    /// 以來源覆蓋差異檔:依打包版本 rclone copy 預設比較語意(大小+修改時間),需傳輸者以來源取代,即使目的地較新。
    case overwriteChanged

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .addOnly: return "只新增(同名略過)"
        case .overwriteChanged: return "以來源覆蓋差異檔"
        }
    }

    var detailText: String {
        switch self {
        case .addOnly: return "目的地已有同名檔案時一律略過,不比較內容"
        case .overwriteChanged: return "依大小/修改時間判定差異後以來源覆蓋,即使目的地較新"
        }
    }
}

/// 批次狀態(PRD §3.3 最小狀態機)
enum BatchState: String, Codable {
    case waiting        // 已成功保存、尚未派發
    case running        // 目前唯一已派發傳輸作業所屬批次
    case stopping       // 已請求停止但尚未確認終止
    case paused         // 已確認無作業繼續寫入;由使用者繼續
    case needsAttention // 錯誤、路徑/裝置問題、保存失敗或引擎狀態待確認
    case done           // 該批無待執行作業且無未解失敗

    var displayName: String {
        switch self {
        case .waiting: return "等待"
        case .running: return "執行中"
        case .stopping: return "停止中"
        case .paused: return "已暫停"
        case .needsAttention: return "需處理"
        case .done: return "完成"
        }
    }
}

/// 批次內單一選取項目(檔案或資料夾)的執行狀態
enum ItemState: String, Codable {
    case pending
    case done
    case failed
    case skippedSameName   // 因同名略過(只新增策略)
    case unsupported       // 符號連結、套件等不支援項目

    var displayName: String {
        switch self {
        case .pending: return "待傳輸"
        case .done: return "已複製"
        case .failed: return "失敗"
        case .skippedSameName: return "因同名略過"
        case .unsupported: return "不支援"
        }
    }
}

struct BatchItem: Codable, Identifiable {
    let id: UUID
    /// 選取項目絕對路徑(尚未標準化為 symlink 後路徑;保護檢查在派發時以實際位置進行)
    let sourcePath: String
    let itemName: String
    let isDirectory: Bool
    var itemState: ItemState = .pending
    var lastError: String?
}

/// 批次結果摘要(PRD §3.5:區分實際複製/同名略過/引擎判定無須傳輸/失敗)
struct BatchResults: Codable, Equatable {
    var copied: Int = 0
    var skippedSameName: Int = 0
    var engineNoTransfer: Int = 0
    var failed: Int = 0
    var unsupported: Int = 0

    var hasIssues: Bool { failed > 0 || unsupported > 0 }
}

/// 一次拖曳或貼上的選取項目算一批
struct QueueBatch: Codable, Identifiable {
    let batchId: UUID
    var id: UUID { batchId }
    let createdAt: Date
    /// 選取項目的共同父目錄(絕對路徑)
    let sourceParent: String
    /// 目的地目錄(絕對路徑)
    let destination: String
    let strategy: ConflictStrategy
    var state: BatchState = .waiting
    var items: [BatchItem] = []
    var lastError: String?
    /// 可取得的卷宗識別資訊(st_dev),派發/恢復前核對原位置
    var sourceVolumeToken: String?
    var destVolumeToken: String?
    /// 引擎 job 資訊僅供目前引擎生命週期使用,不作為重開後的永久工作身分
    var runtimeJobID: Int64?
    var runtimeJobGroup: String?
    var results: BatchResults = BatchResults()
    /// 加入時是否已向使用者提示「依執行時來源內容複製」
    var runtimeNotedAtAdd: Bool = false

    var pendingItems: [BatchItem] { items.filter { $0.itemState == .pending } }

    var summaryText: String {
        let names = items.prefix(3).map { $0.itemName }
        let extra = items.count > 3 ? " 等 \(items.count) 項" : ""
        return names.joined(separator: ", ") + extra
    }
}

/// queue.json 文件
struct QueueDocument: Codable {
    var schemaVersion: Int = 1
    /// 同時傳輸的檔案數上限 N(1~4,預設 2);調整後從下一個作業生效
    var transfersLimit: Int = 2
    var queuePaused: Bool = false
    var batches: [QueueBatch] = []
}

// MARK: - Path protection (PRD §4.3)

enum PathProtection {
    enum ProtectionError: LocalizedError {
        case sameLocation
        case destinationInsideSource
        case symlinkedCollision
        case cannotResolve

        var errorDescription: String? {
            switch self {
            case .sameLocation: return "來源與目的地相同,已拒絕"
            case .destinationInsideSource: return "目的地位於來源資料夾內,已拒絕"
            case .symlinkedCollision: return "路徑經符號連結解析後重疊,無法安全判定,已拒絕"
            case .cannotResolve: return "無法解析實際路徑,已拒絕"
            }
        }
    }

    /// 以實際位置(resolvingSymlinksInPath)判斷,不只比較字串。
    static func validate(source: URL, destination: URL) -> ProtectionError? {
        guard let src = normalized(source), let dst = normalized(destination) else {
            return .cannotResolve
        }
        if src.path == dst.path { return .sameLocation }
        // 資料夾複製到自身子目錄:目的地在來源目錄內
        if dst.path.hasPrefix(src.path + "/") { return .destinationInsideSource }
        return nil
    }

    static func normalized(_ url: URL) -> URL? {
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.path.count > 1, resolved.path != "/" || url.path == "/" else { return nil }
        return resolved
    }

    /// 取得路徑的卷宗識別 token(st_dev),供恢復/派發前核對原位置
    static func volumeToken(for url: URL) -> String? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        var token = "dev:\(st.st_dev)"
        if let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]),
           let uuid = values.volumeUUIDString {
            token += ":uuid:\(uuid)"
        }
        return token
    }
}
