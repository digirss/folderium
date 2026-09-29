import SwiftUI

// MARK: - Toolbar customization (Firefox-style)
// Per-toolbar item visibility + drag reordering, persisted as JSON in
// UserDefaults. Each toolbar registers its own storage key and default
// item set; unknown/missing items fall back to defaults (forward compatible
// when new items are added later).

struct CustomizableToolbarItem: Identifiable, Equatable {
    let id: String          // stable identifier (never rename; migrations key off this)
    let title: String       // default label shown in the customize sheet
    let systemImage: String
}

struct CustomizableToolbarLayout: Codable, Equatable {
    var visible: [String]
    var order: [String]     // full ordering incl. hidden items

    static func defaults(for ids: [String]) -> CustomizableToolbarLayout {
        CustomizableToolbarLayout(visible: ids, order: ids)
    }
}

enum ToolbarCustomizationStore {
    static func load(key: String, defaultIDs: [String]) -> CustomizableToolbarLayout {
        guard
            let raw = UserDefaults.standard.string(forKey: key),
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(CustomizableToolbarLayout.self, from: data)
        else {
            return .defaults(for: defaultIDs)
        }
        // Merge in new default items added after the user last customized:
        // appended at the end, visible (Firefox "Restore Defaults" style parity).
        var order = decoded.order.filter { defaultIDs.contains($0) }
        var visible = decoded.visible.filter { defaultIDs.contains($0) }
        for id in defaultIDs where !order.contains(id) {
            order.append(id)
            visible.append(id)
        }
        return CustomizableToolbarLayout(visible: visible, order: order)
    }

    static func save(_ layout: CustomizableToolbarLayout, key: String) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: key)
    }
}

/// A toolbar row that hides completely when it has no visible items, plus a
/// trailing one-click toggle (chevron) that collapses/expands the whole row.
/// Collapsed state persists per storage key.
struct CustomizableToolbarRow<Content: View>: View {
    let storageKey: String
    let items: [CustomizableToolbarItem]
    @Binding var layout: CustomizableToolbarLayout
    @Binding var isCollapsed: Bool
    @ViewBuilder let content: (String) -> Content

    private var visibleItemIDs: [String] {
        layout.order.filter { layout.visible.contains($0) }
    }

    var body: some View {
        if !isCollapsed && !visibleItemIDs.isEmpty {
            HStack(spacing: 8) {
                ForEach(visibleItemIDs, id: \.self) { id in
                    content(id)
                }
                Spacer(minLength: 0)
                ToolbarCustomizationMenu(storageKey: storageKey, items: items, layout: $layout, isCollapsed: $isCollapsed)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(FolderiumTheme.controlBackground(isSoftDark: softDarkThemeEnabled))
        } else {
            HStack(spacing: 8) {
                Spacer()
                ToolbarCustomizationMenu(storageKey: storageKey, items: items, layout: $layout, isCollapsed: $isCollapsed)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, isCollapsed ? 2 : 8)
            .background(FolderiumTheme.controlBackground(isSoftDark: softDarkThemeEnabled))
        }
    }

    @AppStorage("folderium.softDarkThemeEnabled") private var softDarkThemeEnabled: Bool = false
}

/// The gear menu: per-item show/hide toggles, drag-less reorder via
/// move-up/move-down (reliable in menus), restore defaults, and the
/// one-click collapse toggle for the whole row.
struct ToolbarCustomizationMenu: View {
    let storageKey: String
    let items: [CustomizableToolbarItem]
    @Binding var layout: CustomizableToolbarLayout
    @Binding var isCollapsed: Bool

    private func item(for id: String) -> CustomizableToolbarItem? {
        items.first { $0.id == id }
    }

    private func persist() {
        ToolbarCustomizationStore.save(layout, key: storageKey)
    }

    private func toggle(_ id: String) {
        if layout.visible.contains(id) {
            // Never hide the last visible item — the menu must stay reachable.
            guard layout.visible.count > 1 else { return }
            layout.visible.removeAll { $0 == id }
        } else {
            layout.visible.append(id)
        }
        persist()
    }

    private func moveUp(_ id: String) {
        guard let index = layout.order.firstIndex(of: id), index > 0 else { return }
        layout.order.swapAt(index, index - 1)
        persist()
    }

    private func moveDown(_ id: String) {
        guard let index = layout.order.firstIndex(of: id), index < layout.order.count - 1 else { return }
        layout.order.swapAt(index, index + 1)
        persist()
    }

    private func restoreDefaults() {
        let defaultIDs = items.map(\.id)
        layout = .defaults(for: defaultIDs)
        isCollapsed = false
        persist()
    }

    var body: some View {
        Menu {
            Section {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isCollapsed.toggle()
                    }
                } label: {
                    Label(isCollapsed ? "展開工具列" : "收合工具列", systemImage: isCollapsed ? "chevron.down" : "chevron.up")
                }
            }
            Section("顯示項目") {
                ForEach(layout.order, id: \.self) { id in
                    if let item = item(for: id) {
                        Button {
                            toggle(id)
                        } label: {
                            HStack {
                                Image(systemName: layout.visible.contains(id) ? "checkmark.square.fill" : "square")
                                Image(systemName: item.systemImage)
                                Text(item.title)
                            }
                        }
                    }
                }
            }
            Section("排序") {
                ForEach(layout.order, id: \.self) { id in
                    if let item = item(for: id) {
                        Menu(item.title) {
                            Button { moveUp(id) } label: { Label("上移", systemImage: "arrow.up") }
                            Button { moveDown(id) } label: { Label("下移", systemImage: "arrow.down") }
                        }
                    }
                }
            }
            Section {
                Button { restoreDefaults() } label: {
                    Label("還原預設", systemImage: "arrow.counterclockwise")
                }
            }
        } label: {
            Image(systemName: isCollapsed ? "rectangle.expand.vertical" : "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("自訂這條工具列：顯示/隱藏項目、排序、一鍵收合")
    }
}
