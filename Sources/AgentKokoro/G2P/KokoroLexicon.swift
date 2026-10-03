// Port of misaki's English lexicon (https://github.com/hexgrad/misaki,
// misaki/en.py at fba1236595f2d2bf21d414ba6e57d25256afada3), Copyright hexgrad,
// Apache-2.0, via our reference tools/kokoro-assets/kokoro_ref/g2p.py. Our
// changes are listed in that README ("Differences from misaki").

import Foundation

/// One dictionary value: a phoneme string, JSON `null`, or (gold only) an
/// object of tag -> phonemes-or-null with a `DEFAULT` key.
enum LexEntry {
    case phonemes(String)
    case null
    case tagged([String: String?])
}

/// The context carried right to left through a segment.
struct TokenContext {
    /// nil = unknown / punctuation follows; true = a vowel sound follows.
    var futureVowel: Bool? = nil
    var futureTo = false
}

/// A word or punctuation token (misaki's `MToken`, reduced).
final class G2PToken {
    var text: String
    var tag: String?
    var whitespace: String
    var phonemes: String?
    var stress: Double?
    var isHead = true
    var prespace = false

    init(_ text: String, tag: String? = nil, whitespace: String = "", phonemes: String? = nil,
         stress: Double? = nil, isHead: Bool = true, prespace: Bool = false) {
        self.text = text
        self.tag = tag
        self.whitespace = whitespace
        self.phonemes = phonemes
        self.stress = stress
        self.isHead = isHead
        self.prespace = prespace
    }
}

/// Constants and free functions of `kokoro_ref/g2p.py` (names as in misaki).
enum G2PConstants {
    static func set(_ s: String) -> Set<Unicode.Scalar> { Set(s.unicodeScalars) }

    static let diphthongs = set("AIOQWYʤʧ")
    static let subtokenJunks = set("',-._‘’/")
    static let puncts = set(";:,.!?—…\"“”")
    static let nonQuotePuncts = set(";:,.!?—…")
    static let consonants = set("bdfhjklmnpstvwzðŋɡɹɾʃʒʤʧθ")
    static let usTaus = set("AIOWYiuæɑəɛɪɹʊʌ")
    static let vowels = set("AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ")
    static let symbols = ["%": "percent", "&": "and", "+": "plus", "@": "at"]
    static let primary: Unicode.Scalar = "ˈ"
    static let secondary: Unicode.Scalar = "ˌ"

    /// ' - A-Z a-z
    @inline(__always)
    static func isLexiconOrd(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return v == 39 || v == 45 || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
    }
}

func getParentTag(_ tag: String?) -> String? {
    guard let tag else { return nil }
    if tag.hasPrefix("VB") { return "VERB" }
    if tag.hasPrefix("NN") { return "NOUN" }
    if tag.hasPrefix("ADV") || tag.hasPrefix("RB") { return "ADV" }
    if tag.hasPrefix("ADJ") || tag.hasPrefix("JJ") { return "ADJ" }
    return tag
}

func stressWeight(_ ps: String?) -> Int {
    guard let ps, !ps.isEmpty else { return 0 }
    return ps.unicodeScalars.reduce(0) { $0 + (G2PConstants.diphthongs.contains($1) ? 2 : 1) }
}

func applyStress(_ ps: String?, _ stress: Double?) -> String? {
    typealias C = G2PConstants
    guard let ps, let stress else { return ps }
    let scalars = ps.unicodeScalars
    let hasPrimary = scalars.contains(C.primary)
    let hasSecondary = scalars.contains(C.secondary)
    let hasAnyStress = hasPrimary || hasSecondary
    let hasVowel = scalars.contains { C.vowels.contains($0) }

    /// Moves the leading stress mark to just before the first vowel (the
    /// only stress mark present when this is called).
    func restress(_ mark: Unicode.Scalar) -> String {
        var out = String.UnicodeScalarView()
        var placed = false
        for c in scalars {
            if !placed && C.vowels.contains(c) {
                out.append(mark)
                placed = true
            }
            out.append(c)
        }
        return String(out)
    }

    if stress < -1 {
        return PyText.string(scalars.filter { $0 != C.primary && $0 != C.secondary })
    }
    if stress == -1 || ((stress == 0 || stress == -0.5) && hasPrimary) {
        let noSecondary = PyText.string(scalars.filter { $0 != C.secondary })
        return PyText.replace(noSecondary, C.primary, with: String(C.secondary))
    }
    if (stress == 0 || stress == 0.5 || stress == 1) && !hasAnyStress {
        if !hasVowel { return ps }
        return restress(C.secondary)
    }
    if stress >= 1 && !hasPrimary && hasSecondary {
        return PyText.replace(ps, C.secondary, with: String(C.primary))
    }
    if stress > 1 && !hasAnyStress {
        if !hasVowel { return ps }
        return restress(C.primary)
    }
    return ps
}

/// misaki's `Lexicon`, ported from `kokoro_ref/g2p.py` function by function.
final class KokoroLexicon {
    typealias C = G2PConstants

    let british: Bool
    let golds: [String: LexEntry]
    let silvers: [String: LexEntry]
    private let capStresses: (Double, Double) = (0.5, 2)

    init(british: Bool, golds: [String: LexEntry], silvers: [String: LexEntry]) {
        self.british = british
        self.golds = golds
        self.silvers = silvers
    }

    // MARK: - Dictionaries

    /// misaki `grow_dictionary`: add capitalised / lower-cased variants of
    /// each key (keys are ASCII); the original entries win.
    static func grow(_ d: [String: LexEntry]) -> [String: LexEntry] {
        var e: [String: LexEntry] = [:]
        e.reserveCapacity(d.count)
        for (k, v) in d {
            guard k.utf8.count >= 2 else { continue }
            let lower = k.lowercased()
            if k == lower {
                let cap = PyText.asciiCapitalize(k)
                if k != cap { e[cap] = v }
            } else if k == PyText.asciiCapitalize(lower) {
                e[lower] = v
            }
        }
        e.merge(d) { _, original in original }
        return e
    }

    /// Parses a gold/silver JSON object (already decompressed).
    static func parseDictionary(_ data: Data) throws -> [String: LexEntry] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KokoroEngineError.invalidAsset("dictionary")
        }
        var out: [String: LexEntry] = [:]
        out.reserveCapacity(object.count)
        for (k, v) in object {
            if let s = v as? String {
                out[k] = .phonemes(s)
            } else if let tags = v as? [String: Any] {
                var t: [String: String?] = [:]
                for (tag, value) in tags { t[tag] = value as? String }
                out[k] = .tagged(t)
            } else {
                out[k] = .null
            }
        }
        return out
    }

    // MARK: - misaki Lexicon

    /// `golds.get(word)` as a plain string (single letters are never tagged).
    private func goldString(_ key: String) -> String? {
        if case let .phonemes(s)? = golds[key] { return s }
        return nil
    }

    func getNNP(_ word: String) -> String? {
        var joined = ""
        for c in word.unicodeScalars where PyText.isAlpha(c) {
            guard let ps = goldString(String(c).uppercased()) else { return nil }
            joined += ps
        }
        guard let stressed = applyStress(joined, 0) else { return nil }
        // ps.rsplit(SECONDARY, 1) joined with PRIMARY: the last secondary
        // stress becomes primary.
        var scalars = Array(stressed.unicodeScalars)
        if let i = scalars.lastIndex(of: C.secondary) { scalars[i] = C.primary }
        return PyText.string(scalars)
    }

    func getSpecialCase(_ word: String, _ tag: String?, _ stress: Double?, _ ctx: TokenContext) -> String? {
        if let symbol = C.symbols[word] {
            return lookup(symbol, nil, nil, ctx)
        }
        let scalars = Array(word.unicodeScalars)
        if word.contains(".") {
            // "." in word.strip(".") and word.replace(".", "").isalpha() and
            // len(max(word.split("."), key=len)) < 3
            let stripped = scalars.drop { $0 == "." }.reversed().drop { $0 == "." }
            if stripped.contains("."),
               PyText.isAlpha(PyText.string(scalars.filter { $0 != "." })),
               (scalars.split(separator: ".", omittingEmptySubsequences: false).map(\.count).max() ?? 0) < 3 {
                return getNNP(word)
            }
        }
        switch word {
        case "a", "A":
            return tag == "DT" ? "ɐ" : "ˈA"
        case "am", "Am", "AM":
            if let tag, tag.hasPrefix("NN") { return getNNP(word) }
            if ctx.futureVowel == nil || word != "am" || (stress ?? 0) > 0 { return goldString("am") }
            return "ɐm"
        case "an", "An", "AN":
            if word == "AN", let tag, tag.hasPrefix("NN") { return getNNP(word) }
            return "ɐn"
        default:
            break
        }
        if word == "I" && tag == "PRP" { return "ˌI" }
        if word == "to" || word == "To" || (word == "TO" && (tag == "TO" || tag == "IN")) {
            switch ctx.futureVowel {
            case nil: return goldString("to")
            case false?: return "tə"
            case true?: return "tʊ"
            }
        }
        if word == "in" || word == "In" || (word == "IN" && tag != "NNP") {
            let mark = (ctx.futureVowel == nil || tag != "IN") ? "ˈ" : ""
            return mark + "ɪn"
        }
        if word == "the" || word == "The" || (word == "THE" && tag == "DT") {
            return ctx.futureVowel == true ? "ði" : "ðə"
        }
        if tag == "IN", Self.isVs(word) {
            return lookup("versus", nil, nil, ctx)
        }
        if word == "used" || word == "Used" || word == "USED" {
            guard case let .tagged(tags)? = golds["used"] else { return nil }
            if (tag == "VBD" || tag == "JJ") && ctx.futureTo { return tags["VBD"] ?? nil }
            return tags["DEFAULT"] ?? nil
        }
        return nil
    }

    /// `regex.match(r"(?i)vs\.?$", word)`
    static func isVs(_ word: String) -> Bool {
        let s = Array(word.unicodeScalars)
        guard s.count == 2 || (s.count == 3 && s[2] == ".") else { return false }
        return (s[0] == "v" || s[0] == "V") && (s[1] == "s" || s[1] == "S")
    }

    func isKnown(_ word: String, _ tag: String?) -> Bool {
        if golds[word] != nil || C.symbols[word] != nil || silvers[word] != nil { return true }
        let scalars = word.unicodeScalars
        guard PyText.isAlpha(word), scalars.allSatisfy(C.isLexiconOrd) else { return false }
        if scalars.count == 1 { return true }
        if PyText.isUpperForm(word) && golds[word.lowercased()] != nil { return true }
        let rest = PyText.dropFirst(word, 1)
        return PyText.isUpperForm(rest)
    }

    func lookup(_ input: String, _ inputTag: String?, _ stress: Double?, _ ctx: TokenContext?) -> String? {
        var word = input
        var tag = inputTag
        var isNNP: Bool?
        if PyText.isUpperForm(word) && golds[word] == nil {
            word = word.lowercased()
            isNNP = tag == "NNP"
        }
        var entry = golds[word]
        if entry == nil && isNNP != true { entry = silvers[word] }
        var ps: String?
        switch entry {
        case let .phonemes(s)?:
            ps = s
        case let .tagged(tags)?:
            if ctx != nil && ctx!.futureVowel == nil && tags["None"] != nil {
                tag = "None"
            } else if tag == nil || tags[tag!] == nil {
                tag = getParentTag(tag)
            }
            if let tag, let value = tags[tag] {
                ps = value
            } else {
                ps = tags["DEFAULT"] ?? nil
            }
        case .null?, nil:
            ps = nil
        }
        if ps == nil || (isNNP == true && !PyText.contains(ps!, C.primary)) {
            if let nnp = getNNP(word) { return nnp }
        }
        return applyStress(ps, stress)
    }

    // MARK: Derivations

    private func suffix(_ word: String, _ s: String) -> Bool { PyText.hasSuffix(word, s) }

    func s(_ stem: String?) -> String? {
        guard let stem, let last = PyText.last(stem) else { return nil }
        if C.set("ptkfθ").contains(last) { return stem + "s" }
        if C.set("szʃʒʧʤ").contains(last) { return stem + (british ? "ɪ" : "ᵻ") + "z" }
        return stem + "z"
    }

    func stemS(_ word: String, _ tag: String?, _ stress: Double?, _ ctx: TokenContext) -> String? {
        let n = PyText.count(word)
        guard n >= 3, suffix(word, "s") else { return nil }
        let stem: String
        if !suffix(word, "ss") && isKnown(PyText.dropLast(word, 1), tag) {
            stem = PyText.dropLast(word, 1)
        } else if (suffix(word, "'s") || (n > 4 && suffix(word, "es") && !suffix(word, "ies")))
                    && isKnown(PyText.dropLast(word, 2), tag) {
            stem = PyText.dropLast(word, 2)
        } else if n > 4 && suffix(word, "ies") && isKnown(PyText.dropLast(word, 3) + "y", tag) {
            stem = PyText.dropLast(word, 3) + "y"
        } else {
            return nil
        }
        return s(lookup(stem, tag, stress, ctx))
    }

    func ed(_ stem: String?) -> String? {
        guard let stem, let last = PyText.last(stem) else { return nil }
        if C.set("pkfθʃsʧ").contains(last) { return stem + "t" }
        if last == "d" { return stem + (british ? "ɪ" : "ᵻ") + "d" }
        if last != "t" { return stem + "d" }
        if british || PyText.count(stem) < 2 { return stem + "ɪd" }
        if let prev = PyText.secondLast(stem), C.usTaus.contains(prev) {
            return PyText.dropLast(stem, 1) + "ɾᵻd"
        }
        return stem + "ᵻd"
    }

    func stemEd(_ word: String, _ tag: String?, _ stress: Double?, _ ctx: TokenContext) -> String? {
        let n = PyText.count(word)
        guard n >= 4, suffix(word, "d") else { return nil }
        let stem: String
        if !suffix(word, "dd") && isKnown(PyText.dropLast(word, 1), tag) {
            stem = PyText.dropLast(word, 1)
        } else if n > 4 && suffix(word, "ed") && !suffix(word, "eed") && isKnown(PyText.dropLast(word, 2), tag) {
            stem = PyText.dropLast(word, 2)
        } else {
            return nil
        }
        return ed(lookup(stem, tag, stress, ctx))
    }

    func ing(_ stem: String?) -> String? {
        guard let stem, let last = PyText.last(stem) else { return nil }
        if british {
            if last == "ə" || last == "ː" { return nil }
        } else if PyText.count(stem) > 1 && last == "t", let prev = PyText.secondLast(stem), C.usTaus.contains(prev) {
            return PyText.dropLast(stem, 1) + "ɾɪŋ"
        }
        return stem + "ɪŋ"
    }

    /// `([bcdgklmnprstvxz])\1ing$|cking$`
    private static func doubledConsonantIng(_ word: String) -> Bool {
        let s = Array(word.unicodeScalars)
        guard s.count >= 5, PyText.hasSuffix(word, "ing") else { return false }
        let a = s[s.count - 5], b = s[s.count - 4]
        if a == b && G2PConstants.set("bcdgklmnprstvxz").contains(a) { return true }
        return a == "c" && b == "k"
    }

    func stemIng(_ word: String, _ tag: String?, _ stress: Double?, _ ctx: TokenContext) -> String? {
        let n = PyText.count(word)
        guard n >= 5, suffix(word, "ing") else { return nil }
        let stem: String
        let base = PyText.dropLast(word, 3)
        if n > 5 && isKnown(base, tag) {
            stem = base
        } else if isKnown(base + "e", tag) {
            stem = base + "e"
        } else if n > 5 && Self.doubledConsonantIng(word) && isKnown(PyText.dropLast(word, 4), tag) {
            stem = PyText.dropLast(word, 4)
        } else {
            return nil
        }
        return ing(lookup(stem, tag, stress, ctx))
    }

    func getWord(_ input: String, _ tag: String?, _ stress: Double?, _ ctx: TokenContext) -> String? {
        if let ps = getSpecialCase(input, tag, stress, ctx) { return ps }
        var word = input
        let wl = word.lowercased()
        let n = PyText.count(word)
        if n > 1,
           PyText.isAlpha(PyText.string(word.unicodeScalars.filter { $0 != "'" })),
           !PyText.isLowerForm(word),
           tag != "NNP" || n > 7,
           golds[word] == nil, silvers[word] == nil,
           PyText.isUpperForm(word) || PyText.isLowerForm(PyText.dropFirst(word, 1)) {
            let derivable: () -> Bool = {
                for fn in [self.stemS, self.stemEd, self.stemIng] {
                    if let ps = fn(wl, tag, stress, ctx), !ps.isEmpty { return true }
                }
                return false
            }
            if golds[wl] != nil || silvers[wl] != nil || derivable() {
                word = wl
            }
        }
        if isKnown(word, tag) { return lookup(word, tag, stress, ctx) }
        if suffix(word, "s'") {
            let alt = PyText.dropLast(word, 2) + "'s"
            if isKnown(alt, tag) { return lookup(alt, tag, stress, ctx) }
        }
        if suffix(word, "'") {
            let alt = PyText.dropLast(word, 1)
            if isKnown(alt, tag) { return lookup(alt, tag, stress, ctx) }
        }
        if let ps = stemS(word, tag, stress, ctx) { return ps }
        if let ps = stemEd(word, tag, stress, ctx) { return ps }
        if let ps = stemIng(word, tag, stress ?? 0.5, ctx) { return ps }
        return nil
    }

    func callAsFunction(_ tk: G2PToken, _ ctx: TokenContext) -> String? {
        var word = tk.text
        if word.unicodeScalars.contains(where: { $0 == "‘" || $0 == "’" }) {
            word = PyText.replace(PyText.replace(word, "‘", with: "'"), "’", with: "'")
        }
        word = PyText.foldDiacritics(PyText.nfkc(word))
        let stress: Double? = PyText.isLowerForm(word) ? nil
            : (PyText.isUpperForm(word) ? capStresses.1 : capStresses.0)
        guard let ps = getWord(word, tk.tag, stress, ctx) else { return nil }
        return applyStress(ps, tk.stress)
    }
}
