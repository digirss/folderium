// Extracted from DualPaneView.swift — pure move, no behavior change.
import SwiftUI

struct FileItem {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64
    let sizeString: String
    let modificationDate: Date?
    let fileExtension: String
    let localizedType: String
    
    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        self.fileExtension = url.pathExtension.lowercased()
        
        do {
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey, .localizedTypeDescriptionKey])
            var detectedIsDirectory = resourceValues.isDirectory ?? false
            let isSymbolicLink = resourceValues.isSymbolicLink ?? false
            
            // Special handling for OneDrive and other cloud storage folders
            // These are often symbolic links or special folders that don't report as directories
            if name.lowercased().contains("onedrive") || 
               name.lowercased().contains("dropbox") || 
               name.lowercased().contains("google drive") ||
               name.lowercased().contains("icloud") {
                
                // Force cloud storage folders to be treated as directories for display purposes
                // but they will be handled specially in double-click
                detectedIsDirectory = true
                print("Cloud storage folder detected: \(name), treating as directory for display")
            }
            
            self.isDirectory = detectedIsDirectory
            self.isSymbolicLink = isSymbolicLink
            self.size = Int64(resourceValues.fileSize ?? 0)
            self.modificationDate = resourceValues.contentModificationDate
            self.localizedType = resourceValues.localizedTypeDescription ?? Self.defaultTypeName(for: fileExtension, isDirectory: detectedIsDirectory)
        } catch {
            print("Error getting resource values for \(url): \(error)")
            self.isDirectory = false
            self.isSymbolicLink = false
            self.size = 0
            self.modificationDate = nil
            self.localizedType = Self.defaultTypeName(for: fileExtension, isDirectory: false)
        }
        
        if isDirectory {
            self.sizeString = ""
        } else {
            self.sizeString = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
    }
    
    private static func defaultTypeName(for fileExtension: String, isDirectory: Bool) -> String {
        if isDirectory { return "Folder" }
        if fileExtension.isEmpty { return "File" }
        return fileExtension.uppercased() + " File"
    }
    
    var iconName: String {
        if isDirectory {
            return isSymbolicLink ? "folder.badge.plus" : "folder.fill"
        }
        
        switch fileExtension {
        // Images
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif":
            return "photo"
        case "svg":
            return "photo.artframe"
        
        // Documents
        case "pdf":
            return "doc.richtext"
        case "doc", "docx":
            return "doc.text"
        case "xls", "xlsx":
            return "tablecells"
        case "ppt", "pptx":
            return "rectangle.stack"
        case "txt", "rtf":
            return "doc.plaintext"
        case "md", "markdown":
            return "doc.text"
        
        // Code files
        case "swift":
            return "swift"
        case "py":
            return "p.circle"
        case "js", "jsx":
            return "j.circle"
        case "ts", "tsx":
            return "t.circle"
        case "html", "htm":
            return "globe"
        case "css":
            return "paintbrush"
        case "json":
            return "curlybraces"
        case "xml":
            return "doc.plaintext"
        case "yaml", "yml":
            return "y.circle"
        case "sh", "bash":
            return "terminal"
        case "c", "cpp", "h", "hpp":
            return "c.circle"
        case "java":
            return "j.circle"
        case "php":
            return "p.circle"
        case "rb":
            return "r.circle"
        case "go":
            return "g.circle"
        case "rs":
            return "r.circle"
        
        // Archives
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz":
            return "archivebox"
        
        // Audio
        case "mp3", "wav", "aac", "flac", "m4a", "ogg":
            return "music.note"
        
        // Video
        case "mp4", "mov", "avi", "mkv", "wmv", "flv", "webm":
            return "video"
        
        // System files
        case "dmg", "pkg", "app":
            return "app"
        case "exe", "msi":
            return "exclamationmark.triangle"
        
        // Default
        default:
            return "doc"
        }
    }
    
    var iconColor: Color {
        if isDirectory {
            return .blue
        }
        
        switch fileExtension {
        // Images
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "svg":
            return .green
        
        // Documents
        case "pdf":
            return .red
        case "doc", "docx", "txt", "rtf", "md", "markdown":
            return .blue
        case "xls", "xlsx":
            return .green
        case "ppt", "pptx":
            return .orange
        
        // Code files
        case "swift", "py", "js", "jsx", "ts", "tsx", "html", "htm", "css", "json", "xml", "yaml", "yml", "sh", "bash", "c", "cpp", "h", "hpp", "java", "php", "rb", "go", "rs":
            return .purple
        
        // Archives
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz":
            return .brown
        
        // Audio
        case "mp3", "wav", "aac", "flac", "m4a", "ogg":
            return .pink
        
        // Video
        case "mp4", "mov", "avi", "mkv", "wmv", "flv", "webm":
            return .purple
        
        // System files
        case "dmg", "pkg", "app":
            return .blue
        case "exe", "msi":
            return .red
        
        // Default
        default:
            return .secondary
        }
    }
}
