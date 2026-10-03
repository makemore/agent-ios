import XCTest
import AgentClient
@testable import AgentKokoro

/// The real engine — ONNX Runtime running Kokoro v1.0 and the BART G2P —
/// against a local copy of the kokoro/v1 asset set. Skipped unless
/// `KOKORO_ASSETS_DIR` (`TEST_RUNNER_KOKORO_ASSETS_DIR` with xcodebuild)
/// points at it; the suite never downloads anything.
final class KokoroEngineSmokeTests: XCTestCase {
    static let reply = "Sure, I can help with that. Your next appointment is on Tuesday at 3:30 p.m., and I'll send a reminder the evening before."

    private func engine(voice: String = "af_heart") throws -> (OnnxKokoroEngine, Double) {
        let assets = try KokoroGolden.assetsDirectory()
        let files = KokoroGolden.files(assets, voice: voice)
        let started = Date()
        let engine = try XCTUnwrap(try OnnxKokoroEngineLoader().loadEngine(files) as? OnnxKokoroEngine)
        try engine.prepare(files)
        return (engine, Date().timeIntervalSince(started) * 1000)
    }

    func testSynthesisesNonSilentAudioOfPlausibleLength() throws {
        let (engine, loadMs) = try engine()
        XCTAssertEqual(engine.sampleRate, 24_000)
        var pieces: [[Float]] = []
        var firstPieceMs: Double?
        let started = Date()
        let stats = try engine.synthesize(Self.reply, voice: .defaultVoice, speed: 1.0) { samples in
            if firstPieceMs == nil { firstPieceMs = Date().timeIntervalSince(started) * 1000 }
            pieces.append(samples)
            return true
        }
        let elapsed = Date().timeIntervalSince(started)
        let samples = pieces.joined()
        let seconds = Double(samples.count) / 24_000
        let rms = sqrt(samples.reduce(0) { $0 + Double($1 * $1) } / Double(max(samples.count, 1)))
        print(String(format: "[kokoro-measure] load %.0f ms; first chunk %.0f ms; %d chunks; %.2f s audio in %.2f s (RTF %.2fx real time); rms %.3f",
                     loadMs, firstPieceMs ?? -1, stats.chunkCount, seconds, elapsed, seconds / elapsed, rms))
        XCTAssertGreaterThanOrEqual(stats.chunkCount, 2, "streams more than one piece")
        XCTAssertEqual(stats.audioSamples, samples.count)
        XCTAssertGreaterThan(seconds, 4, "two sentences of speech")
        XCTAssertLessThan(seconds, 14)
        XCTAssertGreaterThan(rms, 0.01, "audio is not silent")
        XCTAssertTrue(samples.allSatisfy { abs($0) <= 1 }, "clipped to [-1, 1]")
    }

    func testBritishVoiceAndUnknownWordsUseTheBartFallback() throws {
        let (engine, _) = try engine(voice: "bm_george")
        var count = 0
        let stats = try engine.synthesize("Zorblaxian frumptuously quibbled with Anthropic.",
                                          voice: KokoroVoice(id: "bm_george")!, speed: 1.1) { samples in
            count += samples.count
            return true
        }
        XCTAssertGreaterThan(count, 24_000)
        XCTAssertEqual(stats.chunkCount, 1)
    }

    func testStopsWhenTheCallbackSaysSo() throws {
        let (engine, _) = try engine()
        var pieces = 0
        _ = try engine.synthesize("First sentence is right here. Second sentence is right here. Third sentence is here too.",
                                  voice: .defaultVoice, speed: 1.0) { _ in
            pieces += 1
            return false
        }
        XCTAssertEqual(pieces, 1)
    }

    func testNewlinesSplitSegmentsWithAShortPause() throws {
        let (engine, _) = try engine()
        var pieces: [[Float]] = []
        _ = try engine.synthesize("First line.\nSecond line.", voice: .defaultVoice, speed: 1.0) { samples in
            pieces.append(samples)
            return true
        }
        XCTAssertEqual(pieces.count, 3)
        XCTAssertEqual(pieces[1].count, Int(24_000 * OnnxKokoroEngine.newlinePause))
        XCTAssertTrue(pieces[1].allSatisfy { $0 == 0 })
    }

    func testMissingModelFailsToLoadInsteadOfCrashing() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = KokoroGolden.files(empty, voice: "af_heart")
        XCTAssertThrowsError(try OnnxKokoroEngineLoader().loadEngine(files))
    }

    /// End to end on real parts: the pinned manifest and every file's size
    /// and SHA-256 verified on local copies (no network), then the provider
    /// speaking through ONNX Runtime and AVAudioEngine (muted). Reports load
    /// time, time to first audio and real-time factor.
    func testProviderSpeaksThroughRealEngineAndAudioOutput() async throws {
        let assets = try KokoroGolden.assetsDirectory()
        let cache = KokoroTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let config = KokoroConfiguration(baseURL: URL(string: "https://unused.invalid/kokoro/v1/")!, cacheDirectory: cache)
        let host = KokoroEngineHost(loader: OnnxKokoroEngineLoader())
        let manager = KokoroModelManager(configuration: config, fetcher: LocalCopyFetcher(source: assets), engineHost: host)

        let downloadStarted = Date()
        try await manager.prepare()
        print(String(format: "[kokoro-measure] verify+copy+load (cold) %.2f s", Date().timeIntervalSince(downloadStarted)))
        XCTAssertEqual(manager.currentState, .ready)
        host.unload() // measure the load inside the first utterance

        let fallback = FakeFallbackProvider()
        let output = AVAudioEngineOutput()
        output.muted = true
        let provider = KokoroTTSProvider(voice: .defaultVoice, speed: 1, modelManager: manager, fallback: fallback,
                                         autoDownload: false, engineHost: host, output: output)
        var reasons: [KokoroFallbackReason] = []
        var metrics: [KokoroSpeechMetrics] = []
        provider.onFallback = { reasons.append($0) }
        provider.onSpeechMetrics = { metrics.append($0) }

        try await provider.speak("Hello from the device.") // cold: includes the model load
        // VoiceController announces chunks in order as they are queued.
        provider.prefetch(Self.reply, options: TTSSpeakOptions())
        provider.prefetch("This second chunk was synthesised ahead.", options: TTSSpeakOptions())
        try await provider.speak(Self.reply) // warm
        try await provider.speak("This second chunk was synthesised ahead.") // prefetched

        await MainActor.run {}
        XCTAssertEqual(reasons, [])
        XCTAssertTrue(fallback.spoken.isEmpty)
        XCTAssertEqual(metrics.count, 3)
        for (label, m) in zip(["cold", "warm", "prefetched"], metrics) {
            print(String(format: "[kokoro-measure] provider %@: load %.0f ms, first audio %.0f ms, %d chunks, %.2f s audio in %.2f s (RTF %.2fx)",
                         label, m.loadMs, m.firstAudioMs, m.chunkCount, m.audioSeconds, m.synthSeconds, m.realTimeFactor))
        }
        XCTAssertGreaterThan(metrics[0].loadMs, 0)
        XCTAssertEqual(metrics[1].loadMs, 0)
        XCTAssertGreaterThan(metrics[1].audioSeconds, 4)
    }
}

/// Serves asset files from a local directory instead of the network.
struct LocalCopyFetcher: KokoroAssetFetching {
    let source: URL

    func fetch(_ url: URL, to destination: URL, expectedSize: Int64?, allowsCellularDownload: Bool,
               relativePath: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source.appendingPathComponent(relativePath), to: destination)
    }
}
