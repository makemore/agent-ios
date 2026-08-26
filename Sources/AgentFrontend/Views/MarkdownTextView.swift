import SwiftUI
import AgentClient

/// Block-level markdown structure, split out from the view so the parsing
/// rules can be unit-tested without rendering.
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case codeBlock(code: String, language: String?)
    case heading(text: String, level: Int)          // level 1-3
    case bulletList([String])
    case numberedList(items: [String], start: Int)  // start = first item's number
    case thematicBreak                              // ---, ***, ___
}

/// Block-level parser for assistant message bodies.
///
/// Inline formatting (bold, italic, code, links) is left to
/// `AttributedString(markdown:)` at render time; this only splits the text
/// into blocks.
/// Memoises markdown work across renders.
///
/// `MarkdownTextView.body` runs on every SwiftUI render, and during a
/// streamed reply the typewriter drain timer mutates `messages` at ~33 Hz.
/// Without caching, every tick re-parses the block structure *and* rebuilds
/// an `AttributedString` per paragraph for every visible message — enough
/// to block the main thread for over a second on a long conversation.
///
/// Keyed by the source string, so a message that hasn't changed costs a
/// dictionary lookup. The streaming message's text does change each tick
/// and still re-parses; everything above it in the scrollback does not,
/// which is where the win is.
///
/// Body runs on the main actor, so a plain dictionary needs no locking.
@MainActor
enum MarkdownRenderCache {
    /// Bounded so a long session can't grow these without limit. On
    /// overflow we drop everything rather than track recency — cheap, and
    /// the next few renders simply repopulate what's on screen.
    private static let capacity = 256

    /// Block cache keyed by *message identity*, not by content.
    ///
    /// Keying by content looks natural but behaves badly while streaming:
    /// the growing message yields a fresh key ~33 times a second, so the
    /// cache fills in seconds and the overflow flush evicts every stable
    /// message along with it. One entry per message, overwritten as its
    /// text grows, keeps the entry count equal to the conversation length
    /// and leaves finished messages permanently warm.
    private static var blockCache: [String: (content: String, blocks: [MarkdownBlock])] = [:]
    private static var inlineCache: [String: AttributedString] = [:]

    static func blocks(id: String, content: String) -> [MarkdownBlock] {
        if let hit = blockCache[id], hit.content == content { return hit.blocks }
        let parsed = HangDiagnostics.measure("markdown parse (\(content.count) chars)") {
            MarkdownBlockParser.parse(content)
        }
        if blockCache.count >= capacity { blockCache.removeAll(keepingCapacity: true) }
        blockCache[id] = (content, parsed)
        return parsed
    }

    /// `nil` when the text isn't valid inline markdown — callers fall back
    /// to plain `Text`. The failure is cached too, via the sentinel below,
    /// so unparseable content doesn't retry 33 times a second.
    static func attributed(for text: String) -> AttributedString? {
        if let hit = inlineCache[text] {
            return hit == Self.failureSentinel ? nil : hit
        }
        let parsed = HangDiagnostics.measure("AttributedString build (\(text.count) chars)") {
            try? AttributedString(
                markdown: text,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        }
        if inlineCache.count >= capacity { inlineCache.removeAll(keepingCapacity: true) }
        inlineCache[text] = parsed ?? Self.failureSentinel
        return parsed
    }

    /// Distinguishes "parsed to empty" from "failed to parse" in the cache.
    private static let failureSentinel = AttributedString("\u{0}__markdown_parse_failed__")
}

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

            // Thematic break (---) — before the bullet check so "- - -"
            // style rules can't be mistaken for a list item.
            if isThematicBreak(line) {
                blocks.append(.thematicBreak)
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
                if l.hasPrefix("```") || heading(l) != nil || isThematicBreak(l) ||
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

    /// Three or more of the same marker (-, *, _) alone on a line, with
    /// optional spaces between them ("---", "***", "- - -"). Rendered as a
    /// blank line — the agent shouldn't emit these, but when one slips
    /// through it must not appear as literal dashes.
    private static func isThematicBreak(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " && $0 != "\t" }
        guard marks.count >= 3, let first = marks.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return marks.allSatisfy { $0 == first }
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
/// - Thematic breaks (---) — rendered as a blank line
/// - Line breaks / paragraphs
///
/// Uses SwiftUI's built-in `AttributedString(markdown:)` for inline formatting
/// and `MarkdownBlockParser` for code blocks, lists, and headers.
struct MarkdownTextView: View {
    let content: String
    let foregroundColor: Color
    var linkColor: Color = Color(hex: "#4a6b8e")
    /// Stable identity for the block cache — the owning message's id.
    /// Falls back to the content itself so preview/harness call sites that
    /// don't have an id still behave correctly, just without the
    /// streaming-friendly reuse.
    var cacheKey: String? = nil
    /// Base text style. Headings step up from it, so the whole reply
    /// scales together when the host raises this.
    var textStyle: Font.TextStyle = .body
    /// Typeface family for the whole reply. `.serif` is the editorial
    /// voice; `.default` keeps the system sans. Code blocks stay
    /// monospaced regardless — a serif code block is unreadable.
    var fontDesign: Font.Design = .default
    /// Extra leading between wrapped lines.
    var lineSpacing: CGFloat = 0
    /// Vertical gap between blocks.
    var blockSpacing: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: blockSpacing) {
            ForEach(Array(MarkdownRenderCache.blocks(id: cacheKey ?? content, content: content).enumerated()), id: \.offset) { _, block in
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

        case .thematicBreak:
            // Rendered as one blank line rather than a drawn rule — in a
            // conversational bubble a hairline reads as UI chrome. Using a
            // space glyph (not a fixed frame) keeps the gap proportional
            // when the host raises `textStyle`.
            Text(verbatim: " ")
                .font(bodyFont)
                .lineSpacing(lineSpacing)

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
                // A heading belongs to what follows it, so it wants more
                // air above than the uniform block gap gives. Half a gap
                // again reads as a section break rather than as one more
                // paragraph that happens to be bold.
                .padding(.top, blockSpacing / 2)

        // Lists render as ONE Text: items joined with newlines, markers
        // as literal text. Wrapped lines return to the margin instead of
        // hanging under the item text — a real cost, paid on purpose.
        //
        // HISTORY, now with two data points, because the row-per-item
        // shape (marker column + text column, the one with hanging
        // indents) has been tried and reverted TWICE:
        //
        //   1. 2026-07, against the lazy message list: long items
        //      tail-ellipsised while sibling paragraphs wrapped fine.
        //      Diagnosed as the lazy stack's height proposal being split
        //      across the nested row containers.
        //   2. 2026-08-20, against the rewritten PLAIN-VStack list, on
        //      the theory that the lazy stack was the cause and its
        //      removal made rows safe. Same symptom on device: first
        //      bullet ellipsised at one line, its sibling wrapped — so
        //      the lazy stack was NOT the whole cause, and the real
        //      constraint is still undiagnosed.
        //
        // Do not attempt the row shape a third time without a live
        // repro in hand: RM debug builds auto-install a fixture
        // conversation (ChatDebugSeeder) whose "list-item truncation"
        // case has bullets long enough to wrap 2-3 lines, and every one
        // of them must render unelided before and after. And do NOT reach for `fixedSize`
        // if anything here looks short — see `inlineMarkdownText`; it
        // hangs the layout.
        case .bulletList(let items):
            inlineMarkdownText(items.map { "•  \($0)" }
                .joined(separator: "\n"))
                .textSelection(.enabled)

        case .numberedList(let items, let start):
            inlineMarkdownText(items.enumerated()
                .map { "\($0.offset + start). \($0.element)" }
                .joined(separator: "\n"))
                .textSelection(.enabled)
        }
    }

    /// The body face, shared by prose and list markers.
    private var bodyFont: Font { .system(textStyle, design: fontDesign) }

    /// Render inline markdown (bold, italic, code, links) using AttributedString
    ///
    /// Wrapping fix: without intervention a long run of text here clips
    /// to one line and ellipsises instead of growing. The original
    /// diagnosis blamed the then-lazy message list's height proposal;
    /// the list is a plain `VStack` now and the constraint evidently
    /// survives (see the list HISTORY above), so treat the width pin
    /// below as load-bearing regardless of what the container is.
    ///
    /// Deliberately `.frame(maxWidth:)`, NOT `fixedSize(horizontal:false,
    /// vertical:true)`. The fixedSize form (the original July fix, written
    /// against the pre-rewrite list) makes every Text negotiate its
    /// intrinsic height with the rewritten list's `LazyVStack`, and that
    /// negotiation never converges — the main thread spins inside
    /// `LazyVStackLayout` / `AGGraphGetValue` indefinitely (2-minute hangs
    /// captured in the debugger, no app code on the stack). Pinning the
    /// width instead gives the Text a definite proposal to wrap against
    /// and stays out of the lazy layout's size negotiation entirely.
    ///
    /// Re-tested 2026-08-04: fixedSize applied *after* an inner
    /// `.frame(maxWidth: .infinity)` hangs identically during a streamed
    /// reply (sampled: main thread 100% in
    /// `LazySubviewPlacements.placeSubviews` → `LazyStack.place`). A
    /// definite width does not rescue the height negotiation, so do not
    /// reintroduce fixedSize here in any form. List-item truncation is
    /// instead solved structurally by the joined-Text list shape above.
    @ViewBuilder
    private func inlineMarkdownText(_ text: String) -> some View {
        if let attributed = MarkdownRenderCache.attributed(for: text) {
            Text(attributed)
                .font(bodyFont)
                .lineSpacing(lineSpacing)
                .foregroundColor(foregroundColor)
                .tint(linkColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Fallback to plain text if markdown parsing fails
            Text(text)
                .font(bodyFont)
                .lineSpacing(lineSpacing)
                .foregroundColor(foregroundColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Text styles in ascending size order. `Font.TextStyle` is
    /// `CaseIterable` but its case order is not documented as size
    /// order, so headings step through this instead.
    private static let sizeOrder: [Font.TextStyle] = [
        .caption2, .caption, .footnote, .subheadline,
        .callout, .body, .title3, .title2, .title, .largeTitle
    ]

    /// Headings are sized *relative to the body*, so raising
    /// `textStyle` lifts the whole reply and keeps the hierarchy
    /// intact. h3 sits at body size and earns its rank from weight
    /// alone, matching the previous `.headline`.
    private func headingFont(_ level: Int) -> Font {
        let steps: Int
        switch level {
        case 1: steps = 2
        case 2: steps = 1
        default: steps = 0
        }
        let base = Self.sizeOrder.firstIndex(of: textStyle)
            ?? Self.sizeOrder.firstIndex(of: .body)!
        let style = Self.sizeOrder[min(base + steps, Self.sizeOrder.count - 1)]
        return .system(style, design: fontDesign)
    }
}
