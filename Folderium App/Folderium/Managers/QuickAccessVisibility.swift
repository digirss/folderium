import Foundation

/// Visibility only: hiding a Quick Access row never changes a pin, mount, or file.
struct QuickAccessVisibility {
    enum Category: String {
        case shortcut, recent, pinned, drive, section, action
    }

    private var hiddenKeys: Set<String>

    init(storedValue: String) {
        if storedValue.hasPrefix("[") {
            let decoded = try? JSONDecoder().decode([String].self, from: Data(storedValue.utf8))
            hiddenKeys = Set(decoded ?? [])
        } else {
            // Version 0.1.1 stored comma-separated names of built-in shortcuts.
            hiddenKeys = Set(storedValue.split(separator: ",").map { "shortcut:\($0)" })
        }
    }

    func isVisible(_ category: Category, _ identifier: String) -> Bool {
        !hiddenKeys.contains("\(category.rawValue):\(identifier)")
    }

    mutating func setVisible(_ category: Category, _ identifier: String, visible: Bool) {
        let key = "\(category.rawValue):\(identifier)"
        if visible {
            hiddenKeys.remove(key)
        } else {
            hiddenKeys.insert(key)
        }
    }

    mutating func showAll() {
        hiddenKeys.removeAll()
    }

    var storedValue: String {
        guard !hiddenKeys.isEmpty, let data = try? JSONEncoder().encode(hiddenKeys.sorted()) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
