import Foundation

/// Number and abbreviation normalisation, a function-by-function port of
/// `kokoro_ref/normalize.py` (spec: tools/kokoro-assets/README.md, "Number
/// and abbreviation normalisation"). After it no ASCII digit is left.
///
/// Regexes are the reference's `RULES`, verbatim apart from ICU's
/// named-group syntax (`(?<name>`, names without underscores). Matching is
/// anchored at the scan position with transparent bounds, so lookbehinds
/// see the text before it.
enum KokoroNormalizer {
    // MARK: - Number words

    static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen",
    ]
    static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    static let scales: [(Int, String)] = [
        (1_000_000_000_000, "trillion"), (1_000_000_000, "billion"), (1_000_000, "million"), (1_000, "thousand"),
    ]
    static let maxCardinal = 999_999_999_999_999

    static let months = [
        "January", "February", "March", "April", "May", "June", "July",
        "August", "September", "October", "November", "December",
    ]
    /// In the reference's insertion order (it matters for the regex).
    static let monthAbbrOrder: [(String, Int)] = [
        ("Jan", 1), ("Feb", 2), ("Mar", 3), ("Apr", 4), ("Jun", 6), ("Jul", 7), ("Aug", 8),
        ("Sep", 9), ("Sept", 9), ("Oct", 10), ("Nov", 11), ("Dec", 12),
    ]
    static let monthAbbr = Dictionary(uniqueKeysWithValues: monthAbbrOrder)
    static let scaleSuffix = ["k": "thousand", "m": "million", "b": "billion", "bn": "billion"]
    static let currencies: [String: (String, String, String, String)] = [
        "$": ("dollar", "dollars", "cent", "cents"),
        "£": ("pound", "pounds", "pence", "pence"),
        "€": ("euro", "euros", "cent", "cents"),
    ]
    static let ordinalWords = [
        "one": "first", "two": "second", "three": "third", "five": "fifth",
        "eight": "eighth", "nine": "ninth", "twelve": "twelfth",
    ]

    static func below100(_ n: Int) -> String {
        if n < 20 { return ones[n] }
        let t = n / 10, o = n % 10
        return o == 0 ? tens[t] : "\(tens[t]) \(ones[o])"
    }

    static func below1000(_ n: Int) -> String {
        let h = n / 100, r = n % 100
        var parts: [String] = []
        if h != 0 { parts.append("\(ones[h]) hundred") }
        if r != 0 { parts.append(below100(r)) }
        return parts.joined(separator: " ")
    }

    /// 0 ... 999,999,999,999,999. No "and", no hyphens.
    static func cardinal(_ value: Int) -> String {
        precondition(value >= 0 && value <= maxCardinal)
        if value == 0 { return "zero" }
        var n = value
        var parts: [String] = []
        for (scale, name) in scales where n >= scale {
            parts.append("\(below1000(n / scale)) \(name)")
            n %= scale
        }
        if n != 0 { parts.append(below1000(n)) }
        return parts.joined(separator: " ")
    }

    static func digits(_ s: String) -> String {
        s.unicodeScalars.map { ones[Int($0.value - 48)] }.joined(separator: " ")
    }

    private static func splitLast(_ words: String) -> (String, String) {
        if let r = words.range(of: " ", options: .backwards) {
            return (String(words[..<r.lowerBound]), String(words[r.upperBound...]))
        }
        return ("", words)
    }

    static func toOrdinal(_ words: String) -> String {
        var (head, last) = splitLast(words)
        if let o = ordinalWords[last] {
            last = o
        } else if last.hasSuffix("y") {
            last = String(last.dropLast()) + "ieth"
        } else {
            last += "th"
        }
        return head.isEmpty ? last : "\(head) \(last)"
    }

    static func toPlural(_ words: String) -> String {
        var (head, last) = splitLast(words)
        if last.hasSuffix("y") {
            last = String(last.dropLast()) + "ies"
        } else if last.hasSuffix("s") || last.hasSuffix("x") {
            last += "es"
        } else {
            last += "s"
        }
        return head.isEmpty ? last : "\(head) \(last)"
    }

    static func year(_ n: Int) -> String {
        let hi = n / 100, lo = n % 100
        if hi % 10 == 0 && lo < 10 { return cardinal(n) }
        if lo == 0 { return "\(below100(hi)) hundred" }
        if lo < 10 { return "\(below100(hi)) oh \(ones[lo])" }
        return "\(below100(hi)) \(below100(lo))"
    }

    /// Value of an ASCII digit string, or nil when it is above
    /// ``maxCardinal`` (Python ints never overflow; here only the comparison
    /// with the maximum matters).
    static func value(_ s: String) -> Int? {
        let trimmed = s.drop { $0 == "0" }
        if trimmed.count > 15 { return nil }
        if trimmed.isEmpty { return 0 }
        return Int(trimmed)
    }

    static func integer(_ s: String) -> String {
        if s.contains(",") { return plainInteger(s) }
        let n = s.utf8.count
        if n > 1 && s.hasPrefix("0") { return digits(s) }
        if n == 4 { return year(Int(s)!) }
        if n > 15 { return digits(s) }
        return cardinal(Int(s)!)
    }

    static func plainInteger(_ s: String) -> String {
        if s.contains(",") {
            let raw = s.replacingOccurrences(of: ",", with: "")
            if let v = value(raw) { return cardinal(v) }
            return digits(raw)
        }
        let n = s.utf8.count
        if n > 1 && s.hasPrefix("0") { return digits(s) }
        if n > 15 { return digits(s) }
        return cardinal(Int(s)!)
    }

    static func decimal(_ intPart: String, _ frac: String) -> String {
        let tail = "point " + digits(frac)
        return intPart.isEmpty ? tail : "\(plainInteger(intPart)) \(tail)"
    }

    static func number(_ intPart: String, _ frac: String?, yearOK: Bool = true) -> String {
        if let frac { return decimal(intPart, frac) }
        return yearOK ? integer(intPart) : plainInteger(intPart)
    }

    // MARK: - Rules

    private static let w = "A-Za-z0-9_"
    private static let b = "(?<![\(w)])"
    private static let e = "(?![\(w)])"
    private static func neg(_ name: String) -> String { "(?:(?<![\(w).])(?<\(name)>[-−]))?" }
    private static let int = "(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)"
    private static let monthRE: String = {
        let names = months.joined(separator: "|")
        // sorted(MONTH_ABBR, key=len, reverse=True): stable, longest first.
        let abbrs = monthAbbrOrder.map(\.0).enumerated()
            .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
            .map(\.element).joined(separator: "|")
        return "(?:\(names)|(?:\(abbrs))\\.?)"
    }()
    private static let ampmRE = "(?:[aApP]\\.?[mM]\(e))"

    static let units: [String: (String, String)] = [
        "km/h": ("kilometer per hour", "kilometers per hour"), "mph": ("mile per hour", "miles per hour"),
        "km": ("kilometer", "kilometers"), "cm": ("centimeter", "centimeters"), "mm": ("millimeter", "millimeters"),
        "kg": ("kilogram", "kilograms"), "mg": ("milligram", "milligrams"),
        "lbs": ("pound", "pounds"), "lb": ("pound", "pounds"), "oz": ("ounce", "ounces"),
        "ml": ("milliliter", "milliliters"), "mL": ("milliliter", "milliliters"),
        "kWh": ("kilowatt hour", "kilowatt hours"),
        "KB": ("kilobyte", "kilobytes"), "MB": ("megabyte", "megabytes"),
        "GB": ("gigabyte", "gigabytes"), "TB": ("terabyte", "terabytes"),
        "GHz": ("gigahertz", "gigahertz"), "MHz": ("megahertz", "megahertz"),
        "kHz": ("kilohertz", "kilohertz"), "Hz": ("hertz", "hertz"),
        "°C": ("degree Celsius", "degrees Celsius"), "°F": ("degree Fahrenheit", "degrees Fahrenheit"),
    ]
    private static let unitsRE: String = units.keys
        .sorted { a, b in
            let la = a.unicodeScalars.count, lb = b.unicodeScalars.count
            if la != lb { return la > lb }
            return a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
        }
        .map { NSRegularExpression.escapedPattern(for: $0) }
        .joined(separator: "|")
    private static let numEnd = "(?![0-9])(?!\\.[0-9])(?!,[0-9]{3})"

    enum Kind: CaseIterable {
        case isoDate, slashDate, monthDay, dayMonth, time, hourAmpm, currency, percent, unit,
             plural, ordinal, fraction, groups, dotted, two, number, digits
    }

    static let rules: [(Kind, NSRegularExpression)] = {
        let patterns: [(Kind, String)] = [
            (.isoDate, "\(b)(?<isoy>[0-9]{4})-(?<isom>[0-9]{2})-(?<isod>[0-9]{2})\(e)"),
            (.slashDate, "\(b)(?<sda>[0-9]{1,2})/(?<sdb>[0-9]{1,2})/(?<sdy>[0-9]{4}|[0-9]{2})\(e)"),
            (.monthDay, "\(b)(?<mdm>\(monthRE)) (?<mdd>[0-9]{1,2})(?:st|nd|rd|th)?\(e)(?![:0-9])"),
            (.dayMonth, "\(b)(?<dmd>[0-9]{1,2})(?:st|nd|rd|th)? (?:of )?(?<dmm>\(monthRE))(?![A-Za-z])"),
            (.time, "\(b)(?<th>[0-9]{1,2}):(?<tm>[0-9]{2})(?::(?<ts>[0-9]{2}))?(?:(?: ?(?<tap>\(ampmRE)))|\(e)(?!:[0-9]))"),
            (.hourAmpm, "\(b)(?<hh>[0-9]{1,2}) ?(?<hap>\(ampmRE))"),
            (.currency, neg("cneg") + "(?<csym>[\\$£€])(?<cint>\(int))(?:\\.(?<cfrac>[0-9]+))?\(numEnd)"
                + "(?: (?<cscale>thousand|million|billion|trillion)\(e)|(?<csfx>bn|[kKmMbB])\(e))?"),
            (.percent, neg("pneg") + "(?<pint>\(int))?(?:\\.(?<pfrac>[0-9]+))? ?%"),
            (.unit, neg("uneg") + "(?<uint>\(int))(?:\\.(?<ufrac>[0-9]+))?\(numEnd) ?(?<u>\(unitsRE))\(e)"),
            (.plural, "(?:'|\(b))(?<pl>[0-9]+)'?s\(e)"),
            (.ordinal, "\(b)(?<on>\(int))(?:st|nd|rd|th|ST|ND|RD|TH)\(e)"),
            (.fraction, "\(b)(?<![0-9]/)(?<fn>[0-9]+)/(?<fd>[0-9]+)\(e)(?!/)"),
            (.groups, "\(b)(?<g>[0-9]+(?:[-–][0-9]+)+)\(e)"),
            (.dotted, "\(b)(?<dt>[0-9]+(?:\\.[0-9]+){2,})\(e)"),
            (.two, "(?<=[A-Za-z])2(?=[A-Za-z])"),
            (.number, neg("nneg") + "(?:(?<nint>\(int))(?:\\.(?<nfrac>[0-9]+))?|\\.(?<nlfrac>[0-9]+))\(numEnd)"),
            (.digits, "(?<dg>[0-9]+)"),
        ]
        return patterns.map { kind, pattern in
            // The patterns are constants; a failure here is a programming error.
            (kind, try! NSRegularExpression(pattern: pattern))
        }
    }()

    /// A match with group access by name (nil = did not participate).
    struct Match {
        let text: NSString
        let result: NSTextCheckingResult
        subscript(_ name: String) -> String? {
            let r = result.range(withName: name)
            return r.location == NSNotFound ? nil : text.substring(with: r)
        }
        var start: Int { result.range.location }
    }

    private static func monthFrom(_ token: String) -> Int {
        var t = token
        while t.hasSuffix(".") { t.removeLast() }
        if let i = months.firstIndex(of: t) { return i + 1 }
        return monthAbbr[t]!
    }

    /// "the ", unless the 4 code points before the match already read "the ".
    private static func the(_ m: Match, scalars: [Unicode.Scalar], scalarStart: Int) -> String {
        let from = max(0, scalarStart - 4)
        let before = PyText.string(scalars[from..<scalarStart])
        return PyText.same(before.lowercased(), "the ") ? "" : "the "
    }

    private static func twoDigitYear(_ s: String) -> String {
        let d = Array(s.unicodeScalars)
        return d[0] == "0" ? "oh \(ones[Int(d[1].value - 48)])" : below100(Int(s)!)
    }

    private static func date(_ month: Int, _ day: Int, _ yearString: String?, _ lang: KokoroLanguage, _ the: String) -> String {
        let m = months[month - 1]
        let d = toOrdinal(cardinal(day))
        var y: String?
        if let yearString {
            y = yearString.utf8.count == 4 ? year(Int(yearString)!) : twoDigitYear(yearString)
        }
        let out = lang == .enGB ? "\(the)\(d) of \(m)" : "\(m) \(d)"
        if let y, !y.isEmpty { return "\(out), \(y)" }
        return out
    }

    private static func validMD(_ m: Int, _ d: Int) -> Bool { (1...12).contains(m) && (1...31).contains(d) }

    private static func ampm(_ s: String) -> String {
        let first = s.unicodeScalars.first!
        return first == "a" || first == "A" ? "a.m" : "p.m"
    }

    private static func unit(_ m: Match, _ lang: KokoroLanguage) -> String {
        var (one, many) = units[m["u"]!]!
        if lang == .enGB {
            one = one.replacingOccurrences(of: "meter", with: "metre").replacingOccurrences(of: "liter", with: "litre")
            many = many.replacingOccurrences(of: "meter", with: "metre").replacingOccurrences(of: "liter", with: "litre")
        }
        let neg = m["uneg"] != nil ? "minus " : ""
        let singular = m["uint"] == "1" && m["ufrac"] == nil
        return "\(neg)\(number(m["uint"]!, m["ufrac"], yearOK: false)) \(singular ? one : many)"
    }

    private static func currency(_ m: Match) -> String {
        let (major1, majorN, minor1, minorN) = currencies[m["csym"]!]!
        let intS = m["cint"]!, frac = m["cfrac"]
        var scale = m["cscale"]
        if let sfx = m["csfx"] { scale = scaleSuffix[sfx.lowercased()] }
        let neg = m["cneg"] != nil ? "minus " : ""
        if let scale {
            return "\(neg)\(number(intS, frac, yearOK: false)) \(scale) \(majorN)"
        }
        let raw = intS.replacingOccurrences(of: ",", with: "")
        let majorIsZero = raw.allSatisfy { $0 == "0" }
        let majorIsOne = value(raw) == 1
        if let frac, frac.utf8.count <= 2 {
            let minor = Int(frac.padding(toLength: 2, withPad: "0", startingAt: 0))!
            var parts: [String] = []
            if !majorIsZero || minor == 0 {
                parts.append("\(plainInteger(intS)) \(majorIsOne ? major1 : majorN)")
            }
            if minor != 0 {
                parts.append("\(cardinal(minor)) \(minor == 1 ? minor1 : minorN)")
            }
            return neg + parts.joined(separator: " and ")
        }
        if let frac { return "\(neg)\(decimal(intS, frac)) \(majorN)" }
        return "\(neg)\(plainInteger(intS)) \(majorIsOne ? major1 : majorN)"
    }

    private static func groups(_ s: String) -> String {
        let parts = s.replacingOccurrences(of: "–", with: "-").components(separatedBy: "-")
        let phoneLike = parts.count >= 3
            || parts.contains { $0.utf8.count > 1 && $0.hasPrefix("0") }
            || (parts[0].utf8.count == 3 && parts[1].utf8.count == 4)
        if phoneLike { return parts.map(digits).joined(separator: ", ") }
        return "\(integer(parts[0])) to \(integer(parts[1]))"
    }

    /// The words for a match, or nil to decline (the scanner then tries the
    /// next rule at the same position).
    private static func replace(_ kind: Kind, _ m: Match, _ lang: KokoroLanguage,
                                scalars: [Unicode.Scalar], scalarStart: Int) -> String? {
        switch kind {
        case .isoDate:
            let y = Int(m["isoy"]!)!, mo = Int(m["isom"]!)!, d = Int(m["isod"]!)!
            guard validMD(mo, d), y >= 1000 else { return nil }
            return date(mo, d, m["isoy"], lang, the(m, scalars: scalars, scalarStart: scalarStart))
        case .slashDate:
            let a = Int(m["sda"]!)!, b = Int(m["sdb"]!)!
            let orders = lang == .enGB ? [(b, a), (a, b)] : [(a, b), (b, a)]
            for (mo, d) in orders where validMD(mo, d) {
                return date(mo, d, m["sdy"], lang, the(m, scalars: scalars, scalarStart: scalarStart))
            }
            return nil
        case .monthDay:
            let d = Int(m["mdd"]!)!
            guard (1...31).contains(d) else { return nil }
            return "\(months[monthFrom(m["mdm"]!) - 1]) \(toOrdinal(cardinal(d)))"
        case .dayMonth:
            let d = Int(m["dmd"]!)!
            guard (1...31).contains(d) else { return nil }
            return "\(the(m, scalars: scalars, scalarStart: scalarStart))\(toOrdinal(cardinal(d))) of \(months[monthFrom(m["dmm"]!) - 1])"
        case .time:
            let h = Int(m["th"]!)!, mi = Int(m["tm"]!)!, ap = m["tap"]
            let sec = m["ts"].map { Int($0)! }
            if h > 23 || mi > 59 || (sec ?? 0) > 59 { return nil }
            var words = below100(h)
            if mi == 0 {
                if sec != nil {
                    words += " hundred"
                } else if ap == nil || ap!.isEmpty {
                    words += " o'clock"
                }
            } else if mi < 10 {
                words += " oh \(ones[mi])"
            } else {
                words += " \(below100(mi))"
            }
            if let sec, sec != 0 {
                words += " and \(below100(sec)) \(sec == 1 ? "second" : "seconds")"
            }
            if let ap, !ap.isEmpty { return "\(words) \(ampm(ap))" }
            return words
        case .hourAmpm:
            let h = Int(m["hh"]!)!
            guard (1...12).contains(h) else { return nil }
            return "\(below100(h)) \(ampm(m["hap"]!))"
        case .currency:
            return currency(m)
        case .unit:
            return unit(m, lang)
        case .percent:
            if m["pint"] == nil && m["pfrac"] == nil { return nil }
            let neg = m["pneg"] != nil ? "minus " : ""
            return "\(neg)\(number(m["pint"] ?? "", m["pfrac"], yearOK: false)) percent"
        case .plural:
            return toPlural(integer(m["pl"]!))
        case .ordinal:
            guard let n = value(m["on"]!.replacingOccurrences(of: ",", with: "")) else { return nil }
            return toOrdinal(cardinal(n))
        case .fraction:
            guard let n = value(m["fn"]!), let d = value(m["fd"]!), d != 0 else { return nil }
            let num = cardinal(n)
            let den: String
            if d == 2 {
                den = n == 1 ? "half" : "halves"
            } else if d == 4 {
                den = n == 1 ? "quarter" : "quarters"
            } else if (3...10).contains(d) {
                let o = toOrdinal(cardinal(d))
                den = n == 1 ? o : o + "s"
            } else {
                return "\(num) over \(cardinal(d))"
            }
            return "\(num) \(den)"
        case .groups:
            return groups(m["g"]!)
        case .dotted:
            return m["dt"]!.components(separatedBy: ".").map(plainInteger).joined(separator: " point ")
        case .two:
            return "to"
        case .number:
            let neg = m["nneg"] != nil ? "minus " : ""
            if let lfrac = m["nlfrac"] { return "\(neg)point \(digits(lfrac))" }
            return neg + number(m["nint"]!, m["nfrac"])
        case .digits:
            return integer(m["dg"]!)
        }
    }

    /// The single left-to-right scan (spec, "Number scanner").
    static func normalizeNumbers(_ text: String, _ lang: KokoroLanguage) -> String {
        let scalars = Array(text.unicodeScalars)
        let n = scalars.count
        // Fast path: every productive rule consumes an ASCII digit.
        guard scalars.contains(where: PyText.isASCIIDigit) else { return text }

        // UTF-16 offset of each scalar (NSRegularExpression works in UTF-16),
        // and the reverse map for match ends.
        var offsets = [Int](repeating: 0, count: n + 1)
        var scalarAt: [Int: Int] = [:]
        var o = 0
        for (i, s) in scalars.enumerated() {
            offsets[i] = o
            scalarAt[o] = i
            o += s.utf16.count
        }
        offsets[n] = o
        scalarAt[o] = n
        // Next ASCII digit at or after each position. A rule's first digit
        // is at most 10 code points into its match ("September 1"), so
        // positions further from any digit cannot produce words.
        var nextDigit = [Int](repeating: Int.max, count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            nextDigit[i] = PyText.isASCIIDigit(scalars[i]) ? i : nextDigit[i + 1]
        }

        let ns = text as NSString
        let total = ns.length
        var out = String.UnicodeScalarView()
        var p = 0
        scan: while p < n {
            if nextDigit[p] != Int.max && nextDigit[p] - p <= 12 {
                let range = NSRange(location: offsets[p], length: total - offsets[p])
                for (kind, rx) in rules {
                    guard let result = rx.firstMatch(in: text, options: [.anchored, .withTransparentBounds], range: range),
                          result.range.length > 0 else { continue }
                    let m = Match(text: ns, result: result)
                    guard var words = replace(kind, m, lang, scalars: scalars, scalarStart: p) else { continue }
                    guard let end = scalarAt[result.range.location + result.range.length] else { continue }
                    if p > 0 {
                        let before = scalars[p - 1]
                        if PyText.isAlnum(before) {
                            words = " " + words
                        } else if before == "-" && p >= 2 && PyText.isAlpha(scalars[p - 2]) {
                            words = " " + words
                        }
                    }
                    if end < n && PyText.isAlnum(scalars[end]) { words += " " }
                    out.append(contentsOf: words.unicodeScalars)
                    p = end
                    continue scan
                }
            }
            out.append(scalars[p])
            p += 1
        }
        return String(out)
    }

    // MARK: - Abbreviations

    static let titles: [String: String] = [
        "Mr": "Mister", "Mrs": "Mrs", "Ms": "Mizz", "Dr": "Doctor", "Prof": "Professor",
        "St": "Saint", "Mt": "Mount", "Ft": "Fort", "Gen": "General", "Sgt": "Sergeant",
        "Capt": "Captain", "Lt": "Lieutenant", "Col": "Colonel", "Rev": "Reverend",
        "Hon": "Honorable", "Gov": "Governor", "Sen": "Senator", "Rep": "Representative",
        "Pres": "President",
    ]
    static let titleElse = ["St": "Street", "Dr": "Drive"]
    static let suffixAbbr: [String: String] = [
        "Jr": "Junior", "Sr": "Senior", "Inc": "Incorporated", "Ltd": "Limited",
        "Corp": "Corporation", "Co": "Company", "Bros": "Brothers", "Ave": "Avenue",
        "Blvd": "Boulevard", "Rd": "Road", "approx": "approximately",
        "dept": "department", "Dept": "Department", "est": "established",
        "fig": "figure", "Fig": "Figure", "vs": "versus", "etc": "etc",
    ]
    private static let abbrRE: NSRegularExpression = {
        let keys = Set(titles.keys).union(suffixAbbr.keys)
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        return try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_.])(?<a>" + keys.joined(separator: "|") + ")\\.")
    }()
    private static let numberAbbrRE = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_.])(?<a>No|no)\\. ?(?=[0-9])")

    static func expandAbbreviations(_ input: String) -> String {
        guard input.contains(".") else { return input }
        let text = substitute(numberAbbrRE, in: input) { m, _ in
            m["a"] == "No" ? "Number " : "number "
        }
        return substitute(abbrRE, in: text) { m, rest in
            let a = m["a"]!
            let atEnd = rest.isEmpty
            let us = Array(rest.unicodeScalars.prefix(2))
            let nextCap = us.count == 2 && us[0] == " " && (65...90).contains(us[1].value)
            if let title = titles[a] {
                let word = (nextCap || titleElse[a] == nil) ? title : titleElse[a]!
                return word + (atEnd ? "." : "")
            }
            return suffixAbbr[a]! + ((atEnd || nextCap) ? "." : "")
        }
    }

    /// `re.sub` with a callback that also sees the text after the match.
    private static func substitute(_ rx: NSRegularExpression, in text: String,
                                   _ replacement: (Match, String) -> String) -> String {
        let ns = text as NSString
        let matches = rx.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var last = 0
        for r in matches {
            out += ns.substring(with: NSRange(location: last, length: r.range.location - last))
            let end = r.range.location + r.range.length
            out += replacement(Match(text: ns, result: r), ns.substring(from: end))
            last = end
        }
        out += ns.substring(from: last)
        return out
    }

    /// Stage 2 of the pipeline: abbreviations, then numbers.
    static func normalize(_ text: String, _ lang: KokoroLanguage) -> String {
        normalizeNumbers(expandAbbreviations(text), lang)
    }
}
