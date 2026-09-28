import Foundation

// MARK: - SingleInstanceGuard: 同一佇列只允許一個 App 實例作為 writer/派發者
// PRD v1.3 §2:第二個實例應轉交既有實例或拒絕啟動傳輸,不可另開一套佇列排程。
// 採簡單檔案鎖(flock),不引入分散式鎖。

enum SingleInstanceGuard {
    private static var lockFileDescriptor: Int32 = -1

    /// 嘗試取得唯一 writer 鎖。回傳 false = 已有實例在跑。
    /// 舊實例剛被 kill/終止中時 flock 尚未釋放,短暫重試涵蓋此競態,
    /// 避免新實例誤判「已有實例」後前景化垂死實例、自身退出導致 0 視窗。
    static func acquire() -> Bool {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = support.appendingPathComponent("Folderium", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lockURL = dir.appendingPathComponent("instance.lock")

        // 最多 ~2.5s:flock 期間被垂死實例持有屬正常退出窗口。
        let retryIntervals: [useconds_t] = [0, 100_000, 200_000, 400_000, 800_000, 1_000_000]
        for delay in retryIntervals {
            if delay > 0 { usleep(delay) }
            let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
            guard fd >= 0 else { return true } // 無法開鎖檔:寧可放行(個人自用),由 rclone 身分機制兜底
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                lockFileDescriptor = fd
                return true
            }
            close(fd)
        }
        return false
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
