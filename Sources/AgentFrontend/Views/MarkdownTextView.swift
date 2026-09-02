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
    case table(headers: [String], rows: [[String]]) // GitHub-style pipe table
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

            // Pipe table — must come before the thematic-break check: the
            // separator row ("|---|---|") is nothing but dashes and pipes,
            // and a table body row of dashes would otherwise read as a rule.
            if isTableStart(lines, at: i) {
                let headers = tableCells(lines[i])
                i += 2 // header + separator
                var rows: [[String]] = []
                while i < lines.count, isTableRow(lines[i]) {
                    // Pad/trim to the header count so a sloppy row can't
                    // shear the whole grid.
                    var cells = tableCells(lines[i])
                    if cells.count < headers.count {
                        cells += Array(repeating: "", count: headers.count - cells.count)
                    }
                    rows.append(Array(cells.prefix(headers.count)))
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
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
                   bulletItemText(l) != nil || numberedItem(l) != nil || isBlank(l) ||
                   isTableStart(lines, at: i) {
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

    // MARK: Tables

    /// A table starts at a pipe row whose NEXT line is a separator row
    /// (`| --- | :--: |`). Both are required — a lone pipe line is prose
    /// ("either | or"), and during streaming the header arrives a tick
    /// before the separator, so the header renders as a paragraph for a
    /// moment and upgrades to a table once the separator lands.
    private static func isTableStart(_ lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count,
              isTableRow(lines[index]),
              isTableSeparator(lines[index + 1]) else { return false }
        return true
    }

    private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("|") && !trimmed.isEmpty && !trimmed.hasPrefix("```")
    }

    /// Separator cells are runs of dashes with optional alignment colons.
    /// One dash is accepted (the spec wants three; models don't always
    /// oblige), but every cell must match or the line is just prose.
    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let core = cell.hasPrefix(":") ? String(cell.dropFirst()) : cell
            let body = core.hasSuffix(":") ? String(core.dropLast()) : core
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }

    /// Split a pipe row into trimmed cells, dropping the empties produced
    /// by leading/trailing pipes ("| a | b |" -> ["a", "b"]).
    private static func tableCells(_ line: String) -> [String] {
        var cells = line.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
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
/// - Pipe tables (| a | b |) — header + striped rows, horizontal scroll
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
            ForEach(Array(renderableBlocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    /// Parsed blocks minus the ones that draw nothing.
    ///
    /// Thematic breaks are dropped here rather than in the parser — the
    /// parser's block vocabulary is the tested contract and stays intact;
    /// this is purely a rendering decision.
    ///
    /// They used to render as one blank line, which is fine for the
    /// occasional stray rule but not for what the agent actually emits: a
    /// `---` between *every sentence*. At that density each break costs a
    /// blank line plus a block gap either side — roughly triple the
    /// intended paragraph spacing — and the reply reads as a poem. Dropping
    /// the block entirely (rather than rendering an `EmptyView`, which
    /// would still take a `VStack` slot and its spacing) leaves the
    /// neighbouring paragraphs exactly one `blockSpacing` apart, which is
    /// what a paragraph break was always meant to look like.
    private var renderableBlocks: [MarkdownBlock] {
        MarkdownRenderCache.blocks(id: cacheKey ?? content, content: content)
            .filter { $0 != .thematicBreak }
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inlineMarkdownText(text)
                .textSelection(.enabled)

        case .thematicBreak:
            // Unreachable — `renderableBlocks` filters these out before
            // they reach here; the case remains only to keep the switch
            // exhaustive. A rule is never drawn: in a conversational
            // transcript a hairline reads as UI chrome.
            EmptyView()

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

        // Wide tables scroll horizontally like code blocks rather than
        // squeezing: JSP replies cite rate tables with 5+ columns, and
        // compressing those into a phone width makes every cell a one-
        // word-per-line ribbon. Each cell wraps against a bounded width,
        // which keeps the layout out of the lazy list's height
        // negotiation (see inlineMarkdownText — no fixedSize, ever).
        case .table(let headers, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .topLeading,
                     horizontalSpacing: 0,
                     verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(headers.enumerated()), id: \.offset) { _, cell in
                            tableCellText(cell, isHeader: true)
                        }
                    }
                    .background(PlatformColors.systemGray6)
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                tableCellText(cell, isHeader: false)
                            }
                        }
                        .background(rowIndex.isMultiple(of: 2)
                            ? Color.clear
                            : PlatformColors.systemGray6.opacity(0.5))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(PlatformColors.systemGray6, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// One table cell. Caps cell width so a prose-length cell wraps at a
    /// readable measure instead of stretching the whole grid off-screen.
    ///
    /// The `fixedSize(horizontal: false, vertical: true)` here is the fix
    /// for cells ellipsising at one line: the Grid row proposes a single
    /// line of height and the Text truncates rather than grow. Yes, the
    /// big warning in `inlineMarkdownText` says never to use fixedSize —
    /// that hang is a negotiation between message-body Text and the (once
    /// lazy) message list. This subtree is a `Grid` inside its own
    /// horizontal `ScrollView`: the width cap right above gives the Text
    /// a definite measure to wrap against, and no lazy container takes
    /// part in the height negotiation, so the ideal-height request
    /// resolves in one pass.
    @ViewBuilder
    private func tableCellText(_ text: String, isHeader: Bool) -> some View {
        Group {
            if let attributed = MarkdownRenderCache.attributed(for: text) {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        .font(.system(.callout, design: fontDesign).weight(isHeader ? .semibold : .regular))
        .foregroundColor(foregroundColor)
        .tint(linkColor)
        .textSelection(.enabled)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 280, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: .infinity, alignment: .topLeading)
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
