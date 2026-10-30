import Foundation
import AgentClient
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Reads the files chosen in the Files picker (`fileImporter`) into attachments. The
/// security-scoped reads happen off the main thread; a file that is too big, a folder or
/// an unreadable file is skipped with a reason, and the others still come through.
enum FileImportReader {
    struct Result {
        var files: [FileAttachment] = []
        /// Short, person-readable reasons, one per skipped file ("report.pdf is over 25 MB").
        var skipped: [String] = []
    }

    static func read(_ urls: [URL], maxBytes: Int = 25 * 1024 * 1024) async -> Result {
        await Task.detached(priority: .userInitiated) {
            var result = Result()
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let name = url.lastPathComponent
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentTypeKey])
                if values?.isDirectory == true {
                    result.skipped.append("\(name) is a folder")
                    continue
                }
                if let size = values?.fileSize, size > maxBytes {
                    result.skipped.append("\(name) is over \(maxBytes / (1024 * 1024)) MB")
                    continue
                }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                    result.skipped.append("\(name) couldn't be read")
                    continue
                }
                if data.count > maxBytes {
                    result.skipped.append("\(name) is over \(maxBytes / (1024 * 1024)) MB")
                    continue
                }
                let type = values?.contentType?.preferredMIMEType ?? "application/octet-stream"
                result.files.append(FileAttachment(name: name, size: data.count, type: type, data: data))
            }
            return result
        }.value
    }
}
