import XCTest
import AgentClient
@testable import AgentKokoro

/// Runs the real sherpa-onnx engine against a real model. Skipped unless
/// `KOKORO_MODEL_DIR` points at a directory holding the files of
/// ``KokoroModelManifest/englishInt8`` — the suite itself never downloads
/// anything. To run it:
///
///     KOKORO_MODEL_DIR=/path/to/kokoro-model swift test --filter KokoroEngineSmokeTests
final class KokoroEngineSmokeTests: XCTestCase {
    private func modelDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["KOKORO_MODEL_DIR"], !path.isEmpty else {
            throw XCTSkip("Set KOKORO_MODEL_DIR to run the real-engine smoke test")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func testSynthesisesStreamedSentences() throws {
        let engine = try SherpaKokoroEngineLoader().loadEngine(modelDirectory: modelDirectory(), accent: .american)
        XCTAssertEqual(engine.sampleRate, 24_000)
        var pieces: [[Float]] = []
        let started = Date()
        try engine.synthesize("Hello from Kokoro on the device. This is a second sentence.",
                              speakerId: KokoroVoice.defaultVoice.speakerId, speed: 1.0) { samples in
            pieces.append(samples)
            return true
        }
        let elapsed = Date().timeIntervalSince(started)
        let seconds = Double(pieces.reduce(0) { $0 + $1.count }) / 24_000
        print("[smoke] \(pieces.count) pieces, \(String(format: "%.2f", seconds)) s audio in \(String(format: "%.2f", elapsed)) s")
        XCTAssertGreaterThanOrEqual(pieces.count, 2, "one callback per sentence")
        XCTAssertGreaterThan(seconds, 1.5)
        XCTAssertTrue(pieces.joined().contains { abs($0) > 0.01 }, "audio is not silent")
    }

    func testStopsWhenTheCallbackSaysSo() throws {
        let engine = try SherpaKokoroEngineLoader().loadEngine(modelDirectory: modelDirectory(), accent: .british)
        var pieces = 0
        try engine.synthesize("First sentence here. Second sentence here. Third sentence here.",
                              speakerId: KokoroVoice(id: "bm_george")!.speakerId, speed: 1.0) { _ in
            pieces += 1
            return false
        }
        XCTAssertEqual(pieces, 1)
    }

    func testOutOfVocabularyWordsUseEspeak() throws {
        let engine = try SherpaKokoroEngineLoader().loadEngine(modelDirectory: modelDirectory(), accent: .american)
        var count = 0
        try engine.synthesize("Zorblaxian frumptuously quibbled.", speakerId: 2, speed: 1.0) { samples in
            count += samples.count
            return true
        }
        XCTAssertGreaterThan(count, 0)
    }

    func testMissingModelFailsToLoadInsteadOfCrashing() {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try SherpaKokoroEngineLoader().loadEngine(modelDirectory: empty, accent: .american))
    }

    /// End to end on real parts: the real manifest's sizes and checksums
    /// verified against local copies of the files (no network), then the
    /// provider speaking through sherpa-onnx and AVAudioEngine.
    func testProviderSpeaksThroughRealEngineAndAudioOutput() async throws {
        let source = try modelDirectory()
        let cache = KokoroTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let manager = KokoroModelManager(
            configuration: .init(baseURL: URL(string: "https://unused.invalid/")!, cacheDirectory: cache),
            fetcher: LocalCopyFetcher(source: source))
        try await manager.download()
        XCTAssertEqual(manager.currentState, .ready)

        let fallback = FakeFallbackProvider()
        let provider = KokoroTTSProvider(voice: .defaultVoice, speed: 1, modelManager: manager, fallback: fallback,
                                         autoDownload: false, engineLoader: SherpaKokoroEngineLoader(),
                                         output: AVAudioEngineOutput())
        var reasons: [KokoroFallbackReason] = []
        provider.onFallback = { reasons.append($0) }

        let started = Date()
        provider.prefetch("Hello from the device.", options: TTSSpeakOptions())
        provider.prefetch("This second chunk was synthesised ahead.", options: TTSSpeakOptions())
        try await provider.speak("Hello from the device.")
        let first = Date().timeIntervalSince(started)
        try await provider.speak("This second chunk was synthesised ahead.")
        let total = Date().timeIntervalSince(started)
        print("[smoke] provider: first chunk done after \(String(format: "%.2f", first)) s, both after \(String(format: "%.2f", total)) s")

        await MainActor.run {}
        XCTAssertEqual(reasons, [])
        XCTAssertTrue(fallback.spoken.isEmpty)
        XCTAssertGreaterThan(total, 2, "speak() returns after playback, not after synthesis")
    }
}

/// Serves model files from a local directory instead of the network.
private struct LocalCopyFetcher: KokoroAssetFetching {
    let source: URL

    func fetch(_ url: URL, to destination: URL, allowsCellularAccess: Bool,
               relativePath: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try FileManager.default.copyItem(at: source.appendingPathComponent(relativePath), to: destination)
    }
}
