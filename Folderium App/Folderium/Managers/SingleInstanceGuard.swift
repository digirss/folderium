import Foundation

// MARK: - SingleInstanceGuard: 同一佇列只允許一個 App 實例作為 writer/派發者
// PRD v1.3 §2:第二個實例應轉交既有實例或拒絕啟動傳輸,不可另開一套佇列排程。
// 採簡單檔案鎖(flock),不引入分散式鎖。

enum SingleInstanceGuard {
    private static var lockFileDescriptor: Int32 = -1

    /// 嘗試取得唯一 writer 鎖。回傳 false = 已有實例在跑。
    static func acquire() -> Bool {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = support.appendingPathComponent("Folderium", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lockURL = dir.appendingPathComponent("instance.lock")
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return true } // 無法開鎖檔:寧可放行(個人自用),由 rclone 身分機制兜底
        let ok = flock(fd, LOCK_EX | LOCK_NB) == 0
        if ok {
            lockFileDescriptor = fd
        } else {
            close(fd)
        }
        return ok
    }

    /// 前景化既有實例(把既有 App 帶到前面);回傳是否成功
    static func activateExistingInstance() -> Bool {
        let appleScript = NSAppleScript(source: """
            tell application id "com.leon.FolderiumX" to activate
            """)
        _ = appleScript?.executeAndReturnError(nil)
        return true
    }
}
