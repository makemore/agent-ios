import Foundation

/// Python `str` semantics the G2P spec relies on, over Unicode scalars.
///
/// The reference implementation (tools/kokoro-assets/kokoro_ref) is Python,
/// where a string is a sequence of code points. Swift `Character`s are
/// grapheme clusters and `String ==` uses canonical equivalence, so every
/// length, slice, membership test and comparison here goes through
/// `unicodeScalars` (spec, "Porting notes").
enum PyText {
    /// `str.isalpha()` for one code point: general category L*.
    @inline(__always)
    static func isAlpha(_ s: Unicode.Scalar) -> Bool {
        if s.isASCII {
            let v = s.value
            return (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
        }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }

    /// `str.isalnum()` for one code point: L* or N*.
    @inline(__always)
    static func isAlnum(_ s: Unicode.Scalar) -> Bool {
        if s.isASCII {
            let v = s.value
            return (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
        }
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    @inline(__always)
    static func isLower(_ s: Unicode.Scalar) -> Bool {
        s.properties.generalCategory == .lowercaseLetter
    }

    @inline(__always)
    static func isUpperLetter(_ s: Unicode.Scalar) -> Bool {
        s.properties.generalCategory == .uppercaseLetter
    }

    @inline(__always)
    static func isASCIIDigit(_ s: Unicode.Scalar) -> Bool {
        s.value >= 48 && s.value <= 57
    }

    /// `str.isalpha()`: non-empty and every code point a letter.
    static func isAlpha(_ s: String) -> Bool {
        var any = false
        for c in s.unicodeScalars {
            if !isAlpha(c) { return false }
            any = true
        }
        return any
    }

    /// Exactly the characters Python `str.split()` / `str.isspace()` treat as
    /// whitespace.
    @inline(__always)
    static func isSpace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09...0x0D, 0x1C...0x1F, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    // MARK: - Strings as code points

    @inline(__always)
    static func count(_ s: String) -> Int { s.unicodeScalars.count }

    /// Code-point equality (Python `==`), not canonical equivalence.
    @inline(__always)
    static func same(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// `s[:-n]`.
    static func dropLast(_ s: String, _ n: Int) -> String {
        let scalars = s.unicodeScalars
        guard n > 0 else { return s }
        guard scalars.count > n else { return "" }
        return string(scalars.dropLast(n))
    }

    /// `s[n:]`.
    static func dropFirst(_ s: String, _ n: Int) -> String {
        string(s.unicodeScalars.dropFirst(n))
    }

    @inline(__always)
    static func last(_ s: String) -> Unicode.Scalar? { s.unicodeScalars.last }

    /// `s[-2]` (the second-to-last code point).
    static func secondLast(_ s: String) -> Unicode.Scalar? {
        let scalars = s.unicodeScalars
        guard scalars.count >= 2 else { return nil }
        return scalars[scalars.index(scalars.endIndex, offsetBy: -2)]
    }

    @inline(__always)
    static func contains(_ s: String, _ c: Unicode.Scalar) -> Bool {
        s.unicodeScalars.contains(c)
    }

    static func hasSuffix(_ s: String, _ suffix: String) -> Bool {
        let a = Array(s.unicodeScalars), b = Array(suffix.unicodeScalars)
        guard a.count >= b.count else { return false }
        return Array(a[(a.count - b.count)...]) == b
    }

    /// `str.replace(old, new)` for single code points.
    static func replace(_ s: String, _ old: Unicode.Scalar, with new: String) -> String {
        guard s.unicodeScalars.contains(old) else { return s }
        var view = String.UnicodeScalarView()
        for c in s.unicodeScalars {
            if c == old { view.append(contentsOf: new.unicodeScalars) } else { view.append(c) }
        }
        return String(view)
    }

    /// `str.lower()` / `str.upper()`: full, locale-independent Unicode case
    /// mapping (Swift's `lowercased()` uses the root locale).
    @inline(__always)
    static func lower(_ s: String) -> String { s.lowercased() }
    @inline(__always)
    static func upper(_ s: String) -> String { s.uppercased() }

    /// `s == s.lower()` with code-point equality.
    static func isLowerForm(_ s: String) -> Bool { same(s, s.lowercased()) }
    /// `s == s.upper()` with code-point equality.
    static func isUpperForm(_ s: String) -> Bool { same(s, s.uppercased()) }

    /// Python `str.capitalize()` for ASCII strings (dictionary keys).
    static func asciiCapitalize(_ s: String) -> String {
        guard let first = s.unicodeScalars.first else { return s }
        return String(first).uppercased() + dropFirst(s, 1).lowercased()
    }

    static func isASCII(_ s: String) -> Bool { s.utf8.allSatisfy { $0 < 0x80 } }

    /// NFKC (Python `unicodedata.normalize("NFKC", s)`).
    static func nfkc(_ s: String) -> String {
        isASCII(s) ? s : s.precomposedStringWithCompatibilityMapping
    }

    /// café -> cafe: NFKD, drop U+0300...U+036F, NFC.
    static func foldDiacritics(_ s: String) -> String {
        if isASCII(s) { return s }
        let d = s.decomposedStringWithCompatibilityMapping
        let kept = d.unicodeScalars.filter { !(0x300...0x36F).contains($0.value) }
        return string(kept).precomposedStringWithCanonicalMapping
    }
}
