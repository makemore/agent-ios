import Foundation

/// Buffers incremental text deltas and emits chunks suitable for low-latency
/// TTS playback. Port of the JS ``SentenceChunker`` so iOS, web, and Android
/// behave identically.
///
/// Default behaviour fires after each sentence terminator (``.``, ``!``,
/// ``?``) once the buffer holds at least ``minChars`` characters, so very
/// short fragments don't trigger their own audio request. Tune ``minChars``
/// and ``maxChars`` to trade latency against the number of synth calls.
public final class SentenceChunker {
    private let minChars: Int
    private let maxChars: Int
    private let onChunk: (String) -> Void
    private var buffer: String = ""

    public init(minChars: Int = 40, maxChars: Int = 240, onChunk: @escaping (String) -> Void) {
        self.minChars = minChars
        self.maxChars = maxChars
        self.onChunk = onChunk
    }

    /// Append a delta to the buffer and emit any complete sentences.
    public func push(_ delta: String) {
        guard !delta.isEmpty else { return }
        buffer.append(delta)
        drain()
    }

    /// Force-emit whatever is left (e.g. on ``assistant.message``).
    public func flush() {
        let remaining = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer.removeAll(keepingCapacity: false)
        if !remaining.isEmpty { emit(remaining) }
    }

    /// Discard buffered text without emitting (e.g. on user interrupt).
    public func reset() {
        buffer.removeAll(keepingCapacity: false)
    }

    private func drain() {
        // Hard cap: emit even mid-sentence if the buffer is uncomfortably
        // long so the user hears something while a long monologue continues.
        while buffer.count >= maxChars {
            let cut = findSafeCut(buffer, max: maxChars)
            let head = String(buffer.prefix(cut)).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeFirst(cut)
            if !head.isEmpty { emit(head) }
        }

        // Soft sentence boundary: only flush once we have enough characters
        // to make a worthwhile TTS request.
        while buffer.count >= minChars {
            guard let endIndex = sentenceEnd(in: buffer) else { break }
            let count = buffer.distance(from: buffer.startIndex, to: endIndex)
            let head = String(buffer.prefix(count)).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeFirst(count)
            if !head.isEmpty { emit(head) }
        }
    }

    /// Locate the index *after* the first sentence-terminator that is
    /// followed by whitespace or end-of-buffer. Returns ``nil`` when the
    /// buffer doesn't yet contain a safe break.
    private func sentenceEnd(in text: String) -> String.Index? {
        let terminators: Set<Character> = [".", "!", "?"]
        var i = text.startIndex
        while i < text.endIndex {
            if terminators.contains(text[i]) {
                let next = text.index(after: i)
                if next == text.endIndex || text[next].isWhitespace {
                    return next
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    private func findSafeCut(_ text: String, max: Int) -> Int {
        // Prefer breaking at the last whitespace before ``max`` so we don't
        // chop a word mid-syllable.
        let head = text.prefix(max)
        if let lastSpace = head.lastIndex(where: { $0.isWhitespace }) {
            let pos = head.distance(from: head.startIndex, to: lastSpace)
            if Double(pos) > Double(max) * 0.6 { return pos }
        }
        return max
    }

    private func emit(_ text: String) {
        let cleaned = SentenceChunker.sanitizeForSpeech(text)
        if !cleaned.isEmpty { onChunk(cleaned) }
    }

    /// Strip markdown noise that TTS reads literally and reads poorly.
    /// Conservative — leaves punctuation alone so prosody works.
    public static func sanitizeForSpeech(_ text: String) -> String {
        if text.isEmpty { return "" }
        var s = text
        // Fenced code blocks
        s = s.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        // Inline code
        s = s.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        // Bold (**x** / __x__)
        s = s.replacingOccurrences(of: #"(\*\*|__)(.*?)\1"#, with: "$2", options: .regularExpression)
        // Italic (*x* / _x_)
        s = s.replacingOccurrences(of: #"(\*|_)(.*?)\1"#, with: "$2", options: .regularExpression)
        // Markdown links: [label](url) -> label
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        // Bare URLs
        s = s.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        // Headings (# ... at line start)
        s = s.replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
        // Collapse whitespace
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
