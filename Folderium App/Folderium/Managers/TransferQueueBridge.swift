import Foundation
import SwiftUI

// MARK: - TransferQueueBridge: UI → TransferQueue 的橋接
// 負責:加入佇列(含策略選擇)、衝突策略設定、錯誤提示

@MainActor
final class TransferQueueBridge: ObservableObject {
    static let shared = TransferQueueBridge()

    @AppStorage("folderium.conflictStrategy") private var strategyRaw: String = ConflictStrategy.addOnly.rawValue
    @Published var lastError: String?
    @Published var strategy: ConflictStrategy = .addOnly

    private init() {
        strategy = ConflictStrategy(rawValue: strategyRaw) ?? .addOnly
    }

    func setStrategy(_ s: ConflictStrategy) {
        strategy = s
        strategyRaw = s.rawValue
    }

    /// 拖放/貼上進入複製佇列。來源消失項目誠實列失敗(PRD §3.2)
    func enqueueCopy(sources: [URL], destination: URL) {
        guard !sources.isEmpty else { return }
        let fm = FileManager.default

        var groups: [URL: [(url: URL, isDirectory: Bool)]] = [:]
        for url in sources {
            let parent = url.deletingLastPathComponent()
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if !exists {
                // 來源消失:照樣加入,由佇列派發時列為失敗,不默默當成完成
                groups[parent, default: []].append((url: url, isDirectory: isDir.boolValue))
                continue
            }
            groups[parent, default: []].append((url: url, isDirectory: isDir.boolValue))
        }

        var firstError: String?
        for (parent, items) in groups.sorted(by: { $0.key.path < $1.key.path }) {
            let err = TransferQueue.shared.addBatch(
                sourceParent: parent,
                items: items,
                destination: destination,
                strategy: strategy
            )
            if let err, firstError == nil { firstError = err }
        }
        if let firstError {
            lastError = firstError
        }
    }
}
