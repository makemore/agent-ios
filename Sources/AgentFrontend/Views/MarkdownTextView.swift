import SwiftUI
import AgentClient

/// Lightweight markdown renderer for assistant message bubbles.
///
/// Supports:
/// - **Bold** and *italic*
/// - `inline code`
/// - Fenced code blocks (``` ... ```)
/// - Bullet lists (- item) and numbered lists (1. item)
/// - Headers (# h1, ## h2, ### h3)
/// - [Links](url) — tappable, open in Safari
/// - Line breaks / paragraphs
///
/// Uses SwiftUI's built-in `AttributedString(markdown:)` for inline formatting
/// and a block-level parser for code blocks, lists, and headers.
struct MarkdownTextView: View {
    let content: String
    let foregroundColor: Color
    var linkColor: Color = Color(hex: "#4a6b8e")

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // MARK: - Block types

    private enum Block {
        case paragraph(String)
        case codeBlock(String, String?) // code, language
        case heading(String, Int)       // text, level 1-3
        case bulletList([String])
        case numberedList([String])
    }

    // MARK: - Block parser

    private func parseBlocks() -> [Block] {
        var blocks: [Block] = []
        let lines = content.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Fenced code block
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                i += 1 // skip closing ```
                blocks.append(.codeBlock(codeLines.joined(separator: "\n"), lang.isEmpty ? nil : lang))
                continue
            }

            // Heading
            if let heading = parseHeading(line) {
                blocks.append(heading)
                i += 1
                continue
            }

            // Bullet list
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") ||
               line.trimmingCharacters(in: .whitespaces).hasPrefix("* ") {
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("- ") { items.append(String(l.dropFirst(2))) }
                    else if l.hasPrefix("* ") { items.append(String(l.dropFirst(2))) }
                    else { break }
                    i += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            // Numbered list
            if isNumberedListItem(line) {
                var items: [String] = []
                while i < lines.count && isNumberedListItem(lines[i]) {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if let dotIdx = l.firstIndex(of: ".") {
                        let afterDot = l[l.index(after: dotIdx)...]
                            .trimmingCharacters(in: .whitespaces)
                        items.append(afterDot)
                    }
                    i += 1
                }
                blocks.append(.numberedList(items))
                continue
            }

            // Blank line — skip
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }

            // Paragraph — collect consecutive non-special lines
            var paraLines: [String] = []
            while i < lines.count {
                let l = lines[i]
                if l.hasPrefix("```") || parseHeading(l) != nil ||
                   l.trimmingCharacters(in: .whitespaces).hasPrefix("- ") ||
                   l.trimmingCharacters(in: .whitespaces).hasPrefix("* ") ||
                   isNumberedListItem(l) ||
                   l.trimmingCharacters(in: .whitespaces).isEmpty {
                    break
                }
                paraLines.append(l)
                i += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(paraLines.joined(separator: "\n")))
            }
        }

        return blocks
    }

    private func parseHeading(_ line: String) -> Block? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("### ") { return .heading(String(trimmed.dropFirst(4)), 3) }
        if trimmed.hasPrefix("## ") { return .heading(String(trimmed.dropFirst(3)), 2) }
        if trimmed.hasPrefix("# ") { return .heading(String(trimmed.dropFirst(2)), 1) }
        return nil
    }

    private func isNumberedListItem(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let dotIdx = trimmed.firstIndex(of: ".") else { return false }
        let prefix = trimmed[trimmed.startIndex..<dotIdx]
        return !prefix.isEmpty && prefix.allSatisfy(\.isNumber)
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .paragraph(let text):
            inlineMarkdownText(text)
                .textSelection(.enabled)

        case .codeBlock(let code, let lang):
            VStack(alignment: .leading, spacing: 4) {
                if let lang = lang {
                    Text(lang)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PlatformColors.systemGray6)
            .cornerRadius(8)

        case .heading(let text, let level):
            inlineMarkdownText(text)
                .font(headingFont(level))
                .fontWeight(.bold)
                .textSelection(.enabled)

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .foregroundColor(foregroundColor)
                        inlineMarkdownText(item)
                            .textSelection(.enabled)
                    }
                }
            }

        case .numberedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(idx + 1).")
                            .foregroundColor(foregroundColor)
                            .monospacedDigit()
                        inlineMarkdownText(item)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    /// Render inline markdown (bold, italic, code, links) using AttributedString
    @ViewBuilder
    private func inlineMarkdownText(_ text: String) -> some View {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
                .font(.body)
                .foregroundColor(foregroundColor)
                .tint(linkColor)
        } else {
            // Fallback to plain text if markdown parsing fails
            Text(text)
                .font(.body)
                .foregroundColor(foregroundColor)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        default: return .headline
        }
    }
}

