// Extracted from DualPaneView.swift — pure move, no behavior change.
import SwiftUI

struct FileContextMenu: View {
    let file: FileItem
    let currentSelectionCount: Int
    let onFileOperation: () -> Void
    let onSelect: () -> Void
    let onRecordMoveBatch: (_ title: String, _ pairs: [(from: URL, to: URL)]) -> Void
    let canPasteFromClipboard: () -> Bool
    let onPasteIntoFolder: (URL) -> Void
    let onBulkCompress: () -> Void
    var onBeginInlineRename: ((URL) -> Void)? = nil
    
    enum ActionType {
        case delete, moveToTrash
    }
    
    private var openWithApplications: [URL] {
        guard !file.isDirectory else { return [] }
        return NSWorkspace.shared
            .urlsForApplications(toOpen: file.url)
            .filter { $0.pathExtension.lowercased() == "app" }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button("Open") {
                onSelect()
                openFile()
            }
            
            if !file.isDirectory {
                Menu("Open With") {
                    if openWithApplications.isEmpty {
                        Text("No compatible apps found")
                    } else {
                        ForEach(Array(openWithApplications.prefix(12)), id: \.path) { appURL in
                            Button(displayName(for: appURL)) {
                                onSelect()
                                openFile(with: appURL)
                            }
                        }
                    }
                    
                    Divider()
                    
                    Button("Other...") {
                        onSelect()
                        openFileWithOtherAppPicker()
                    }
                }
            }
            
            Button("Open in New Window") {
                openInNewWindow()
            }
            
            Divider()
            
            Button("Cut") {
                cutToClipboard()
            }
            
            Button("Copy") {
                copyToClipboard()
            }
            
            Button("Copy path") {
                copyPaths()
            }
            
            if file.isDirectory {
                Button("Paste Into Folder") {
                    onPasteIntoFolder(file.url)
                }
                .disabled(!canPasteFromClipboard())
            }
            
            Divider()
            
            Button(currentSelectionCount > 1 ? "Compress Selected (\(currentSelectionCount))" : "Compress") {
                if currentSelectionCount > 1 {
                    onBulkCompress()
                } else {
                    compressFile()
                }
            }
            
            let archiveSupport = ArchiveManager.shared.archiveSupportInfo(for: file.url)
            if archiveSupport.isArchive {
                Button(archiveSupport.canExtract
                    ? "Extract (\(archiveSupport.formatLabel) - Supported)"
                    : "Extract (\(archiveSupport.formatLabel) - Unsupported)") {
                    extractFile()
                }
                .disabled(!archiveSupport.canExtract)
            }
            
            Button("Reveal in Finder") {
                revealInFinder()
            }
            
            Divider()
            
            Button("Rename") {
                onSelect()
                // Finder-like: edit in place, no modal dialog.
                onBeginInlineRename?(file.url)
            }
            
            Button("Delete") {
                onSelect()
                showNSAlert(for: .moveToTrash)
            }
            
            Button("Delete Permanently") {
                onSelect()
                showNSAlert(for: .delete)
            }
            
            Divider()
            
            Button("Properties") {
                getInfo()
            }
        }
    }
    
    private func showNSAlert(for actionType: ActionType) {
        // Get the current file name from the URL to avoid issues with stale FileItem
        let currentFileName = file.url.lastPathComponent
        
        let alert = NSAlert()
        
        switch actionType {
        case .delete:
            alert.messageText = "Delete Permanently"
            alert.informativeText = "Are you sure you want to permanently delete '\(currentFileName)'? This action cannot be undone."
            alert.addButton(withTitle: "Delete")
        case .moveToTrash:
            alert.messageText = "Move to Trash"
            alert.informativeText = "Are you sure you want to move '\(currentFileName)' to Trash?"
            alert.addButton(withTitle: "Move to Trash")
        }
        
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            performAction(for: actionType)
        }
    }
    
    private func performAction(for actionType: ActionType) {
        switch actionType {
        case .delete:
            deleteFile()
        case .moveToTrash:
            moveToTrash()
        }
    }
    
    private func openFile() {
        NSWorkspace.shared.open(file.url)
    }
    
    private func openInNewWindow() {
        NSWorkspace.shared.open(file.url)
    }
    
    private func openFile(with applicationURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([file.url], withApplicationAt: applicationURL, configuration: configuration) { _, error in
            guard let error else { return }
            Task { @MainActor in
                FileOperationErrorCenter.shared.report(
                    title: "開啟失敗",
                    message: error.localizedDescription)
            }
        }
    }
    
    private func openFileWithOtherAppPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose an application to open this file."
        panel.prompt = "Open"
        
        if panel.runModal() == .OK, let appURL = panel.url {
            openFile(with: appURL)
        }
    }
    
    private func displayName(for appURL: URL) -> String {
        FileManager.default.displayName(atPath: appURL.path)
    }
    
    private func compressFile() {
        Task {
            do {
                let parentDirectory = file.url.deletingLastPathComponent()
                let archiveName = file.name + ".zip"
                let archiveURL = parentDirectory.appendingPathComponent(archiveName)
                
                print("Individual compress: Compressing \(file.name) to \(archiveURL.path)")
                
                try await ArchiveManager.shared.compressFiles([file.url], to: archiveURL, format: .zip)
                
                print("Individual compression completed successfully")
                
                await MainActor.run {
                    onFileOperation() // Refresh the file list
                }
            } catch {
                await MainActor.run {
                    FileOperationErrorCenter.shared.report(
                        title: "壓縮失敗",
                        message: error.localizedDescription)
                }
            }
        }
    }
    
    private func extractFile() {
        Task {
            do {
                let fileManager = FileManager.default
                let parentDirectory = file.url.deletingLastPathComponent()
                let baseName = file.name.replacingOccurrences(of: file.url.pathExtension, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
                
                // Generate a unique folder name to avoid conflicts
                var extractedFolderName = baseName
                var counter = 1
                var extractedFolderURL = parentDirectory.appendingPathComponent(extractedFolderName)
                
                // Check if folder already exists and find a unique name
                while fileManager.fileExists(atPath: extractedFolderURL.path) {
                    extractedFolderName = "\(baseName) (\(counter))"
                    extractedFolderURL = parentDirectory.appendingPathComponent(extractedFolderName)
                    counter += 1
                }
                
                print("Extracting \(file.name) to \(extractedFolderURL.path)")
                
                // Create the extraction directory
                try fileManager.createDirectory(at: extractedFolderURL, withIntermediateDirectories: true)
                print("Created extraction directory: \(extractedFolderURL.path)")
                
                try await ArchiveManager.shared.extractArchive(at: file.url, to: extractedFolderURL)
                print("Extraction completed successfully")
                
                await MainActor.run {
                    onFileOperation() // Refresh the file list
                }
            } catch {
                print("Error extracting file: \(error)")
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Extraction Failed"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "OK")
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
    
    private func getInfo() {
        // Show file info dialog
        Task {
            do {
                let fileInfo = try await getFileInfo(for: file.url)
                await MainActor.run {
                    showFileInfoDialog(fileInfo: fileInfo)
                }
            } catch {
                await MainActor.run {
                    FileOperationErrorCenter.shared.report(
                        title: "讀取檔案資訊失敗",
                        message: error.localizedDescription)
                }
            }
        }
    }
    
    private func getFileInfo(for url: URL) async throws -> DetailedFileInfo {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let resourceValues = try url.resourceValues(forKeys: [
                        .nameKey,
                        .fileSizeKey,
                        .isDirectoryKey,
                        .creationDateKey,
                        .contentModificationDateKey,
                        .contentAccessDateKey,
                        .fileResourceTypeKey,
                        .localizedTypeDescriptionKey,
                        .isHiddenKey,
                        .isReadableKey,
                        .isWritableKey,
                        .isExecutableKey
                    ])
                    
                    let fileInfo = DetailedFileInfo(
                        name: resourceValues.name ?? url.lastPathComponent,
                        path: url.path,
                        size: resourceValues.fileSize ?? 0,
                        isDirectory: resourceValues.isDirectory ?? false,
                        creationDate: resourceValues.creationDate,
                        modificationDate: resourceValues.contentModificationDate,
                        accessDate: resourceValues.contentAccessDate,
                        fileType: resourceValues.fileResourceType?.rawValue ?? "Unknown",
                        localizedType: resourceValues.localizedTypeDescription ?? "Unknown",
                        isHidden: resourceValues.isHidden ?? false,
                        isReadable: resourceValues.isReadable ?? false,
                        isWritable: resourceValues.isWritable ?? false,
                        isExecutable: resourceValues.isExecutable ?? false
                    )
                    
                    continuation.resume(returning: fileInfo)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func showFileInfoDialog(fileInfo: DetailedFileInfo) {
        let alert = NSAlert()
        alert.messageText = "File Information"
        alert.informativeText = formatFileInfo(fileInfo)
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .informational
        alert.runModal()
    }
    
    private func formatFileInfo(_ info: DetailedFileInfo) -> String {
        let sizeString = info.isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: Int64(info.size), countStyle: .file)
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        
        var infoText = "Name: \(info.name)\n"
        infoText += "Path: \(info.path)\n"
        infoText += "Size: \(sizeString)\n"
        infoText += "Kind: \(info.localizedType)\n"
        infoText += "Type: \(info.fileType)\n"
        
        if let creationDate = info.creationDate {
            infoText += "Created: \(dateFormatter.string(from: creationDate))\n"
        }
        if let modificationDate = info.modificationDate {
            infoText += "Modified: \(dateFormatter.string(from: modificationDate))\n"
        }
        if let accessDate = info.accessDate {
            infoText += "Accessed: \(dateFormatter.string(from: accessDate))\n"
        }
        
        infoText += "\nPermissions:\n"
        infoText += "Readable: \(info.isReadable ? "Yes" : "No")\n"
        infoText += "Writable: \(info.isWritable ? "Yes" : "No")\n"
        infoText += "Executable: \(info.isExecutable ? "Yes" : "No")\n"
        infoText += "Hidden: \(info.isHidden ? "Yes" : "No")"
        
        return infoText
    }
    
    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }
    
    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([file.url as NSURL])
        pasteboard.setString(file.url.path, forType: .string)
    }
    
    private func cutToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([file.url as NSURL])
        pasteboard.setString("cut", forType: NSPasteboard.PasteboardType("public.folderium.cut"))
        pasteboard.setString(file.url.path, forType: .string)
    }
    
    private func copyPaths() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(file.url.path, forType: .string)
    }
    
    private func moveToTrash() {
        // Trashing hits the filesystem (and can stall on slow volumes) — do it
        // off the main actor, then refresh on main.
        let targetURL = file.url
        Task {
            let trashError = await Task.detached(priority: .userInitiated) { () -> Error? in
                do {
                    try FileManager.default.trashItem(at: targetURL, resultingItemURL: nil)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let trashError {
                FileOperationErrorCenter.shared.report(
                    title: "丟入垃圾桶失敗",
                    message: trashError.localizedDescription)
            }
            onFileOperation() // Refresh the file list
        }
    }
    
    private func deleteFile() {
        // Deletion can stall on slow volumes — keep it off the main actor.
        let targetURL = file.url
        Task {
            let deleteError = await Task.detached(priority: .userInitiated) { () -> Error? in
                do {
                    try FileManager.default.removeItem(at: targetURL)
                    return nil
                } catch {
                    return error
                }
            }.value
            if let deleteError {
                FileOperationErrorCenter.shared.report(
                    title: "刪除失敗",
                    message: deleteError.localizedDescription)
            }
            onFileOperation() // Refresh the file list
        }
    }
}

struct EmptyAreaContextMenu: View {
    let currentPath: URL
    let canPasteFromClipboard: () -> Bool
    let onPaste: () -> Void
    let onFileOperation: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button("New Folder") {
                createNewFolder()
            }
            
            Button("New File") {
                createNewFileWithDialog()
            }
            
            Button("Paste") {
                onPaste()
            }
            .disabled(!canPasteFromClipboard())
            
            Divider()
            
            Button("Refresh") {
                onFileOperation()
            }
            
            Divider()
            
            Button("Reveal in Finder") {
                revealInFinder()
            }
            
            Button("Copy Path") {
                copyFolderPath()
            }
            
            Divider()
            
            Button("Analyze Disk Usage") {
                analyzeDiskUsage()
            }
            
            Divider()
            
            Button("Properties") {
                getInfo()
            }
        }
    }
    
    private func createNewFolder() {
        let folderName = "New Folder"
        let targetPath = currentPath
        
        // Name probing + mkdir can stall on slow volumes — keep off the UI thread.
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (Bool, Error?) in
                var finalName = folderName
                var counter = 1
                
                // Find a unique name
                while FileManager.default.fileExists(atPath: targetPath.appendingPathComponent(finalName).path) {
                    finalName = "\(folderName) \(counter)"
                    counter += 1
                }
                
                do {
                    try FileManager.default.createDirectory(
                        at: targetPath.appendingPathComponent(finalName),
                        withIntermediateDirectories: true
                    )
                    return (true, nil)
                } catch {
                    return (false, error)
                }
            }.value
            if let error = result.1 {
                FileOperationErrorCenter.shared.report(
                    title: "新增資料夾失敗",
                    message: error.localizedDescription)
            }
            if result.0 {
                onFileOperation()
            }
        }
    }
    
    private func createNewFile(named fileName: String = "New File.txt") {
        let targetPath = currentPath
        
        // Name probing + file creation can stall on slow volumes — off the UI thread.
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (Bool, Error?) in
                var finalName = fileName
                var counter = 1
                
                // If no extension provided, add .txt
                if !fileName.contains(".") {
                    finalName = "\(fileName).txt"
                }
                
                // Find a unique name
                while FileManager.default.fileExists(atPath: targetPath.appendingPathComponent(finalName).path) {
                    if let lastDotIndex = fileName.lastIndex(of: ".") {
                        let nameWithoutExt = String(fileName[..<lastDotIndex])
                        let ext = String(fileName[lastDotIndex...])
                        finalName = "\(nameWithoutExt) \(counter)\(ext)"
                    } else {
                        finalName = "\(fileName) \(counter).txt"
                    }
                    counter += 1
                }
                
                do {
                    try "".write(
                        to: targetPath.appendingPathComponent(finalName),
                        atomically: true,
                        encoding: .utf8
                    )
                    return (true, nil)
                } catch {
                    return (false, error)
                }
            }.value
            if let error = result.1 {
                FileOperationErrorCenter.shared.report(
                    title: "新增檔案失敗",
                    message: error.localizedDescription)
            }
            if result.0 {
                onFileOperation()
            }
        }
    }
    
    private func createNewFileWithDialog() {
        // Show new file dialog using NSAlert (same approach as rename)
        let alert = NSAlert()
        alert.messageText = "New File"
        alert.informativeText = "Enter the name for the new file:"
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = ""
        textField.placeholderString = "File name (e.g., MyFile.txt)"
        textField.selectText(nil)
        
        alert.accessoryView = textField
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let fileName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fileName.isEmpty {
                createNewFile(named: fileName)
            }
        }
    }
    
    private func getInfo() {
        // Show folder info
        NSWorkspace.shared.activateFileViewerSelecting([currentPath])
    }
    
    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([currentPath])
    }
    
    private func copyFolderPath() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(currentPath.path, forType: .string)
    }
    
    private func analyzeDiskUsage() {
        // Open Disk Utility or show folder size
        Task {
            do {
                let size = try await calculateFolderSize(currentPath)
                await MainActor.run {
                    showDiskUsageAlert(size: size)
                }
            } catch {
                await MainActor.run {
                    FileOperationErrorCenter.shared.report(
                        title: "計算資料夾大小失敗",
                        message: error.localizedDescription)
                }
            }
        }
    }
    
    private func calculateFolderSize(_ url: URL) async throws -> Int64 {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var totalSize: Int64 = 0
                
                let fileManager = FileManager.default
                let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
                
                while let fileURL = enumerator?.nextObject() as? URL {
                    do {
                        let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                        totalSize += Int64(resourceValues.fileSize ?? 0)
                    } catch {
                        // Skip files that can't be read
                        continue
                    }
                }
                
                continuation.resume(returning: totalSize)
            }
        }
    }
    
    private func showDiskUsageAlert(size: Int64) {
        let alert = NSAlert()
        alert.messageText = "Disk Usage Analysis"
        alert.informativeText = "Folder: \(currentPath.lastPathComponent)\nSize: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Status Bar View
