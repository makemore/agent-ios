import XCTest
@testable import AgentKokoro

/// The cross-platform golden vectors of kokoro/v1 (tools/kokoro-assets,
/// README "Golden test vectors"). Every row must match exactly.
///
/// The vectors, `manifest.json`, `vocab.json` and `voices.json` are test
/// resources. Rows that need the dictionaries or ONNX models read them from
/// a local copy of the asset set, named by `KOKORO_ASSETS_DIR`
/// (`TEST_RUNNER_KOKORO_ASSETS_DIR` through xcodebuild), e.g.
/// `tools/kokoro-assets/build/kokoro/v1`. Without it those tests skip.
final class KokoroGoldenTests: XCTestCase {
    // MARK: - Without model files

    func testNormalizerMatchesEveryGoldenRow() throws {
        let rows = try KokoroGolden.rows("golden-g2p.jsonl")
        XCTAssertEqual(rows.count, 1190)
        var failures: [String] = []
        for row in rows {
            let lang = KokoroLanguage(rawValue: row["voice_lang"] as! String)!
            let text = row["text"] as! String
            let expected = row["normalized"] as! String
            let actual = KokoroNormalizer.normalize(KokoroG2P.prepareText(text), lang)
            if !PyText.same(actual, expected) {
                failures.append("\(row["id"]!) \(lang.rawValue): \(text.debugDescription) -> \(actual.debugDescription), want \(expected.debugDescription)")
            }
        }
        failures.prefix(30).forEach { print("[golden normalize] \($0)") }
        XCTAssertEqual(failures.count, 0, "normalized mismatches: \(failures.count) of \(rows.count)")
    }

    func testTokenIdsAndStyleRowsMatchGolden() throws {
        let vocab = try KokoroVocab(data: Data(contentsOf: KokoroGolden.resource("vocab.json")))
        XCTAssertEqual(vocab.sampleRate, 24_000)
        let rows = try KokoroGolden.rows("golden-tokens.jsonl")
        XCTAssertEqual(rows.count, 14)
        for row in rows {
            let phonemes = row["phonemes"] as! String
            let expected = (row["input_ids"] as! [NSNumber]).map(\.int64Value)
            XCTAssertEqual(vocab.modelInputIds(phonemes), expected, phonemes)
            XCTAssertEqual(KokoroVoicePack.styleIndex(tokenCount: expected.count - 2),
                           (row["style_index"] as! NSNumber).intValue)
        }
    }

    // MARK: - With the asset set

    func testG2PMatchesEveryGoldenRow() throws {
        let assets = try KokoroGolden.assetsDirectory()
        let rows = try KokoroGolden.rows("golden-g2p.jsonl")
        var failures: [String] = []
        var checked = 0
        var withFallback = 0
        for lang in KokoroLanguage.allCases {
            let g2p = try KokoroGolden.g2p(assets, lang)
            for row in rows where row["voice_lang"] as? String == lang.rawValue {
                checked += 1
                if !(row["fallback"] as! [String]).isEmpty { withFallback += 1 }
                let text = row["text"] as! String
                let result = try g2p(text)
                let want = row["phonemes"] as! String
                let wantFallback = row["fallback"] as! [String]
                if !PyText.same(result.phonemes, want) || !PyText.same(result.normalized, row["normalized"] as! String) {
                    failures.append("\(row["id"]!) \(lang.rawValue): \(text.debugDescription) -> \(result.phonemes.debugDescription), want \(want.debugDescription)")
                } else if result.fallbackWords != wantFallback {
                    failures.append("\(row["id"]!) \(lang.rawValue): fallback \(result.fallbackWords), want \(wantFallback)")
                }
            }
        }
        failures.prefix(40).forEach { print("[golden g2p] \($0)") }
        XCTAssertEqual(checked, 1190)
        XCTAssertEqual(withFallback, 77, "rows that exercise the BART fallback")
        XCTAssertEqual(failures.count, 0, "G2P mismatches: \(failures.count) of \(rows.count)")
    }

    func testBartMatchesEveryGoldenRow() throws {
        let assets = try KokoroGolden.assetsDirectory()
        let rows = try KokoroGolden.rows("golden-bart.jsonl")
        XCTAssertEqual(rows.count, 112)
        var failures = 0
        var checked = 0
        for lang in KokoroLanguage.allCases {
            let dir = assets.appendingPathComponent("g2p/\(lang.rawValue)")
            let bart = try KokoroBartG2P(model: dir.appendingPathComponent("g2p.onnx"),
                                         vocab: Data(contentsOf: dir.appendingPathComponent("g2p-vocab.json")))
            for row in rows where row["voice_lang"] as? String == lang.rawValue {
                checked += 1
                let word = row["word"] as! String
                let (input, output) = try bart.decodeIds(word)
                let wantInput = (row["input_ids"] as! [NSNumber]).map(\.int64Value)
                let wantOutput = (row["output_ids"] as! [NSNumber]).map(\.int64Value)
                if input != wantInput || output != wantOutput || !PyText.same(bart.idsToPhonemes(output), row["phonemes"] as! String) {
                    failures += 1
                    print("[golden bart] \(lang.rawValue) \(word): \(output) want \(wantOutput) (min_margin \(row["min_margin"]!))")
                }
            }
        }
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(checked, 112)
    }

    func testChunksMatchGolden() throws {
        let assets = try KokoroGolden.assetsDirectory()
        let rows = try KokoroGolden.rows("golden-chunks.jsonl")
        XCTAssertEqual(rows.count, 4)
        for lang in KokoroLanguage.allCases {
            let g2p = try KokoroGolden.g2p(assets, lang)
            for row in rows where row["voice_lang"] as? String == lang.rawValue {
                let result = try g2p(row["text"] as! String)
                XCTAssertTrue(PyText.same(result.phonemes, row["phonemes"] as! String))
                let chunks = KokoroChunker.chunk(result.tokens)
                let want = row["chunks"] as! [[String: Any]]
                XCTAssertEqual(chunks.count, want.count, lang.rawValue)
                for (chunk, expected) in zip(chunks, want) {
                    XCTAssertTrue(PyText.same(chunk.phonemes, expected["phonemes"] as! String),
                                  "\(lang.rawValue): \(chunk.phonemes) want \(expected["phonemes"]!)")
                    XCTAssertEqual(PyText.count(chunk.phonemes), (expected["n"] as! NSNumber).intValue)
                    XCTAssertEqual(chunk.text, expected["text"] as? String)
                }
                // Streaming pieces only re-split those chunks at punctuation.
                let pieces = KokoroChunker.streamingPieces(result.tokens)
                XCTAssertGreaterThanOrEqual(pieces.count, chunks.count)
                XCTAssertTrue(PyText.same(pieces.map(\.phonemes).joined(separator: " "),
                                          chunks.map(\.phonemes).joined(separator: " ")))
                XCTAssertTrue(pieces.allSatisfy { PyText.count($0.phonemes) <= KokoroChunker.maxPhonemes })
            }
        }
    }
}

enum KokoroGolden {
    static func resource(_ name: String) throws -> URL {
        guard let dir = Bundle.module.url(forResource: "kokoro-v1", withExtension: nil) else {
            throw XCTSkip("test resources missing")
        }
        return dir.appendingPathComponent(name)
    }

    static func rows(_ name: String) throws -> [[String: Any]] {
        let text = try String(contentsOf: resource(name), encoding: .utf8)
        return try text.split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }

    /// A local copy of the asset set, or a skip.
    static func assetsDirectory() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["KOKORO_ASSETS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set KOKORO_ASSETS_DIR (TEST_RUNNER_KOKORO_ASSETS_DIR with xcodebuild) to a local kokoro/v1 asset set, e.g. tools/kokoro-assets/build/kokoro/v1")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("No manifest.json in KOKORO_ASSETS_DIR (\(path))")
        }
        return url
    }

    /// The engine's view of a local asset directory for one voice.
    static func files(_ assets: URL, voice: String) -> KokoroAssetFiles {
        let lang = KokoroLanguage(voiceId: voice)!
        let g2p = assets.appendingPathComponent("g2p/\(lang.rawValue)")
        return KokoroAssetFiles(
            language: lang, voiceId: voice,
            model: assets.appendingPathComponent("model/kokoro-v1.0-q8.onnx"),
            vocab: assets.appendingPathComponent("model/vocab.json"),
            voice: assets.appendingPathComponent("voices/\(voice).bin"),
            gold: g2p.appendingPathComponent("gold.json.gz"),
            silver: g2p.appendingPathComponent("silver.json.gz"),
            g2pModel: g2p.appendingPathComponent("g2p.onnx"),
            g2pVocab: g2p.appendingPathComponent("g2p-vocab.json"))
    }

    private static var cache: [KokoroLanguage: KokoroG2P] = [:]

    static func g2p(_ assets: URL, _ lang: KokoroLanguage) throws -> KokoroG2P {
        if let hit = cache[lang] { return hit }
        let started = Date()
        let g = try OnnxKokoroEngine.loadG2P(files(assets, voice: lang == .enUS ? "af_heart" : "bf_emma"))
        print("[golden] \(lang.rawValue) G2P loaded in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        cache[lang] = g
        return g
    }
}
