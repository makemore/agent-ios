// Chunking ported from hexgrad/kokoro (https://github.com/hexgrad/kokoro,
// kokoro/pipeline.py at dfb907a02bba8152ca444717ca5d78747ccb4bec), Copyright
// hexgrad, Apache-2.0, via our reference tools/kokoro-assets/kokoro_ref/kokoro.py.

import Foundation

/// One piece of phonemes to synthesise in one model run.
struct KokoroChunk: Equatable {
    let text: String
    let phonemes: String
}

/// Chunking of resolved tokens: a port of `chunk_tokens()` in
/// `kokoro_ref/kokoro.py` (hexgrad KPipeline.en_tokenize / waterfall_last),
/// plus the latency split recommended by the spec.
enum KokoroChunker {
    static let maxPhonemes = 510
    static let waterfall: [Set<String>] = [["!", ".", "?", "…"], [":", ";"], [",", "—"]]
    static let bumps: Set<String> = [")", "”"]

    static func tokensToPhonemes(_ tokens: ArraySlice<G2PToken>) -> String {
        var s = ""
        for t in tokens { s += (t.phonemes ?? "") + (t.whitespace.isEmpty ? "" : " ") }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func textOf(_ tokens: ArraySlice<G2PToken>) -> String {
        var s = ""
        for t in tokens { s += t.text + t.whitespace }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func waterfallLast(_ tokens: ArraySlice<G2PToken>, _ nextCount: Int) -> Int {
        let base = tokens.startIndex
        for w in waterfall {
            guard var z = tokens.lastIndex(where: { w.contains($0.phonemes ?? "") }) else { continue }
            z += 1
            if z < tokens.endIndex, bumps.contains(tokens[z].phonemes ?? "") { z += 1 }
            if nextCount - PyText.count(tokensToPhonemes(tokens[base..<z])) <= maxPhonemes {
                return z - base
            }
        }
        return tokens.count
    }

    /// Greedily fills chunks of up to 510 phonemes, cutting at the last
    /// sentence / clause / comma punctuation that fits. Golden-tested.
    static func chunk(_ tokens: [G2PToken]) -> [KokoroChunk] {
        chunkSlices(tokens)
            .map { KokoroChunk(text: textOf($0), phonemes: tokensToPhonemes($0)) }
            .filter { !$0.phonemes.isEmpty }
    }

    /// Splits each chunk further for streaming (not part of the golden
    /// contract; spec, "Chunking" recommendations). Synthesis runs at a
    /// small multiple of real time, so the first audio waits for the whole
    /// first piece, and each later piece must be ready before the audio
    /// queued ahead of it runs out. So pieces only end at punctuation and:
    /// - the first piece ends at the first sentence or clause mark
    ///   (`. ! ? …` / `, ; : —`) once it has `minFirst` phonemes;
    /// - later pieces end at a sentence mark once they have `minSentence`
    ///   phonemes, or at a clause mark once they are 1.5 times as long as
    ///   the piece before (and at least `minClause`), so lengths ramp up and
    ///   each piece is ready before the audio ahead of it has played.
    /// A cut never leaves a tail shorter than `minTail` phonemes: voices are
    /// weak below 10–20 tokens.
    static func streamingPieces(_ tokens: [G2PToken], minFirst: Int = 12, minSentence: Int = 20,
                                minClause: Int = 30, minTail: Int = 10) -> [KokoroChunk] {
        var pieces: [KokoroChunk] = []
        var previousLength = 0
        for chunk in chunkSlices(tokens) {
            var start = chunk.startIndex
            var i = chunk.startIndex
            while i < chunk.endIndex {
                let p = chunk[i].phonemes ?? ""
                var end = i + 1
                let sentenceEnd = waterfall[0].contains(p)
                let clause = waterfall[1].contains(p) || waterfall[2].contains(p)
                if sentenceEnd || clause {
                    if end < chunk.endIndex, bumps.contains(chunk[end].phonemes ?? "") { end += 1 }
                    let length = PyText.count(tokensToPhonemes(chunk[start..<end]))
                    let tail = PyText.count(tokensToPhonemes(chunk[end..<chunk.endIndex]))
                    let cut: Bool
                    if pieces.isEmpty {
                        cut = length >= minFirst
                    } else if sentenceEnd {
                        cut = length >= minSentence
                    } else {
                        cut = length >= max(minClause, previousLength * 3 / 2)
                    }
                    if cut && tail >= minTail {
                        let slice = chunk[start..<end]
                        pieces.append(KokoroChunk(text: textOf(slice), phonemes: tokensToPhonemes(slice)))
                        previousLength = length
                        start = end
                    }
                }
                i = end
            }
            if start < chunk.endIndex {
                let slice = chunk[start..<chunk.endIndex]
                let piece = KokoroChunk(text: textOf(slice), phonemes: tokensToPhonemes(slice))
                previousLength = PyText.count(piece.phonemes)
                pieces.append(piece)
            }
        }
        return pieces.filter { !$0.phonemes.isEmpty }
    }

    /// The token ranges of ``chunk(_:)``.
    private static func chunkSlices(_ tokens: [G2PToken]) -> [ArraySlice<G2PToken>] {
        var out: [ArraySlice<G2PToken>] = []
        var tks: ArraySlice<G2PToken> = []
        var pcount = 0
        for t in tokens {
            var nextPs = (t.phonemes ?? "") + (t.whitespace.isEmpty ? "" : " ")
            let trimmed = nextPs.unicodeScalars.reversed().drop(while: { PyText.isSpace($0) }).count
            if pcount + trimmed > maxPhonemes {
                let z = waterfallLast(tks, pcount + trimmed)
                out.append(tks.prefix(z))
                tks = tks.dropFirst(z)
                pcount = PyText.count(tokensToPhonemes(tks))
                if tks.isEmpty {
                    nextPs = PyText.string(nextPs.unicodeScalars.drop(while: { PyText.isSpace($0) }))
                }
            }
            tks.append(t)
            pcount += PyText.count(nextPs)
        }
        if !tks.isEmpty { out.append(tks) }
        return out.map { ArraySlice(Array($0)) }
    }
}
