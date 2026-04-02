import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Block Renderer

/// Renders an array of content blocks using native SwiftUI components.
/// Unknown block types are silently skipped for forward compatibility.
public struct ContentBlockRenderer: View {
    let blocks: [ContentBlock]
    let config: ChatWidgetConfig
    var onAction: ((BlockAction) -> Void)?

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                renderBlock(block)
            }
        }
    }

    @ViewBuilder
    private func renderBlock(_ block: ContentBlock) -> some View {
        switch block {
        case .card(let b): CardBlockView(block: b, config: config, onAction: onAction)
        case .cardList(let b): CardListBlockView(block: b, config: config, onAction: onAction)
        case .actionButtons(let b): ActionButtonsBlockView(block: b, onAction: onAction)
        case .callout(let b): CalloutBlockView(block: b)
        case .image(let b): ImageBlockView(block: b)
        case .divider: Divider().padding(.vertical, 2)
        case .table(let b): TableBlockView(block: b)
        case .code(let b): CodeBlockView(block: b)
        case .file(let b): FileBlockView(block: b)
        case .collapsible(let b): CollapsibleBlockView(block: b)
        case .status(let b): StatusBlockView(block: b)
        case .location(let b): LocationBlockView(block: b)
        case .unknown: EmptyView()
        }
    }
}

// MARK: - Card

struct CardBlockView: View {
    let block: CardBlock
    let config: ChatWidgetConfig
    var onAction: ((BlockAction) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let imageUrl = block.image, let url = URL(string: imageUrl) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { Color.gray.opacity(0.2) }
                .frame(height: 120).clipped()
            }

            VStack(alignment: .leading, spacing: 4) {
                if let badge = block.badge {
                    Text(badge)
                        .font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(config.primaryColor)
                        .foregroundColor(config.primaryColor.contrastingTextColor)
                        .cornerRadius(4)
                }
                Text(block.title).font(.subheadline).fontWeight(.semibold)
                if let sub = block.subtitle { Text(sub).font(.caption).foregroundColor(.secondary) }

                if let meta = block.metadata, !meta.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(meta, id: \.label) { pair in
                            Text("\(pair.label): \(pair.value)").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }

                if let actions = block.actions, !actions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(actions, id: \.label) { action in
                            BlockActionButton(action: action, config: config, onAction: onAction)
                        }
                    }.padding(.top, 4)
                }
            }.padding(10)
        }
        .background(PlatformColors.systemGray6)
        .cornerRadius(10)
    }
}

// MARK: - Card List

struct CardListBlockView: View {
    let block: CardListBlock
    let config: ChatWidgetConfig
    var onAction: ((BlockAction) -> Void)?

    var body: some View {
        let isHorizontal = block.layout == "horizontal"
        if isHorizontal {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(block.items, id: \.title) { item in
                        CardBlockView(block: item, config: config, onAction: onAction)
                            .frame(width: 220)
                    }
                }
            }
        } else {
            VStack(spacing: 8) {
                ForEach(block.items, id: \.title) { item in
                    CardBlockView(block: item, config: config, onAction: onAction)
                }
            }
        }
    }
}

// MARK: - Action Button

struct BlockActionButton: View {
    let action: BlockAction
    let config: ChatWidgetConfig
    var onAction: ((BlockAction) -> Void)?
    private var isPrimary: Bool { action.style != "secondary" }

    var body: some View {
        if action.type == "link", let urlStr = action.url, let url = URL(string: urlStr) {
            Link(destination: url) { label }
        } else {
            Button { onAction?(action) } label: { label }
        }
    }

    private var label: some View {
        Text(action.label)
            .font(.caption).fontWeight(.medium)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(isPrimary ? config.primaryColor : PlatformColors.systemGray6)
            .foregroundColor(isPrimary ? config.primaryColor.contrastingTextColor : .primary)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isPrimary ? Color.clear : Color.secondary.opacity(0.3), lineWidth: 1)
            )
    }
}

// MARK: - Action Buttons Group

struct ActionButtonsBlockView: View {
    let block: ActionButtonsBlock
    var onAction: ((BlockAction) -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(block.buttons, id: \.label) { action in
                BlockActionButton(action: action, config: ChatWidgetConfig(), onAction: onAction)
            }
        }
    }
}

// MARK: - Callout

struct CalloutBlockView: View {
    let block: CalloutBlock
    private var style: String { block.style ?? "info" }

    private var backgroundColor: Color {
        switch style {
        case "success": return Color.green.opacity(0.12)
        case "warning": return Color.orange.opacity(0.12)
        default: return Color.blue.opacity(0.12)
        }
    }

    private var icon: String {
        switch style {
        case "success": return "checkmark.circle.fill"
        case "warning": return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundColor(iconColor).font(.body)
            VStack(alignment: .leading, spacing: 2) {
                if let title = block.title { Text(title).font(.subheadline).fontWeight(.semibold) }
                Text(block.body).font(.caption)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .cornerRadius(8)
    }

    private var iconColor: Color {
        switch style {
        case "success": return .green
        case "warning": return .orange
        default: return .blue
        }
    }
}

// MARK: - Image

struct ImageBlockView: View {
    let block: ImageBlock

    var body: some View {
        VStack(spacing: 4) {
            if let url = URL(string: block.url) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: { Color.gray.opacity(0.2).frame(height: 100) }
                .cornerRadius(8)
            }
            if let caption = block.caption {
                Text(caption).font(.caption2).foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Table

struct TableBlockView: View {
    let block: TableBlock

    var body: some View {
        VStack(spacing: 0) {
            if let headers = block.headers {
                HStack(spacing: 0) {
                    ForEach(headers, id: \.self) { h in
                        Text(h).font(.caption).fontWeight(.semibold)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                }
                .background(PlatformColors.systemGray6)
            }
            ForEach(block.rows ?? [], id: \.description) { row in
                HStack(spacing: 0) {
                    ForEach(row, id: \.self) { cell in
                        Text(cell).font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                }
                Divider()
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
        .cornerRadius(6)
    }
}

// MARK: - Code

struct CodeBlockView: View {
    let block: CodeBlock
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let filename = block.filename {
                Text(filename).font(.caption2).foregroundColor(.gray)
                    .padding(.horizontal, 10).padding(.top, 6)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.code).font(.system(.caption, design: .monospaced))
                    .foregroundColor(Color(white: 0.88))
                    .padding(10)
            }
        }
        .background(Color(red: 0.12, green: 0.12, blue: 0.18))
        .cornerRadius(8)
        .overlay(alignment: .topTrailing) {
            if block.copyable != false {
                Button {
                    #if os(iOS)
                    UIPasteboard.general.string = block.code
                    #else
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(block.code, forType: .string)
                    #endif
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2).foregroundColor(.gray)
                        .padding(6)
                }
            }
        }
    }
}

// MARK: - File

struct FileBlockView: View {
    let block: FileBlock

    var body: some View {
        if let url = URL(string: block.url) {
            Link(destination: url) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill").foregroundColor(.blue)
                    VStack(alignment: .leading) {
                        Text(block.filename).font(.caption).fontWeight(.medium)
                        if let size = block.size {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "arrow.down.circle").foregroundColor(.blue)
                }
                .padding(10)
                .background(PlatformColors.systemGray6)
                .cornerRadius(8)
            }
        }
    }
}

// MARK: - Collapsible

struct CollapsibleBlockView: View {
    let block: CollapsibleBlock
    @State private var isOpen: Bool

    init(block: CollapsibleBlock) {
        self.block = block
        _isOpen = State(initialValue: block.defaultOpen ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation { isOpen.toggle() } } label: {
                HStack {
                    Text(block.title).font(.subheadline).fontWeight(.medium)
                    Spacer()
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(10)
                .background(PlatformColors.systemGray6)
            }
            .buttonStyle(.plain)

            if isOpen {
                Text(block.body).font(.caption).padding(10)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
        .cornerRadius(8)
    }
}

// MARK: - Status

struct StatusBlockView: View {
    let block: StatusBlock
    private var state: String { block.state ?? "info" }

    private var icon: String {
        switch state {
        case "loading": return "clock.fill"
        case "success": return "checkmark.circle.fill"
        case "error": return "xmark.circle.fill"
        case "warning": return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }

    private var iconColor: Color {
        switch state {
        case "loading": return .orange
        case "success": return .green
        case "error": return .red
        case "warning": return .orange
        default: return .blue
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundColor(iconColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(block.title).font(.subheadline).fontWeight(.semibold)
                if let body = block.body { Text(body).font(.caption) }
                if let progress = block.progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.2)).frame(height: 4)
                            RoundedRectangle(cornerRadius: 2).fill(iconColor)
                                .frame(width: geo.size.width * progress, height: 4)
                        }
                    }.frame(height: 4)
                }
            }
        }
        .padding(10)
        .background(PlatformColors.systemGray6)
        .cornerRadius(8)
    }
}

// MARK: - Location

struct LocationBlockView: View {
    let block: LocationBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "mappin.circle.fill").foregroundColor(.red)
                Text(block.label).font(.subheadline).fontWeight(.medium)
            }
            Text("(\(String(format: "%.4f", block.latitude)), \(String(format: "%.4f", block.longitude)))")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(10)
        .background(PlatformColors.systemGray6)
        .cornerRadius(8)
    }
}


