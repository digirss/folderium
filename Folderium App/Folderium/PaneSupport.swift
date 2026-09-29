// Extracted from DualPaneView.swift — pure move, no behavior change.
import SwiftUI
import Quartz

enum PaneBookmarkKey: String {
    case left, right
}

enum SandboxAccessManager {
    private static let leftBookmarkKey = "folderium.bookmark.left"
    private static let rightBookmarkKey = "folderium.bookmark.right"
    static let defaultDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory())
    
    static func saveBookmark(for pane: PaneBookmarkKey, url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey(for: pane))
        } catch {
            print("Failed to save bookmark for \(pane.rawValue): \(error)")
        }
    }
    
    static func restoreBookmark(for pane: PaneBookmarkKey) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey(for: pane)) else {
            return nil
        }
        
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            if isStale {
                saveBookmark(for: pane, url: url)
            }
            
            guard url.startAccessingSecurityScopedResource() else {
                print("Failed to access restored bookmark for \(pane.rawValue)")
                return nil
            }
            
            return url
        } catch {
            print("Failed to restore bookmark for \(pane.rawValue): \(error)")
            return nil
        }
    }
    
    private static func bookmarkKey(for pane: PaneBookmarkKey) -> String {
        switch pane {
        case .left:
            return leftBookmarkKey
        case .right:
            return rightBookmarkKey
        }
    }
}

// MARK: - Data Models

class FileTab: ObservableObject, Identifiable, Equatable {
    let id = UUID()
    @Published var name: String
    @Published var leftPath: URL
    @Published var rightPath: URL
    
    init(
        name: String = "New Tab",
        leftPath: URL = SandboxAccessManager.defaultDirectory,
        rightPath: URL = SandboxAccessManager.defaultDirectory
    ) {
        self.name = name
        self.leftPath = leftPath
        self.rightPath = rightPath
    }
    
    static func == (lhs: FileTab, rhs: FileTab) -> Bool {
        return lhs.id == rhs.id
    }
}

class TabManager: ObservableObject {
    @Published var tabs: [FileTab] = []
    
    init() {
        // Add initial tab
        addTab()
    }
    
    func addTab() {
        let tab = FileTab()
        tabs.append(tab)
    }
    
    func closeTab(_ id: UUID) {
        tabs.removeAll { $0.id == id }
    }
}

struct DetailedFileInfo {
    let name: String
    let path: String
    let size: Int
    let isDirectory: Bool
    let creationDate: Date?
    let modificationDate: Date?
    let accessDate: Date?
    let fileType: String
    let localizedType: String
    let isHidden: Bool
    let isReadable: Bool
    let isWritable: Bool
    let isExecutable: Bool
}

final class DirectoryWatcher {
    private let directoryURL: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    
    init(directoryURL: URL, onChange: @escaping () -> Void) {
        self.directoryURL = directoryURL
        self.onChange = onChange
    }
    
    func start() {
        stop()

        // open() on network volumes (SMB/NFS) can block for a long time or even hang
        // (observed: _fcntl_overlay_open stuck on smbfs). Never run it on the main
        // thread — do the open + source setup on a utility queue, then resume there.
        let dirPath = directoryURL.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let fd = open(dirPath, O_EVTONLY)
            guard fd >= 0 else { return }

            let queue = DispatchQueue(label: "folderium.directory-watcher", qos: .utility)
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
                queue: queue
            )

            src.setEventHandler { [weak self] in
                self?.onChange()
            }

            src.setCancelHandler {
                if fd >= 0 {
                    close(fd)
                }
            }

            src.resume()

            DispatchQueue.main.async { [weak self] in
                // A newer watcher may have been started meanwhile (rapid navigation);
                // drop this one instead of clobbering the newer state.
                guard let self, self.fileDescriptor == -1 else {
                    src.cancel()
                    return
                }
                self.source = src
                self.fileDescriptor = fd
            }
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }
    
    deinit {
        stop()
    }
}

struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            self.window = view.window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            self.window = nsView.window
        }
    }
}

// MARK: - Quick Look (Space) Preview Coordinator

/// Finder-style Quick Look panel driven by the active pane's selection.
/// NSWindowDelegate conformance dismisses the panel on window close.

final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSWindowDelegate {
    static let shared = QuickLookCoordinator()

    private(set) var previewURLs: [URL] = []
    private var panel: QLPreviewPanel?

    func toggle(urls: [URL], parentWindow: NSWindow?) {
        guard !urls.isEmpty else { return }
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            return
        }
        previewURLs = urls
        if let panel {
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
        } else if let shared = QLPreviewPanel.shared() {
            panel = shared
            shared.dataSource = self
            shared.delegate = self
            shared.reloadData()
            shared.makeKeyAndOrderFront(nil)
        }
        if let parentWindow {
            parentWindow.delegate = self
        }
    }

    func refresh(urls: [URL]) {
        guard let panel, panel.isVisible else {
            previewURLs = urls
            return
        }
        let previousURL = previewURLs.isEmpty ? nil : previewURLs[panel.currentPreviewItemIndex]
        previewURLs = urls
        panel.reloadData()
        if let previousURL,
           let index = urls.firstIndex(of: previousURL),
           index != panel.currentPreviewItemIndex {
            panel.currentPreviewItemIndex = index
        }
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        let url = previewURLs[index]
        return url as NSURL
    }

    // MARK: QLPreviewPanelDelegate / NSWindowDelegate

    /// Pressing Space again while the panel is key must close it (Finder behavior).
    func previewPanel(_ panel: QLPreviewPanel, handle event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.keyCode == 49,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).intersection([.command, .option, .control, .shift]).isEmpty {
            panel.orderOut(nil)
            return true
        }
        return false
    }

    func windowDidClose(_ notification: Notification) {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        }
    }
}

// MARK: - Empty Area Context Menu

struct StatusBarView: View {
    @AppStorage("folderium.softDarkThemeEnabled") private var softDarkThemeEnabled: Bool = false
    @AppStorage("folderium.globalFontSize") private var globalFontSize: Double = 12
    let files: [FileItem]
    
    private var folderCount: Int {
        files.filter { $0.isDirectory }.count
    }
    
    private var fileCount: Int {
        files.filter { !$0.isDirectory }.count
    }
    
    private var totalSize: Int64 {
        files.filter { !$0.isDirectory }.reduce(0) { $0 + $1.size }
    }
    
    private var totalSizeString: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    private var statusFont: Font {
        .system(size: CGFloat(max(globalFontSize - 2, 10)))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack {
                // File and folder counts
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(statusFont)
                            .foregroundColor(.blue)
                        Text("\(folderCount)")
                            .font(statusFont)
                            .fontWeight(.medium)
                        Text("folders")
                            .font(statusFont)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack(spacing: 4) {
                        Image(systemName: "doc")
                            .font(statusFont)
                            .foregroundColor(.secondary)
                        Text("\(fileCount)")
                            .font(statusFont)
                            .fontWeight(.medium)
                        Text("files")
                            .font(statusFont)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Total size
                HStack(spacing: 4) {
                    Image(systemName: "externaldrive")
                        .font(statusFont)
                        .foregroundColor(.orange)
                    Text(totalSizeString)
                        .font(statusFont)
                        .fontWeight(.medium)
                    Text("total")
                        .font(statusFont)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(FolderiumTheme.controlBackground(isSoftDark: softDarkThemeEnabled))
            
            // Bottom border
            Divider()
        }
    }
}
