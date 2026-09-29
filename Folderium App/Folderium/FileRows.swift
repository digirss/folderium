// Extracted from DualPaneView.swift — pure move, no behavior change.
import SwiftUI

struct ColumnReorderDropDelegate: DropDelegate {
    let target: FilePaneView.FileColumn
    @Binding var order: [FilePaneView.FileColumn]
    @Binding var dragged: FilePaneView.FileColumn?
    @Binding var dragOver: FilePaneView.FileColumn?
    let onSave: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target,
              let from = order.firstIndex(of: dragged),
              let to = order.firstIndex(of: target) else { return }

        dragOver = target

        if order[to] != dragged {
            withAnimation(.easeInOut(duration: 0.12)) {
                order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dragOver == target {
            dragOver = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let didDrop = dragged != nil
        dragged = nil
        dragOver = nil
        if didDrop {
            onSave()
        }
        return didDrop
    }
}

struct PinnedLocationDropDelegate: DropDelegate {
    let targetPath: String
    @Binding var pinnedPaths: [String]
    @Binding var draggedPath: String?

    func dropEntered(info: DropInfo) {
        guard let draggedPath,
              draggedPath != targetPath,
              let fromIndex = pinnedPaths.firstIndex(of: draggedPath),
              let toIndex = pinnedPaths.firstIndex(of: targetPath) else { return }

        if pinnedPaths[toIndex] != draggedPath {
            withAnimation(.easeInOut(duration: 0.12)) {
                pinnedPaths.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let dropped = draggedPath != nil
        draggedPath = nil
        return dropped
    }

    func dropExited(info: DropInfo) {}
}

struct FileRowView: View {
    @AppStorage("folderium.softDarkThemeEnabled") private var softDarkThemeEnabled: Bool = false
    @AppStorage("folderium.globalFontSize") private var globalFontSize: Double = 12
    @FocusState private var inlineRenameFieldFocused: Bool
    @State private var isNameTooltipVisible: Bool = false
    private static let rowDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
    
    let file: FileItem
    let isSelected: Bool
    let selectionCount: Int
    let isPartOfSelection: Bool
    let isStriped: Bool
    let isInlineRenaming: Bool
    @Binding var inlineRenameText: String
    let visibleColumns: [FilePaneView.FileColumn]
    let columnWidths: [FilePaneView.FileColumn: CGFloat]
    let resolvedColumnWidths: [FilePaneView.FileColumn: CGFloat]
    let onSelectWithModifiers: (Bool, Bool) -> Void
    let onDoubleClick: () -> Void
    let onCommitInlineRename: () -> Void
    let onCancelInlineRename: () -> Void
    let onFileOperation: () -> Void
    let onRecordMoveBatch: (_ title: String, _ pairs: [(from: URL, to: URL)]) -> Void
    /// Evaluated lazily when a context menu actually opens — never during row
    /// construction (clipboard reads are XPC round trips).
    let canPasteFromClipboard: () -> Bool
    let onPasteIntoFolder: (URL) -> Void
    let onBulkCompress: () -> Void
    let onDropToFolder: (URL?, [NSItemProvider]) -> Bool
    let selectedURLsProvider: () -> [URL]
    let onFocus: () -> Void
    var onBeginInlineRename: ((URL) -> Void)? = nil
    private static let internalDragPrefix = "folderium-internal-drag-v1"
    
    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.3)
        } else if isStriped {
            return FolderiumTheme.stripedRowBackground(isSoftDark: softDarkThemeEnabled)
        } else {
            return Color.clear
        }
    }
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(visibleColumns, id: \.self) { column in
                columnValueView(for: column)
                    .frame(width: width(for: column), alignment: .leading)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(backgroundColor)
        .contentShape(Rectangle())
        .clipped()
        .overlay {
            RowMouseCaptureView { event in
                let modifierFlags = event.modifierFlags
                let isCommandPressed = modifierFlags.contains(.command)
                let isShiftPressed = modifierFlags.contains(.shift)
                let shouldPreserveMultiSelection =
                    !isCommandPressed &&
                    !isShiftPressed &&
                    selectionCount > 1 &&
                    isPartOfSelection

                if !shouldPreserveMultiSelection {
                    onSelectWithModifiers(isCommandPressed, isShiftPressed)
                }
                onFocus()

                if event.clickCount >= 2 {
                    onDoubleClick()
                }
            }
        }
        .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { providers in
            // If dropped over a non-folder row, fall back to pane's current path.
            onDropToFolder(file.isDirectory ? file.url : nil, providers)
        }
        .contextMenu {
            FileContextMenu(
                file: file, 
                currentSelectionCount: selectionCount,
                onFileOperation: onFileOperation, 
                onSelect: {
                    onSelectWithModifiers(false, false)
                },
                onRecordMoveBatch: onRecordMoveBatch,
                // FileContextMenu takes a closure too: its paste item must be
                // evaluated when the menu opens, not when the row is built.
                canPasteFromClipboard: { canPasteFromClipboard() },
                onPasteIntoFolder: onPasteIntoFolder,
                onBulkCompress: onBulkCompress,
                onBeginInlineRename: { url in
                    onBeginInlineRename?(url)
                }
            )
        }
        .onDrag {
            let draggedURLs = dragSelectionURLs()
            let payload = Self.internalDragPrefix + "\n" + draggedURLs.map(\.path).joined(separator: "\n")
            return NSItemProvider(object: payload as NSString)
        } preview: {
            dragPreview
        }
        .onAppear {
            if isInlineRenaming {
                inlineRenameFieldFocused = true
            }
        }
        .onChange(of: isInlineRenaming) { _, newValue in
            inlineRenameFieldFocused = newValue
            if newValue {
                isNameTooltipVisible = false
                selectBaseNameInInlineRenameField()
            }
        }
    }

    /// Finder-like: when inline editing begins, select only the base name and
    /// leave the extension unselected (dotfiles without an inner dot select all).
    private func selectBaseNameInInlineRenameField() {
        let nameText = inlineRenameText
        let name = nameText as NSString
        let ext = name.pathExtension
        let selectedLength: Int
        if ext.isEmpty || (nameText.hasPrefix(".") && !nameText.dropFirst().contains(".")) {
            selectedLength = name.length
        } else {
            selectedLength = name.length - ext.count - 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                  editor.string == nameText else { return }
            editor.selectedRange = NSRange(location: 0, length: selectedLength)
        }
    }
    
    private func formatDate(_ date: Date?) -> String {
        guard let date = date else { return "--" }
        return Self.rowDateFormatter.string(from: date)
    }

    private func width(for column: FilePaneView.FileColumn) -> CGFloat {
        if let resolved = resolvedColumnWidths[column] {
            return max(resolved, column.minWidth)
        }
        let defaultWidth = FilePaneView.FileColumn.defaultWidths[column] ?? 120
        return max(columnWidths[column] ?? defaultWidth, column.minWidth)
    }

    @ViewBuilder
    private func columnValueView(for column: FilePaneView.FileColumn) -> some View {
        switch column {
        case .name:
            HStack {
                Image(systemName: file.iconName)
                    .foregroundColor(file.iconColor)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 16)

                if isInlineRenaming {
                    TextField("", text: $inlineRenameText)
                        .textFieldStyle(.roundedBorder)
                        .focused($inlineRenameFieldFocused)
                        .onSubmit {
                            onCommitInlineRename()
                        }
                        .onExitCommand {
                            onCancelInlineRename()
                        }
                } else {
                    Text(file.name)
                        .font(.system(size: CGFloat(globalFontSize)))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .onHover { hovering in
                            isNameTooltipVisible = hovering
                        }
                        .popover(isPresented: $isNameTooltipVisible, arrowEdge: .bottom) {
                            Text(file.url.lastPathComponent)
                                .font(.system(size: max(globalFontSize - 1, 10)))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                }
            }
        case .type:
            Text(file.localizedType)
                .font(.system(size: CGFloat(globalFontSize)))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        case .size:
            Text(file.isDirectory ? "--" : file.sizeString)
                .font(.system(size: CGFloat(globalFontSize)))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .modified:
            Text(formatDate(file.modificationDate))
                .font(.system(size: CGFloat(globalFontSize)))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func dragSelectionURLs() -> [URL] {
        if isPartOfSelection, selectionCount > 0 {
            return selectedURLsProvider()
        }
        return [file.url]
    }

    @ViewBuilder
    private var dragPreview: some View {
        let draggedURLs = dragSelectionURLs()
        HStack(spacing: 8) {
            Image(systemName: draggedURLs.count > 1 ? "doc.on.doc.fill" : file.iconName)
                .foregroundColor(draggedURLs.count > 1 ? .blue : file.iconColor)
                .symbolRenderingMode(.hierarchical)

            if draggedURLs.count > 1 {
                Text("\(draggedURLs.count) items")
                    .font(.system(size: max(globalFontSize - 1, 11), weight: .semibold))
            } else {
                Text(file.name)
                    .font(.system(size: max(globalFontSize - 1, 11), weight: .semibold))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(FolderiumTheme.controlBackground(isSoftDark: softDarkThemeEnabled))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
    }
}

struct SearchResultRowView: View {
    @AppStorage("folderium.softDarkThemeEnabled") private var softDarkThemeEnabled: Bool = false
    @AppStorage("folderium.globalFontSize") private var globalFontSize: Double = 12
    let result: SearchResult
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: result.isDirectory ? "folder.fill" : "doc")
                    .foregroundColor(result.isDirectory ? .blue : .secondary)
                    .frame(width: 16)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.name)
                        .font(.system(size: CGFloat(globalFontSize)))
                        .lineLimit(1)
                    
                    Text(result.url.path)
                        .font(.system(size: CGFloat(max(globalFontSize - 2, 10))))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                if !result.isDirectory {
                    Text(result.sizeString)
                        .font(.system(size: CGFloat(max(globalFontSize - 2, 10))))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
            .contentShape(Rectangle())
            .overlay {
                RowMouseCaptureView { event in
                    onSelect()
                    if event.clickCount >= 2 {
                        onOpen()
                    }
                }
            }
            
            Divider()
                .background(FolderiumTheme.separator(isSoftDark: softDarkThemeEnabled))
        }
    }
}

struct RowMouseCaptureView: NSViewRepresentable {
    let onMouseDown: (NSEvent) -> Void

    func makeNSView(context: Context) -> MouseCaptureNSView {
        let view = MouseCaptureNSView()
        view.onMouseDown = onMouseDown
        return view
    }

    func updateNSView(_ nsView: MouseCaptureNSView, context: Context) {
        nsView.onMouseDown = onMouseDown
    }

    final class MouseCaptureNSView: NSView {
        var onMouseDown: ((NSEvent) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override var acceptsFirstResponder: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            self
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            onMouseDown?(event)
        }

        // Let right-click pass through so SwiftUI context menus still work.
        override func rightMouseDown(with event: NSEvent) {
            nextResponder?.rightMouseDown(with: event)
        }
    }
}

// MARK: - Sandbox Access
