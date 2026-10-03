import XCTest
import Combine
import AgentClient
@testable import AgentKokoro

final class KokoroTTSProviderTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for dir in directories { try? FileManager.default.removeItem(at: dir) }
        directories = []
        AudioSessionCoordinator.owner = .unclaimed
        KokoroTTS.unregister()
        super.tearDown()
    }

    private func makeProvider(installed: Bool = true,
                              autoDownload: Bool = true,
                              voice: KokoroVoice = .defaultVoice,
                              loader: FakeEngineLoader = FakeEngineLoader(),
                              output: FakeOutput = FakeOutput(),
                              fallback: FakeFallbackProvider? = FakeFallbackProvider(),
                              fetcher: FakeFetcher? = nil) async throws -> KokoroTTSProvider {
        let manager: KokoroModelManager
        if installed {
            let (installedManager, dir) = try await KokoroTestSupport.installedManager(voice: voice.id, loader: loader)
            directories.append(dir)
            manager = installedManager
        } else {
            let dir = KokoroTestSupport.temporaryDirectory()
            directories.append(dir)
            manager = KokoroTestSupport.manager(directory: dir, fetcher: fetcher ?? FakeFetcher(contents: KokoroTestSupport.served()),
                                                voice: voice.id, loader: loader)
        }
        return KokoroTTSProvider(voice: voice, speed: 1.0, modelManager: manager, fallback: fallback,
                                 autoDownload: autoDownload, engineHost: manager.engineHost, output: output)
    }

    // MARK: - Speaking

    func testSpeaksChunksInOrderWithKokoro() async throws {
        let loader = FakeEngineLoader()
        let output = FakeOutput()
        let fallback = FakeFallbackProvider()
        let provider = try await makeProvider(loader: loader, output: output, fallback: fallback)

        try await provider.speak("First sentence.")
        try await provider.speak("Second sentence.")
        try await provider.speak("Third sentence.")

        XCTAssertEqual(provider.name, "kokoro")
        XCTAssertEqual(loader.engine.calls.map(\.text), ["First sentence.", "Second sentence.", "Third sentence."])
        XCTAssertEqual(Set(loader.engine.calls.map(\.voiceId)), ["af_heart"])
        XCTAssertEqual(loader.loads, [.enUS], "engine is loaded once and reused")
        // Every utterance streamed both pieces, in order.
        XCTAssertEqual(output.utterances.count, 3)
        for samples in output.utterances {
            XCTAssertEqual(samples, [Float](repeating: 0, count: 240) + [Float](repeating: 1, count: 240))
        }
        XCTAssertTrue(fallback.spoken.isEmpty)
    }

    func testVoiceControllerChunksPlayInOrderAndTurnEnds() async throws {
        let loader = FakeEngineLoader()
        let output = FakeOutput()
        let provider = try await makeProvider(loader: loader, output: output)
        let ended = expectation(description: "turn ended")
        let (controller, sub) = await MainActor.run { () -> (VoiceController, AnyCancellable) in
            let controller = VoiceController(provider: provider, minChars: 10, maxChars: 240)
            return (controller, controller.agentTurnDidEnd.sink { ended.fulfill() })
        }
        defer { sub.cancel() }

        await MainActor.run {
            controller.reset()
            controller.pushDelta("The first sentence is here. ")
            controller.pushDelta("The second one follows it. ")
            controller.pushDelta("And a closing line")
            controller.finishTurn()
        }
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertEqual(loader.engine.calls.map(\.text), [
            "The first sentence is here.",
            "The second one follows it.",
            "And a closing line",
        ])
        let enabled = await MainActor.run { controller.isEnabled }
        XCTAssertTrue(enabled)
    }

    func testSpeakOptionsVoiceIdSelectsKokoroVoice() async throws {
        let loader = FakeEngineLoader()
        let fallback = FakeFallbackProvider()
        let provider = try await makeProvider(loader: loader, fallback: fallback)
        try await provider.modelManager.prepare(voice: "bm_george")

        try await provider.speak("Hello there.", options: TTSSpeakOptions(voiceId: "bm_george"))
        try await provider.speak("Hello again.", options: TTSSpeakOptions(voiceId: "not-a-kokoro-voice"))

        XCTAssertEqual(loader.engine.calls.map(\.voiceId), ["bm_george", "af_heart"])
        XCTAssertEqual(loader.engine.prepared.suffix(2), ["bm_george", "af_heart"],
                       "British voices use the British G2P")
        XCTAssertTrue(fallback.spoken.isEmpty)
    }

    func testVoiceNotDownloadedYetFallsBackAndFetchesIt() async throws {
        let loader = FakeEngineLoader()
        let fallback = FakeFallbackProvider()
        let provider = try await makeProvider(loader: loader, fallback: fallback)
        var reasons: [KokoroFallbackReason] = []
        provider.onFallback = { reasons.append($0) }

        try await provider.speak("Cheerio.", options: TTSSpeakOptions(voiceId: "bf_emma"))
        XCTAssertEqual(fallback.spoken, ["Cheerio."])
        for _ in 0..<400 where !provider.modelManager.isDownloaded(voice: "bf_emma") {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(provider.modelManager.isDownloaded(voice: "bf_emma"))
        await MainActor.run {}
        XCTAssertEqual(reasons, [.modelNotDownloaded])
    }

    func testPunctuationOnlyChunkIsSkipped() async throws {
        let loader = FakeEngineLoader()
        let fallback = FakeFallbackProvider()
        let provider = try await makeProvider(loader: loader, fallback: fallback)
        try await provider.speak("  ...  ")
        try await provider.speak("—")
        XCTAssertTrue(loader.engine.calls.isEmpty)
        XCTAssertTrue(fallback.spoken.isEmpty)
    }

    func testProvidersShareOneLoadedEngineUntilTheModelChanges() async throws {
        let loader = FakeEngineLoader()
        let (manager, dir) = try await KokoroTestSupport.installedManager(loader: loader)
        directories.append(dir)
        func provider() -> KokoroTTSProvider {
            KokoroTTSProvider(voice: .defaultVoice, speed: 1, modelManager: manager, fallback: nil,
                              autoDownload: false, engineHost: manager.engineHost, output: FakeOutput())
        }
        let first = provider()
        let second = provider()

        try await first.speak("One.")
        try await second.speak("Two.")
        XCTAssertEqual(loader.loads.count, 1, "a second chat screen must not load a second model")

        // Re-installing the model invalidates the loaded engine.
        try manager.deleteDownloadedModel()
        try await manager.prepare()
        try await second.speak("Three.")
        XCTAssertEqual(loader.loads.count, 2)
    }

    func testTurnStartLoadsTheModelInTheBackground() async throws {
        let loader = FakeEngineLoader()
        let (manager, dir) = try await KokoroTestSupport.installedManager(loader: loader)
        directories.append(dir)
        manager.engineHost.unload()
        let provider = KokoroTTSProvider(voice: .defaultVoice, speed: 1, modelManager: manager, fallback: nil,
                                         autoDownload: false, engineHost: manager.engineHost, output: FakeOutput())
        provider.prepareForNewTurn()
        try await waitUntil { loader.loads.count == 2 }
        XCTAssertTrue(loader.engine.calls.isEmpty, "warming does not speak")
    }

    func testSpeechMetricsAreReported() async throws {
        let provider = try await makeProvider()
        var metrics: [KokoroSpeechMetrics] = []
        provider.onSpeechMetrics = { metrics.append($0) }
        try await provider.speak("Measure me.")
        await MainActor.run {}
        XCTAssertEqual(metrics.count, 1)
        let m = try XCTUnwrap(metrics.first)
        XCTAssertEqual(m.chunkCount, 2)
        XCTAssertEqual(m.audioSeconds, 480.0 / 24_000, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(m.firstAudioMs, 0)
        XCTAssertGreaterThan(m.synthSeconds, 0)
    }

    // MARK: - Prefetch

    func testPrefetchedChunkIsSynthesisedAheadAndOnlyOnce() async throws {
        let loader = FakeEngineLoader()
        let output = FakeOutput()
        let provider = try await makeProvider(loader: loader, output: output)

        provider.prefetch("Coming up next.", options: TTSSpeakOptions())
        try await waitUntil { loader.engine.calls.count == 1 }
        XCTAssertTrue(output.utterances.isEmpty, "prefetch synthesises but does not play")

        try await provider.speak("Coming up next.")
        XCTAssertEqual(loader.engine.calls.map(\.text), ["Coming up next."])
        XCTAssertEqual(output.utterances, [[Float](repeating: 0, count: 240) + [Float](repeating: 1, count: 240)])
    }

    func testCancelDiscardsPrefetchedAudio() async throws {
        let loader = FakeEngineLoader()
        let output = FakeOutput()
        let provider = try await makeProvider(loader: loader, output: output)

        provider.prefetch("Never mind.", options: TTSSpeakOptions())
        try await waitUntil { loader.engine.calls.count == 1 }
        provider.cancel()
        try await provider.speak("Never mind.")

        XCTAssertEqual(loader.engine.calls.count, 2, "a cancelled prefetch is not reused")
        XCTAssertEqual(output.utterances.count, 1)
    }

    func testVoiceControllerPrefetchesChunksQueuedWhilePlaying() async throws {
        let loader = FakeEngineLoader()
        let output = FakeOutput()
        output.holdPlayback = true
        let provider = try await makeProvider(loader: loader, output: output)
        let ended = expectation(description: "turn ended")
        let (controller, sub) = await MainActor.run { () -> (VoiceController, AnyCancellable) in
            let controller = VoiceController(provider: provider, minChars: 10, maxChars: 240)
            return (controller, controller.agentTurnDidEnd.sink { ended.fulfill() })
        }
        defer { sub.cancel() }

        await MainActor.run {
            controller.reset()
            controller.pushDelta("The first sentence is here. ")
        }
        XCTAssertEqual(output.playbackStarted.wait(timeout: .now() + 5), .success)
        await MainActor.run {
            controller.pushDelta("The second one follows it. ")
            controller.finishTurn()
        }
        // The second chunk is synthesised while the first is still playing.
        try await waitUntil { loader.engine.calls.count == 2 }
        XCTAssertEqual(output.utterances.count, 1)

        output.releasePlayback()
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertEqual(loader.engine.calls.map(\.text), ["The first sentence is here.", "The second one follows it."])
        XCTAssertEqual(output.utterances.count, 2)
    }

    // MARK: - Cancellation

    func testCancelStopsSynthesisPromptly() async throws {
        let loader = FakeEngineLoader()
        loader.engine.blockAfterFirstPiece = true
        let output = FakeOutput()
        let fallback = FakeFallbackProvider()
        let provider = try await makeProvider(loader: loader, output: output, fallback: fallback)

        let started = Date()
        let speaking = Task { try await provider.speak("A long paragraph that takes a while.") }
        XCTAssertEqual(loader.engine.firstPieceDelivered.wait(timeout: .now() + 5), .success)
        provider.cancel()

        do {
            try await speaking.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "cancel must not wait for synthesis to finish")
        try await waitUntil { loader.engine.stoppedEarly } // generation is told to stop
        XCTAssertGreaterThanOrEqual(output.stops, 1, "audio is stopped")
        XCTAssertTrue(fallback.spoken.isEmpty, "a cancel is not a failure")
    }

    func testCancelDuringPlaybackThrowsCancellation() async throws {
        let output = FakeOutput()
        output.holdPlayback = true
        let provider = try await makeProvider(output: output)

        let speaking = Task { try await provider.speak("Playing for a while.") }
        XCTAssertEqual(output.playbackStarted.wait(timeout: .now() + 5), .success)
        provider.cancel()

        do {
            try await speaking.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
    }

    func testTaskCancellationStopsPlayback() async throws {
        let output = FakeOutput()
        output.holdPlayback = true
        let provider = try await makeProvider(output: output)

        let speaking = Task { try await provider.speak("Playing for a while.") }
        XCTAssertEqual(output.playbackStarted.wait(timeout: .now() + 5), .success)
        speaking.cancel() // VoiceController.stop() cancels its drain task

        do {
            try await speaking.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertGreaterThanOrEqual(output.stops, 1)
    }

    func testVoiceControllerStopCancelsKokoroAndFallback() async throws {
        let output = FakeOutput()
        output.holdPlayback = true
        let fallback = FakeFallbackProvider()
        let provider = try await makeProvider(output: output, fallback: fallback)
        let controller = await MainActor.run { VoiceController(provider: provider, minChars: 1, maxChars: 240) }

        await MainActor.run {
            controller.reset()
            controller.pushDelta("Something to say. ")
        }
        XCTAssertEqual(output.playbackStarted.wait(timeout: .now() + 5), .success)
        await MainActor.run { controller.stop() }

        XCTAssertGreaterThanOrEqual(output.stops, 1)
        XCTAssertGreaterThanOrEqual(fallback.cancels, 1)
        let speaking = await MainActor.run { controller.isSpeaking }
        XCTAssertFalse(speaking)
    }

    func testLiveVoiceOwnershipBlocksPlayback() async throws {
        let loader = FakeEngineLoader()
        let provider = try await makeProvider(loader: loader)
        await MainActor.run { AudioSessionCoordinator.owner = .liveVoice }

        do {
            try await provider.speak("Should not play.")
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertTrue(loader.engine.calls.isEmpty)
    }

    // MARK: - Fallback

    func testMissingModelFallsBackAndStartsDownload() async throws {
        let loader = FakeEngineLoader()
        let fallback = FakeFallbackProvider()
        let fetcher = FakeFetcher(contents: KokoroTestSupport.served())
        let provider = try await makeProvider(installed: false, loader: loader, fallback: fallback, fetcher: fetcher)
        var reasons: [KokoroFallbackReason] = []
        provider.onFallback = { reasons.append($0) }

        try await provider.speak("Hello before the model exists.")

        XCTAssertEqual(fallback.spoken, ["Hello before the model exists."])
        // The one-time download starts in the background.
        for _ in 0..<400 where provider.modelManager.currentState != .ready {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(provider.modelManager.currentState, .ready)
        XCTAssertEqual(Set(fetcher.requestedPaths), KokoroTestSupport.expectedPaths(voice: "af_heart"))
        await MainActor.run {}
        XCTAssertEqual(reasons.first, .modelNotDownloaded)

        // Next turn: Kokoro speaks.
        provider.prepareForNewTurn()
        try await provider.speak("Now with the model.")
        XCTAssertEqual(loader.engine.calls.map(\.text), ["Now with the model."])
        XCTAssertEqual(fallback.spoken.count, 1)
    }

    func testFailedAutoDownloadIsTriedOncePerTurn() async throws {
        let fallback = FakeFallbackProvider()
        let fetcher = FakeFetcher(contents: KokoroTestSupport.served())
        fetcher.failingPaths = ["manifest.json"] // e.g. offline
        let provider = try await makeProvider(installed: false, fallback: fallback, fetcher: fetcher)

        provider.prepareForNewTurn()
        try await provider.speak("One.")
        try await waitUntil { fetcher.requests.count == 1 }
        if case .failed = provider.modelManager.currentState {} else {
            try await waitUntil { if case .failed = provider.modelManager.currentState { return true }; return false }
        }
        provider.prepareForNewTurn() // a new turn: fall back again, but no second download in it
        try await provider.speak("Two.")
        try await provider.speak("Three.")
        try await waitUntil { fetcher.requests.count == 2 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fetcher.requests.count, 2, "one attempt per turn, not one per chunk")
        XCTAssertEqual(fallback.spoken, ["One.", "Two.", "Three."])
    }

    func testMissingModelWithoutAutoDownloadDoesNotDownload() async throws {
        let fallback = FakeFallbackProvider()
        let fetcher = FakeFetcher(contents: KokoroTestSupport.served())
        let provider = try await makeProvider(installed: false, autoDownload: false, fallback: fallback, fetcher: fetcher)

        try await provider.speak("Hello.")

        XCTAssertEqual(fallback.spoken, ["Hello."])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(fetcher.requests.isEmpty)
        XCTAssertEqual(provider.modelManager.currentState, .notDownloaded)
    }

    func testEngineLoadFailureFallsBackForTheTurnAndIsNotRetried() async throws {
        let loader = FakeEngineLoader()
        let fallback = FakeFallbackProvider()
        let provider = try await makeProvider(loader: loader, fallback: fallback)
        provider.modelManager.engineHost.unload()
        loader.failLoad = true

        try await provider.speak("First chunk.")
        try await provider.speak("Second chunk.")
        XCTAssertEqual(fallback.spoken, ["First chunk.", "Second chunk."])
        XCTAssertEqual(loader.loads.count, 2) // prepare(), then the failed reload

        // A new turn tries Kokoro again, but the same broken files are not
        // reloaded from disk on every chunk.
        provider.prepareForNewTurn()
        try await provider.speak("Next turn.")
        XCTAssertEqual(fallback.spoken.last, "Next turn.")
        XCTAssertEqual(loader.loads.count, 2)
    }

    func testSynthesisFailureFallsBackForRestOfTurnThenRecovers() async throws {
        let loader = FakeEngineLoader()
        loader.engine.failSynthesis = true
        let fallback = FakeFallbackProvider()
        let provider = try await makeProvider(loader: loader, fallback: fallback)
        var reasons: [KokoroFallbackReason] = []
        provider.onFallback = { reasons.append($0) }

        try await provider.speak("Chunk one.")
        loader.engine.failSynthesis = false
        try await provider.speak("Chunk two.")

        XCTAssertEqual(fallback.spoken, ["Chunk one.", "Chunk two."], "no mid-turn voice switch")
        XCTAssertEqual(loader.engine.calls.map(\.text), ["Chunk one."])
        await MainActor.run {}
        XCTAssertEqual(reasons, [.synthesisFailed, .earlierChunkFellBack])

        provider.prepareForNewTurn()
        try await provider.speak("Next turn.")
        XCTAssertEqual(loader.engine.calls.map(\.text), ["Chunk one.", "Next turn."])
        XCTAssertEqual(fallback.spoken.count, 2)
    }

    func testVoiceControllerResetStartsANewTurn() async throws {
        let loader = FakeEngineLoader()
        loader.engine.failSynthesis = true
        let fallback = FakeFallbackProvider()
        let provider = try await makeProvider(loader: loader, fallback: fallback)
        try await provider.speak("Fails.")
        loader.engine.failSynthesis = false

        await MainActor.run { VoiceController(provider: provider).reset() }
        try await provider.speak("Back on Kokoro.")

        XCTAssertEqual(loader.engine.calls.last?.text, "Back on Kokoro.")
    }

    func testAudioOutputFailureFallsBack() async throws {
        let output = FakeOutput()
        output.failBegin = true
        let fallback = FakeFallbackProvider()
        let provider = try await makeProvider(output: output, fallback: fallback)
        try await provider.speak("No speaker.")
        XCTAssertEqual(fallback.spoken, ["No speaker."])
    }

    func testUnsupportedScriptUsesFallback() async throws {
        let loader = FakeEngineLoader()
        let fallback = FakeFallbackProvider()
        let provider = try await makeProvider(loader: loader, fallback: fallback)
        try await provider.speak("你好，世界。")
        XCTAssertEqual(fallback.spoken, ["你好，世界。"])
        XCTAssertTrue(loader.engine.calls.isEmpty)
    }

    func testWithoutFallbackFailuresSurfaceToTheController() async throws {
        let loader = FakeEngineLoader()
        let provider = try await makeProvider(loader: loader, fallback: nil)
        provider.modelManager.engineHost.unload()
        loader.failLoad = true
        do {
            try await provider.speak("Hello.")
            XCTFail("expected an error")
        } catch let error as KokoroTTSError {
            guard case .unavailable(.engineLoadFailed) = error else { return XCTFail("\(error)") }
        }
    }

    func testFallbackDoesNotReceiveKokoroVoiceId() async throws {
        final class RecordingFallback: TTSProvider {
            let name = "recording"
            var voiceIds: [String?] = []
            func speak(_ text: String, options: TTSSpeakOptions) async throws { voiceIds.append(options.voiceId) }
            func cancel() {}
            func listVoices() async throws -> [VoiceDescriptor] { [] }
        }
        let fallback = RecordingFallback()
        let dir = KokoroTestSupport.temporaryDirectory()
        directories.append(dir)
        let manager = KokoroTestSupport.manager(directory: dir, fetcher: FakeFetcher(contents: [:]))
        let provider = KokoroTTSProvider(voice: .defaultVoice, speed: 1, modelManager: manager, fallback: fallback,
                                         autoDownload: false, engineHost: manager.engineHost, output: FakeOutput())
        try await provider.speak("Hi.", options: TTSSpeakOptions(voiceId: "af_bella"))
        XCTAssertEqual(fallback.voiceIds, [nil])
    }

    func testFailureDiscardsPrefetchesForTheRestOfTheTurn() async throws {
        let loader = FakeEngineLoader()
        loader.engine.failSynthesis = true
        let fallback = FakeFallbackProvider()
        let provider = try await makeProvider(loader: loader, fallback: fallback)

        try await provider.speak("Fails.")
        provider.prefetch("Later chunk.", options: TTSSpeakOptions())
        try await provider.speak("Later chunk.")

        XCTAssertEqual(loader.engine.calls.map(\.text), ["Fails."], "no prefetch once the turn fell back")
        XCTAssertEqual(fallback.spoken, ["Fails.", "Later chunk."])
    }

    // MARK: - Voices

    func testVoiceCatalogUsesKokoroIds() async throws {
        let provider = try await makeProvider()
        let voices = try await provider.listVoices()
        XCTAssertEqual(voices.count, 28)
        let ids = Set(voices.map(\.id))
        for id in ["af_heart", "af_bella", "am_michael", "bf_emma", "bm_george"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        XCTAssertEqual(KokoroVoice.defaultVoice.id, "af_heart")
        XCTAssertEqual(KokoroVoice(id: "bf_emma")?.language, .enGB)
        XCTAssertEqual(KokoroVoice(id: "am_michael")?.gender, .male)
        XCTAssertEqual(KokoroVoice(id: "af_heart")?.label, "Heart (US, female)")
        XCTAssertEqual(KokoroVoice(id: "bm_george")?.name, "George")
        XCTAssertNil(KokoroVoice(id: "zf_xiaobei"))
        XCTAssertEqual(voices.first { $0.id == "bm_george" }?.labels?["lang"], "en-gb")
        XCTAssertEqual(voices.first { $0.id == "bf_emma" }?.labels?["suggested"], "true")
        XCTAssertEqual(voices.first { $0.id == "af_heart" }?.labels?["engine"], "kokoro")
    }

    // MARK: - VoiceFactory wiring

    func testRegisterMakesKokoroTheOnDeviceVoice() {
        var config = ChatWidgetConfig(backendUrl: "http://stub.local", agentKey: "agent")
        config.enableTTS = true
        config.ttsProviderPolicy = .localOnly
        config.voiceId = "bf_emma"
        let apiClient = APIClient(config: config, storage: InMemoryStorage())

        XCTAssertEqual(VoiceFactory.resolveProvider(config: config, apiClient: apiClient).provider?.name, "av-speech")

        let dir = KokoroTestSupport.temporaryDirectory()
        directories.append(dir)
        KokoroTTS.register(configuration: KokoroConfiguration(cacheDirectory: dir), autoDownload: false)
        let resolved = VoiceFactory.resolveProvider(config: config, apiClient: apiClient, voiceId: config.voiceId)
        XCTAssertEqual(resolved.mode, .local)
        XCTAssertEqual(resolved.provider?.name, "kokoro")
        XCTAssertEqual((resolved.provider as? KokoroTTSProvider)?.voice.id, "bf_emma")

        // Protected mode resolves on-device too.
        var privateConfig = config
        privateConfig.ttsProviderPolicy = .automatic
        privateConfig.privateOnly = true
        XCTAssertEqual(VoiceFactory.resolveProvider(config: privateConfig, apiClient: apiClient).provider?.name, "kokoro")

        // Policy still wins: disabled means no voice at all.
        var disabled = config
        disabled.ttsProviderPolicy = .disabled
        XCTAssertNil(VoiceFactory.resolveProvider(config: disabled, apiClient: apiClient).provider)

        // A configured remote proxy is still preferred by .automatic.
        var remote = config
        remote.ttsProviderPolicy = .remote
        XCTAssertEqual(VoiceFactory.resolveProvider(config: remote, apiClient: apiClient).provider?.name, "elevenlabs")

        KokoroTTS.unregister()
        XCTAssertEqual(VoiceFactory.resolveProvider(config: config, apiClient: apiClient).provider?.name, "av-speech")
    }

    func testMakeProviderFallsBackToConfiguredVoiceForUnknownId() {
        XCTAssertEqual(KokoroTTS.makeProvider(voiceId: nil, autoDownload: false).voice, .defaultVoice)
        XCTAssertEqual(KokoroTTS.makeProvider(voiceId: "com.apple.voice.Samantha", autoDownload: false).voice, .defaultVoice)
        XCTAssertEqual(KokoroTTS.makeProvider(voiceId: "am_michael", autoDownload: false).voice.id, "am_michael")
        let british = KokoroConfiguration(voice: "bf_emma", speed: 1.2)
        let provider = KokoroTTS.makeProvider(voiceId: "unknown", configuration: british, autoDownload: false)
        XCTAssertEqual(provider.voice.id, "bf_emma")
        XCTAssertEqual(provider.speed, 1.2)
        XCTAssertEqual(KokoroTTS.engineId, "kokoro")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("condition not met in time") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
