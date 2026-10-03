import XCTest
@testable import AgentKokoro

/// Unit tests of the text front end that need no model files.
final class KokoroTextTests: XCTestCase {
    private func tokens(_ spec: [(String, String)]) -> [G2PToken] {
        spec.enumerated().map { i, item in
            G2PToken(item.0, whitespace: i == spec.count - 1 ? "" : " ", phonemes: item.1)
        }
    }

    func testStreamingPiecesStartShortAndRampUp() {
        // "Hello there, my friend. ..." with made-up phonemes.
        let ts = tokens([
            ("Hello", "həlˈO"), ("there", "ðˈɛɹ"), (",", ","), ("my", "mI"), ("friend", "fɹˈɛnd"), (".", "."),
            ("This", "ðɪs"), ("is", "ɪz"), ("the", "ðə"), ("second", "sˈɛkənd"), ("sentence", "sˈɛntəns"), (".", "."),
            ("And", "ænd"), ("a", "ɐ"), ("third", "θˈɜɹd"), ("one", "wˈʌn"), (",", ","), ("with", "wɪð"),
            ("a", "ɐ"), ("clause", "klˈɔz"), (".", "."),
        ])
        let pieces = KokoroChunker.streamingPieces(ts)
        XCTAssertEqual(pieces.map(\.text), [
            "Hello there ,",                              // first: 12 phonemes, at a clause
            "my friend . This is the second sentence .",  // "my friend ." alone is < 20
            "And a third one , with a clause .",          // a clause cut would need 1.5 × 40
        ])
        XCTAssertEqual(pieces.map(\.phonemes).joined(separator: " "), KokoroChunker.chunk(ts).map(\.phonemes).joined(separator: " "))
    }

    func testStreamingPiecesKeepShortTextWhole() {
        let ts = tokens([("Hi", "hˈI"), ("!", "!"), ("Thanks", "θˈæŋks"), (".", ".")])
        XCTAssertEqual(KokoroChunker.streamingPieces(ts).count, 1, "no piece below the minimum, no tiny tail")
        XCTAssertTrue(KokoroChunker.streamingPieces([]).isEmpty)
    }

    func testChunkerCutsLongTextAtSentenceEnds() {
        var spec: [(String, String)] = []
        for _ in 0..<40 { spec += [("word", "wˈɜɹd"), ("again", "əɡˈɛn"), (".", ".")] }
        let chunks = KokoroChunker.chunk(tokens(spec))
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { PyText.count($0.phonemes) <= 510 })
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.phonemes.hasSuffix(".") })
    }

    func testCodePointHelpers() {
        let s = "ɑ̃bc" // a + combining tilde is one Character but two code points
        XCTAssertEqual(PyText.count(s), 4)
        XCTAssertEqual(PyText.dropLast(s, 2), "ɑ̃")
        XCTAssertEqual(PyText.last("ɑ̃"), "\u{303}")
        XCTAssertFalse(PyText.same("é", "e\u{301}"), "code points, not canonical equivalence")
        XCTAssertTrue(PyText.isAlpha("Ünïcode"))
        XCTAssertFalse(PyText.isAlpha("it's"))
        XCTAssertFalse(PyText.isAlpha(""))
        XCTAssertEqual(PyText.foldDiacritics("café naïve"), "cafe naive")
        XCTAssertEqual(PyText.asciiCapitalize("hELLO"), "Hello")
        XCTAssertTrue(PyText.isSpace("\u{3000}"))
        XCTAssertFalse(PyText.isSpace("\u{200B}"))
    }

    func testPrepareTextKeepsEllipsisAndCollapsesWhitespace() {
        XCTAssertEqual(KokoroG2P.prepareText("  Wait…\u{00A0}what’s\tthis ﬁle?\n"), "Wait… what's this file?")
        XCTAssertEqual(KokoroG2P.prepareText("x²"), "x2")
    }

    func testNormalizerSpotChecks() {
        let cases: [(String, KokoroLanguage, String)] = [
            ("It costs $3.50, or £12", .enUS, "It costs three dollars and fifty cents, or twelve pounds"),
            ("3/4/2024", .enGB, "the third of April, twenty twenty four"),
            ("$5M", .enUS, "five million dollars"),
            ("COVID-19", .enUS, "COVID- nineteen"),
            ("20°C", .enUS, "twenty degrees Celsius"),
            ("5 km", .enGB, "five kilometres"),
            ("No. 5", .enUS, "Number five"),
            ("Dr. Smith lives on Main St. near", .enUS, "Doctor Smith lives on Main Street near"),
            ("12345678901234567890", .enUS, "one two three four five six seven eight nine zero one two three four five six seven eight nine zero"),
            ("no digits here", .enUS, "no digits here"),
        ]
        for (input, lang, want) in cases {
            XCTAssertEqual(KokoroNormalizer.normalize(input, lang), want, input)
        }
    }
}
