import SwiftUI
import AgentClient
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A photo (or, from history, an attachment of unknown kind) on a message: from its bytes when this phone sent it, otherwise read from
/// the host (`APIPaths.attachments`) by its id. Falls back to the file's name.
struct AttachmentThumbnail: View {
    let file: FileAttachment
    let load: ((String) async -> Data?)?

    @State private var data: Data?
    @State private var failed = false

    var body: some View {
        Group {
            if let image = Self.image(from: data ?? file.data) {
                image
                    .resizable()
                    .scaledToFill()
            } else if failed || (file.attachmentId == nil || load == nil) {
                VStack(spacing: 4) {
                    Image(systemName: file.symbolName)
                    Text(file.name).font(.caption2).lineLimit(1)
                }
                .foregroundColor(.secondary)
                .padding(6)
            } else {
                ProgressView()
            }
        }
        .frame(width: 96, height: 72)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(file.name)
        .task(id: file.attachmentId) {
            guard file.data == nil, data == nil, let id = file.attachmentId, let load else { return }
            // A file that isn't a picture (history without a type) falls back to its icon and name.
            if let loaded = await load(id), Self.image(from: loaded) != nil { data = loaded } else { failed = true }
        }
    }

    static func image(from data: Data?) -> Image? {
        guard let data else { return nil }
        #if canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #elseif canImport(AppKit)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return nil
        #endif
    }
}
