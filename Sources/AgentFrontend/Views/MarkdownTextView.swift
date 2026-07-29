import SwiftUI
import AgentClient

/// Block-level markdown structure, split out from the view so the parsing
/// rules can be unit-tested without rendering (same shape as `ScrollDecision`).
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case codeBlock(code: String, language: String?)
    case heading(text: String, level: Int)          // level 1-3
    case bulletList([String])
    case numberedList(items: [String], start: Int)  // start = first item's number
}

/// Block-level parser for assistant message bodies.
///
/// Inline formatting (bold, italic, code, links) is left to
/// `AttributedString(markdown:)` at render time; this only splits the text
/// into blocks.
enum MarkdownBlockParser {

    static func parse(_ content: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
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
                blocks.append(.codeBlock(code: codeLines.joined(separator: "\n"),
                                         language: lang.isEmpty ? nil : lang))
                continue
            }

            // Heading
            if let heading = heading(line) {
                blocks.append(heading)
                i += 1
                continue
            }

            // Bullet list
            if bulletItemText(line) != nil {
                var items: [String] = []
                while i < lines.count {
                    if let text = bulletItemText(lines[i]) {
                        items.append(text)
                        i += 1
                        continue
                    }
                    if let next = continuationIndex(from: i, in: lines, isItem: { bulletItemText($0) != nil }) {
                        i = next
                        continue
                    }
                    break
                }
                blocks.append(.bulletList(items))
                continue
            }

            // Numbered list
            if let first = numberedItem(line) {
                var items: [String] = []
                while i < lines.count {
                    if let item = numberedItem(lines[i]) {
                        items.append(item.text)
                        i += 1
                        continue
                    }
                    if let next = continuationIndex(from: i, in: lines, isItem: { numberedItem($0) != nil }) {
                        i = next
                        continue
                    }
                    break
                }
                blocks.append(.numberedList(items: items, start: first.number))
                continue
            }

            // Blank line — skip
            if isBlank(line) {
                i += 1
                continue
            }

            // Paragraph — collect consecutive non-special lines
            var paraLines: [String] = []
            while i < lines.count {
                let l = lines[i]
                if l.hasPrefix("```") || heading(l) != nil ||
                   bulletItemText(l) != nil || numberedItem(l) != nil || isBlank(l) {
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

    // MARK: - Line classification

    /// Index of the next item in the current list, skipping blank lines.
    ///
    /// A blank line between items makes a *loose* list, not two lists — the
    /// agent emits these constantly, and treating each item as its own list
    /// restarted the numbering at 1 for every entry.
    private static func continuationIndex(from index: Int,
                                          in lines: [String],
                                          isItem: (String) -> Bool) -> Int? {
        guard isBlank(lines[index]) else { return nil }
        var j = index
        while j < lines.count, isBlank(lines[j]) { j += 1 }
        guard j < lines.count, isItem(lines[j]) else { return nil }
        return j
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("### ") { return .heading(text: String(trimmed.dropFirst(4)), level: 3) }
        if trimmed.hasPrefix("## ") { return .heading(text: String(trimmed.dropFirst(3)), level: 2) }
        if trimmed.hasPrefix("# ") { return .heading(text: String(trimmed.dropFirst(2)), level: 1) }
        return nil
    }

    private static func bulletItemText(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") { return String(trimmed.dropFirst(2)) }
        if trimmed.hasPrefix("* ") { return String(trimmed.dropFirst(2)) }
        return nil
    }

    /// Splits "2. Grounding" into its number and text.
    ///
    /// The dot must be followed by whitespace or end the line, so decimals
    /// ("3.5 seconds in") stay prose rather than opening a list.
    private static func numberedItem(_ line: String) -> (number: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let dotIdx = trimmed.firstIndex(of: ".") else { return nil }
        let digits = trimmed[trimmed.startIndex..<dotIdx]
        guard !digits.isEmpty, digits.count <= 9,
              digits.allSatisfy(\.isNumber),
              let number = Int(digits) else { return nil }
        let rest = trimmed[trimmed.index(after: dotIdx)...]
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return (number, rest.trimmingCharacters(in: .whitespaces))
    }
}

/// Lightweight markdown renderer for assistant message bubbles.
///
/// Supports:
/// - **Bold** and *italic*
/// - `inline code`
/// - Fenced code blocks (``` ... ```)
/// - Bullet lists (- item) and numbered lists (1. item), including loose
///   lists with blank lines between items
/// - Headers (# h1, ## h2, ### h3)
/// - [Links](url) — tappable, open in Safari
/// - Line breaks / paragraphs
///
/// Uses SwiftUI's built-in `AttributedString(markdown:)` for inline formatting
/// and `MarkdownBlockParser` for code blocks, lists, and headers.
struct MarkdownTextView: View {
    let content: String
    let foregroundColor: Color
    var linkColor: Color = Color(hex: "#4a6b8e")

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlockParser.parse(content).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
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

        case .numberedList(let items, let start):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(start + idx).")
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
