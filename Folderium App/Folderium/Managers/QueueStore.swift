import Foundation

// MARK: - QueueStore: queue.json 原子寫入與損毀保護
// PRD v1.3 §3.4 保存規則:
//   1. 原子寫入,序列化所有佇列寫入
//   4. 讀取損毀或不支援 schema 時保留原檔、提示,不默認成空佇列後覆寫

enum QueueStoreError: LocalizedError {
    case corrupt(String)
    case unsupportedSchema(Int)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .corrupt(let m): return "queue.json 損毀:\(m)"
        case .unsupportedSchema(let v): return "不支援的 schema 版本 \(v),已保留原檔"
        case .saveFailed(let m): return "保存失敗:\(m)"
        }
    }
}

struct QueueStore {
    static let schemaVersion = 1

    private let fileURL: URL
    private let backupURL: URL
    private let ioQueue = DispatchQueue(label: "folderium.queue.io")

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = support.appendingPathComponent("Folderium", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("queue.json")
        backupURL = dir.appendingPathComponent("queue.corrupt.backup.json")
    }

    /// 讀取。損毀/不支援 schema → throw(呼叫端停止派發,不覆寫原檔)
    func load() throws -> QueueDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return QueueDocument(schemaVersion: Self.schemaVersion, transfersLimit: 2, queuePaused: false, batches: [])
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw QueueStoreError.corrupt("無法讀取:\(error.localizedDescription)")
        }
        do {
            let doc = try JSONDecoder().decode(QueueDocument.self, from: data)
            guard doc.schemaVersion == Self.schemaVersion else {
                throw QueueStoreError.unsupportedSchema(doc.schemaVersion)
            }
            return doc
        } catch let e as QueueStoreError {
            throw e
        } catch DecodingError.dataCorrupted(let ctx) {
            keepCorruptBackup()
            throw QueueStoreError.corrupt(ctx.debugDescription)
        } catch {
            keepCorruptBackup()
            throw QueueStoreError.corrupt("\(error.localizedDescription)")
        }
    }

    /// 損毀時保留原檔副本(不刪原檔)
    private func keepCorruptBackup() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)
        }
    }

    /// 使用者明確選擇重建時:先留存原檔副本再建立新佇列
    func rebuildFresh(keepingBackup: Bool = true) -> QueueDocument {
        if keepingBackup, FileManager.default.fileExists(atPath: fileURL.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            let stamped = backupURL.deletingLastPathComponent()
                .appendingPathComponent("queue.rebuild.\(stamp).json")
            try? FileManager.default.copyItem(at: fileURL, to: stamped)
        }
        let doc = QueueDocument(schemaVersion: Self.schemaVersion, transfersLimit: 2, queuePaused: false, batches: [])
        try? save(doc)
        return doc
    }

    /// 原子寫入(temp + rename),序列化所有寫入
    func save(_ doc: QueueDocument) throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(doc)
        } catch {
            throw QueueStoreError.saveFailed("編碼失敗:\(error.localizedDescription)")
        }
        var thrown: Error?
        ioQueue.sync {
            do {
                try data.write(to: fileURL, options: [.atomic])
            } catch {
                thrown = error
            }
        }
        if let thrown {
            throw QueueStoreError.saveFailed(thrown.localizedDescription)
        }
    }

    var corruptBackupPath: String { backupURL.path }
}
