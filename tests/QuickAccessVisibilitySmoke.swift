import Foundation

@main struct QuickAccessVisibilitySmoke {
    static func main() {
        var legacy = QuickAccessVisibility(storedValue: "Pictures,Music")
        precondition(!legacy.isVisible(.shortcut, "Pictures"), "legacy Pictures preference lost")
        precondition(!legacy.isVisible(.shortcut, "Music"), "legacy Music preference lost")
        precondition(legacy.isVisible(.shortcut, "Home"), "unselected shortcut must remain visible")

        let unusualPath = "/Volumes/NAS, A/folder\nname"
        legacy.setVisible(.drive, unusualPath, visible: false)
        legacy.setVisible(.pinned, unusualPath, visible: false)
        legacy.setVisible(.recent, unusualPath, visible: false)
        legacy.setVisible(.section, "Recent", visible: false)
        legacy.setVisible(.action, "Choose Folder", visible: false)
        let saved = legacy.storedValue
        precondition(saved.first == "[", "new settings must use delimiter-safe JSON")

        var restored = QuickAccessVisibility(storedValue: saved)
        for kind in [QuickAccessVisibility.Category.drive, .pinned, .recent] {
            precondition(!restored.isVisible(kind, unusualPath), "individual path choice must survive reload")
        }
        precondition(!restored.isVisible(.section, "Recent"), "section choice must survive reload")
        precondition(!restored.isVisible(.action, "Choose Folder"), "action choice must survive reload")
        precondition(restored.isVisible(.action, "Pin Active Folder"), "other action should remain visible")
        restored.setVisible(.drive, unusualPath, visible: true)
        precondition(restored.isVisible(.drive, unusualPath), "drive did not restore")
        precondition(!restored.isVisible(.pinned, unusualPath), "drive and pinned IDs must be independent")
        precondition(!restored.isVisible(.shortcut, "Pictures"), "updating a drive lost the shortcut choice")
        restored.showAll()
        precondition(restored.storedValue.isEmpty, "reset must clear persisted hidden choices")
        precondition(QuickAccessVisibility(storedValue: restored.storedValue).isVisible(.shortcut, "Pictures"))

        let malformed = QuickAccessVisibility(storedValue: "[not json")
        precondition(malformed.isVisible(.shortcut, "Home"), "malformed settings should fail open")
        print("QuickAccessVisibility smoke PASS")
    }
}
