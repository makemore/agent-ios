// Port of misaki's English lexicon (https://github.com/hexgrad/misaki,
// misaki/en.py at fba1236595f2d2bf21d414ba6e57d25256afada3), Copyright hexgrad,
// Apache-2.0, via our reference tools/kokoro-assets/kokoro_ref/g2p.py. Our
// changes are listed in that README ("Differences from misaki").

import Foundation

/// A word or punctuation item of a segment: misaki's `words` structure.
enum G2PItem {
    /// Punctuation, or a word made of one subtoken.
    case token(G2PToken)
    /// A word of several subtokens with no whitespace between them.
    case word([G2PToken])

    var tokens: [G2PToken] {
        switch self {
        case let .token(t): return [t]
        case let .word(ts): return ts
        }
    }

    /// `_is_word`: a list, or a token without phonemes yet.
    var isWord: Bool {
        switch self {
        case let .token(t): return t.phonemes == nil
        case .word: return true
        }
    }

    var text: String {
        switch self {
        case let .token(t): return t.text
        case let .word(ts): return ts.map(\.text).joined()
        }
    }
}

/// Unknown-word fallback (the BART G2P model).
protocol G2PFallback: AnyObject {
    func phonemes(for word: String) throws -> String
}

struct G2PResult {
    let phonemes: String
    let normalized: String
    /// Punctuation tokens and merged words, with their whitespace: the
    /// input to ``KokoroChunker``.
    let tokens: [G2PToken]
    let fallbackWords: [String]
}

/// English text -> Kokoro phonemes. A port of `G2P` in
/// `kokoro_ref/g2p.py` (spec: tools/kokoro-assets/README.md).
final class KokoroG2P {
    typealias C = G2PConstants

    let language: KokoroLanguage
    let lexicon: KokoroLexicon
    let fallback: G2PFallback

    init(language: KokoroLanguage, lexicon: KokoroLexicon, fallback: G2PFallback) {
        self.language = language
        self.lexicon = lexicon
        self.fallback = fallback
    }

    // MARK: - Stage 1

    /// NFKC (keeping U+2026), apostrophe-like characters to `'`, every
    /// whitespace run to one space, stripped.
    static func prepareText(_ text: String) -> String {
        let parts = text.components(separatedBy: "…").map(PyText.nfkc)
        var s = parts.joined(separator: "…")
        s = PyText.replace(s, "‘", with: "'")
        s = PyText.replace(s, "’", with: "'")
        s = PyText.replace(s, "ʼ", with: "'")
        var out = String.UnicodeScalarView()
        var inSpace = false
        for c in s.unicodeScalars {
            if PyText.isSpace(c) {
                if !inSpace { out.append(" ") }
                inSpace = true
            } else {
                out.append(c)
                inSpace = false
            }
        }
        var scalars = Array(out)
        while scalars.first == " " { scalars.removeFirst() }
        while scalars.last == " " { scalars.removeLast() }
        return PyText.string(scalars)
    }

    // MARK: - Tokenizer

    static let subtokenRegex = try! NSRegularExpression(pattern:
        "^['‘’]+|\\p{Lu}(?=\\p{Lu}\\p{Ll})|(?:^-)?(?:[0-9]?[,.]?[0-9])+|[-_]+|['‘’]{2,}"
        + "|\\p{L}*?(?:['‘’]\\p{L})*?\\p{Ll}(?=\\p{Lu})|\\p{L}+(?:['‘’]\\p{L})*"
        + "|[^-_\\p{L}'‘’0-9]|['‘’]+$")

    static let junkChars = C.set("-_'/")
    static let dashChunks = C.set("-–—")
    static let openBrackets = C.set("([{")
    static let closeBrackets = C.set(")]}")

    private static func hasAlnum(_ s: String) -> Bool {
        s.unicodeScalars.contains { PyText.isAlpha($0) || PyText.isASCIIDigit($0) }
    }

    private static func hasLetters(_ s: String) -> Bool {
        s.unicodeScalars.contains(where: PyText.isAlpha)
    }

    private final class Quotes {
        var count = 0
        func next() -> String {
            count += 1
            return count % 2 == 1 ? "“" : "”"
        }
    }

    private static func punctPhonemes(_ text: String, _ quotes: Quotes) -> String {
        var out: [Unicode.Scalar] = []
        for c in text.unicodeScalars {
            if c == "\"" {
                out.append(contentsOf: quotes.next().unicodeScalars)
            } else if C.puncts.contains(c) {
                out.append(c)
            } else if openBrackets.contains(c) {
                out.append("(")
            } else if closeBrackets.contains(c) {
                out.append(")")
            } else if c == "–" || (c == "-" && out.last != "—") {
                out.append("—")
            }
        }
        return PyText.string(out)
    }

    static func subtokens(_ chunk: String) -> [String] {
        let ns = chunk as NSString
        return subtokenRegex.matches(in: chunk, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// Whitespace chunks -> misaki subtokens -> words and punctuation.
    static func tokenize(_ text: String) -> [G2PItem] {
        var chunks: [String] = []
        var current = String.UnicodeScalarView()
        for c in text.unicodeScalars {
            if PyText.isSpace(c) {
                if !current.isEmpty { chunks.append(String(current)); current = String.UnicodeScalarView() }
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { chunks.append(String(current)) }

        let quotes = Quotes()
        // Items before unwrapping: a list is a word (even with one subtoken).
        var items: [(token: G2PToken?, word: [G2PToken]?)] = []
        for (ci, chunk) in chunks.enumerated() {
            let ws = ci < chunks.count - 1 ? " " : ""
            if chunk.unicodeScalars.allSatisfy({ dashChunks.contains($0) }) {
                items.append((G2PToken(chunk, whitespace: ws, phonemes: "—"), nil))
                continue
            }
            let subs = subtokens(chunk)
            let lastChunk = ci == chunks.count - 1
            var kinds: [Bool] = [] // true = word part
            for (si, s) in subs.enumerated() {
                let sc = s.unicodeScalars
                if sc.count >= 2 && sc.allSatisfy({ $0 == "-" }) {
                    kinds.append(false)
                } else if C.symbols[s] != nil || hasAlnum(s) || sc.allSatisfy({ junkChars.contains($0) }) {
                    kinds.append(true)
                } else if PyText.same(s, ".") {
                    let prevLetter = si > 0 && hasLetters(subs[si - 1])
                    let nextLetter = si + 1 < subs.count && hasLetters(subs[si + 1])
                    if prevLetter && nextLetter {
                        kinds.append(true)
                    } else if prevLetter && si == subs.count - 1 && !lastChunk
                                && subs.dropLast().contains(where: { PyText.same($0, ".") }) {
                        kinds.append(true)
                    } else {
                        kinds.append(false)
                    }
                } else {
                    kinds.append(false)
                }
            }
            var toks: [G2PToken] = []
            var tkKinds: [Bool] = []
            for (s, k) in zip(subs, kinds) {
                if !k, let last = tkKinds.last, !last {
                    toks[toks.count - 1].text += s
                    continue
                }
                toks.append(G2PToken(s))
                tkKinds.append(k)
            }
            guard !toks.isEmpty else { continue }
            toks[toks.count - 1].whitespace = ws
            for (tk, isWordPart) in zip(toks, tkKinds) {
                if !isWordPart {
                    tk.phonemes = punctPhonemes(tk.text, quotes)
                    items.append((tk, nil))
                } else if let last = items.last, var list = last.word, list.last!.whitespace.isEmpty {
                    tk.isHead = false
                    list.append(tk)
                    items[items.count - 1] = (nil, list)
                } else {
                    items.append((nil, [tk]))
                }
            }
        }
        return items.map { item in
            if let token = item.token { return .token(token) }
            let list = item.word!
            return list.count == 1 ? .token(list[0]) : .word(list)
        }
    }

    // MARK: - Context tags

    static let sentenceEnd = C.set(".!?…")
    static let nounTriggers: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "his",
        "her", "its", "our", "their", "no", "every", "each", "some", "any",
        "another", "which", "whose",
    ]
    static let verbTriggers: Set<String> = [
        "to", "will", "would", "can", "could", "should", "must", "might", "may",
        "shall", "do", "does", "did", "don't", "doesn't", "didn't", "won't",
        "wouldn't", "can't", "cannot", "couldn't", "shouldn't", "mustn't",
        "let's", "please", "i'll", "you'll", "we'll", "they'll", "he'll", "she'll",
    ]
    static let perfectTriggers: Set<String> = [
        "have", "has", "had", "having", "i've", "you've", "we've", "they've",
        "haven't", "hasn't", "hadn't",
    ]
    static let presentTriggers = ["i": "VBP", "you": "VBP", "we": "VBP", "they": "VBP",
                                  "he": "VBZ", "she": "VBZ", "it": "VBZ"]
    static let subjectStarters: Set<String> = [
        "i", "you", "he", "she", "it", "we", "they", "the", "a", "an", "this", "these",
        "those", "my", "your", "his", "her", "its", "our", "their", "there", "someone",
        "something", "everyone", "everything", "nobody", "no",
    ]

    private static func hasLower(_ s: String) -> Bool { s.unicodeScalars.contains(where: PyText.isLower) }
    private static func letterCount(_ s: String) -> Int { s.unicodeScalars.filter(PyText.isAlpha).count }

    /// The context tagger that replaces spaCy (spec, "Context tags").
    static func assignTags(_ items: [G2PItem]) {
        let words = items.filter(\.isWord).map(\.text)
        let shouting = !words.contains(where: hasLower) && words.filter({ letterCount($0) >= 2 }).count >= 2
        for (i, item) in items.enumerated() where item.isWord {
            let text = item.text
            let prev: G2PItem? = i > 0 ? items[i - 1] : nil
            let next: G2PItem? = i + 1 < items.count ? items[i + 1] : nil
            let prevWord = (prev?.isWord ?? false) ? prev!.text.lowercased() : nil
            let nextWord = (next?.isWord ?? false) ? next!.text : nil
            var sentenceStart = prev == nil
            if let prev, !prev.isWord, case let .token(t) = prev {
                sentenceStart = (t.phonemes ?? "").unicodeScalars.contains { sentenceEnd.contains($0) }
            }
            let tag: String?
            let lower = text.lowercased()
            if text == "a" {
                tag = "DT"
            } else if text == "A" {
                tag = (nextWord.map(hasLower) ?? false) ? "DT" : nil
            } else if text == "I" {
                tag = "PRP"
            } else if text == "in" || text == "In" || text == "IN" {
                tag = "IN"
            } else if text == "to" || text == "To" || text == "TO" {
                tag = "TO"
            } else if text == "the" || text == "The" || text == "THE" {
                tag = "DT"
            } else if KokoroLexicon.isVs(text) {
                tag = "IN"
            } else if text == "used" || text == "Used" || text == "USED" {
                tag = "VBD"
            } else if lower == "that" || lower == "that's" {
                tag = (nextWord.map { subjectStarters.contains($0.lowercased()) } ?? false) ? nil : "DT"
            } else if !hasLower(text) {
                tag = (shouting || letterCount(text) < 2) ? nil : "NN"
            } else if sentenceStart, let nextWord, nounTriggers.contains(nextWord.lowercased()) {
                tag = "VB"
            } else if let prevWord, nounTriggers.contains(prevWord) {
                tag = "NN"
            } else if let prevWord, verbTriggers.contains(prevWord) {
                tag = "VB"
            } else if let prevWord, perfectTriggers.contains(prevWord) {
                tag = "VBN"
            } else if let prevWord, let t = presentTriggers[prevWord] {
                tag = t
            } else {
                tag = nil
            }
            for tk in item.tokens { tk.tag = tag }
        }
    }

    // MARK: - Resolution helpers

    static func mergeTokens(_ tokens: [G2PToken], unk: String? = nil) -> G2PToken {
        let stresses = Set(tokens.compactMap(\.stress))
        var phonemes: String?
        if let unk {
            var ps = ""
            for tk in tokens {
                if tk.prespace, let last = ps.unicodeScalars.last, !PyText.isSpace(last),
                   let p = tk.phonemes, !p.isEmpty {
                    ps += " "
                }
                ps += tk.phonemes ?? unk
            }
            phonemes = ps
        }
        var text = ""
        for tk in tokens.dropLast() { text += tk.text + tk.whitespace }
        text += tokens.last!.text
        // misaki: tag of the token with the most "capital weight"; first wins ties.
        var best = tokens[0]
        var bestWeight = -1
        for tk in tokens {
            let weight = tk.text.unicodeScalars.reduce(0) { sum, c in
                let s = String(c)
                return sum + (PyText.same(s, s.lowercased()) ? 1 : 2)
            }
            if weight > bestWeight { best = tk; bestWeight = weight }
        }
        return G2PToken(text, tag: best.tag, whitespace: tokens.last!.whitespace, phonemes: phonemes,
                        stress: stresses.count == 1 ? stresses.first : nil,
                        isHead: tokens[0].isHead, prespace: tokens[0].prespace)
    }

    static func tokenContext(_ ctx: TokenContext, _ ps: String?, _ token: G2PToken) -> TokenContext {
        var vowel = ctx.futureVowel
        if let ps, !ps.isEmpty {
            for c in ps.unicodeScalars where C.vowels.contains(c) || C.consonants.contains(c) || C.nonQuotePuncts.contains(c) {
                vowel = C.nonQuotePuncts.contains(c) ? nil : C.vowels.contains(c)
                break
            }
        }
        let t = token.text
        let futureTo = t == "to" || t == "To" || (t == "TO" && (token.tag == "TO" || token.tag == "IN"))
        return TokenContext(futureVowel: vowel, futureTo: futureTo)
    }

    static func resolveTokens(_ tokens: [G2PToken]) {
        var text = ""
        for tk in tokens.dropLast() { text += tk.text + tk.whitespace }
        text += tokens.last!.text
        var classes = Set<Int>()
        for c in text.unicodeScalars where !C.subtokenJunks.contains(c) {
            classes.insert(PyText.isAlpha(c) ? 0 : (PyText.isASCIIDigit(c) ? 1 : 2))
        }
        let prespace = text.unicodeScalars.contains(" ") || text.unicodeScalars.contains("/") || classes.count > 1
        for (i, tk) in tokens.enumerated() {
            if tk.phonemes == nil {
                if i == tokens.count - 1, tk.text.unicodeScalars.count == 1,
                   C.nonQuotePuncts.contains(tk.text.unicodeScalars.first!) {
                    tk.phonemes = tk.text
                } else if tk.text.unicodeScalars.allSatisfy({ C.subtokenJunks.contains($0) }) {
                    tk.phonemes = ""
                }
            } else if i > 0 {
                tk.prespace = prespace
            }
        }
        if prespace { return }
        var indices: [(primary: Bool, weight: Int, index: Int)] = []
        for (i, tk) in tokens.enumerated() {
            if let p = tk.phonemes, !p.isEmpty {
                indices.append((PyText.contains(p, C.primary), stressWeight(p), i))
            }
        }
        if indices.count == 2 && PyText.count(tokens[indices[0].index].text) == 1 {
            let i = indices[1].index
            tokens[i].phonemes = applyStress(tokens[i].phonemes, -0.5)
            return
        }
        let primaries = indices.filter(\.primary).count
        if indices.count < 2 || primaries <= (indices.count + 1) / 2 { return }
        let sorted = indices.sorted { a, b in
            if a.primary != b.primary { return !a.primary }
            if a.weight != b.weight { return a.weight < b.weight }
            return a.index < b.index
        }
        for entry in sorted.prefix(indices.count / 2) {
            tokens[entry.index].phonemes = applyStress(tokens[entry.index].phonemes, -0.5)
        }
    }

    // MARK: - Pipeline

    private func runFallback(_ text: String, _ used: inout [String]) throws -> String {
        if text.unicodeScalars.allSatisfy({ C.subtokenJunks.contains($0) }) { return "" }
        let apos = PyText.replace(PyText.replace(text, "’", with: "'"), "‘", with: "'")
        let word = PyText.foldDiacritics(PyText.nfkc(apos))
        used.append(word)
        return try fallback.phonemes(for: word)
    }

    /// One segment of text (callers split on newlines first).
    func callAsFunction(_ input: String) throws -> G2PResult {
        let text = Self.prepareText(input)
        let normalized = KokoroNormalizer.normalize(text, language)
        let items = Self.tokenize(normalized)
        Self.assignTags(items)
        var used: [String] = []
        var ctx = TokenContext()
        for item in items.reversed() {
            switch item {
            case let .token(w):
                if w.phonemes == nil { w.phonemes = lexicon(w, ctx) }
                if w.phonemes == nil { w.phonemes = try runFallback(w.text, &used) }
                ctx = Self.tokenContext(ctx, w.phonemes, w)
            case let .word(w):
                var left = 0, right = w.count
                var shouldFallback = false
                while left < right {
                    let span = w[left..<right]
                    let tk: G2PToken? = span.contains(where: { $0.phonemes != nil }) ? nil : Self.mergeTokens(Array(span))
                    let ps = tk.flatMap { lexicon($0, ctx) }
                    if let ps, let tk {
                        w[left].phonemes = ps
                        for x in w[(left + 1)..<right] { x.phonemes = "" }
                        ctx = Self.tokenContext(ctx, ps, tk)
                        right = left
                        left = 0
                    } else if left + 1 < right {
                        left += 1
                    } else {
                        right -= 1
                        let t = w[right]
                        if t.phonemes == nil {
                            if t.text.unicodeScalars.allSatisfy({ C.subtokenJunks.contains($0) }) {
                                t.phonemes = ""
                            } else {
                                shouldFallback = true
                                break
                            }
                        }
                        left = 0
                    }
                }
                if shouldFallback {
                    let merged = Self.mergeTokens(w)
                    w[0].phonemes = try runFallback(merged.text, &used)
                    for j in 1..<w.count { w[j].phonemes = "" }
                } else {
                    Self.resolveTokens(w)
                }
            }
        }
        let flat: [G2PToken] = items.map { item in
            switch item {
            case let .token(t): return t
            case let .word(ts): return Self.mergeTokens(ts, unk: "")
            }
        }
        var result = ""
        for tk in flat {
            if let p = tk.phonemes, !p.isEmpty {
                tk.phonemes = PyText.replace(PyText.replace(p, "ɾ", with: "T"), "ʔ", with: "t")
            }
            result += (tk.phonemes ?? "") + tk.whitespace
        }
        return G2PResult(phonemes: result.trimmingCharacters(in: .whitespaces),
                         normalized: normalized, tokens: flat, fallbackWords: used)
    }
}
