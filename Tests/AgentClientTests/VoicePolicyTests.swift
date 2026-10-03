import XCTest
@testable import AgentClient

final class VoicePolicyTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        APIClient.sessionConfigurator = nil
        super.tearDown()
    }

    func testPrivateOnlyAutomaticSelectsLocalProviderWithAPIClientPresent() {
        var config = ChatWidgetConfig(backendUrl: "http://stub.local", agentKey: "agent")
        config.privateOnly = true
        config.enableTTS = true
        let apiClient = APIClient(config: config, storage: InMemoryStorage())

        let resolved = VoiceFactory.resolveProvider(config: config, apiClient: apiClient)

        XCTAssertEqual(resolved.mode, .local)
        XCTAssertEqual(resolved.provider?.name, "av-speech")
    }

    func testLocalOnlySelectsSystemTTSEvenWithAPIClientPresent() {
        var config = ChatWidgetConfig(backendUrl: "http://stub.local", agentKey: "agent")
        config.enableTTS = true
        config.ttsProviderPolicy = .localOnly
        let apiClient = APIClient(config: config, storage: InMemoryStorage())

        let resolved = VoiceFactory.resolveProvider(config: config, apiClient: apiClient)

        XCTAssertEqual(resolved.mode, .local)
        XCTAssertEqual(resolved.provider?.name, "av-speech")
    }

    func testRemotePolicySelectsElevenLabsProxyOutsidePrivateMode() {
        var config = ChatWidgetConfig(backendUrl: "http://stub.local", agentKey: "agent")
        config.enableTTS = true
        config.ttsProviderPolicy = .remote
        let apiClient = APIClient(config: config, storage: InMemoryStorage())

        let resolved = VoiceFactory.resolveProvider(config: config, apiClient: apiClient)

        XCTAssertEqual(resolved.mode, .remote)
        XCTAssertEqual(resolved.provider?.name, "elevenlabs")
    }

    func testDisabledPolicyCreatesNoVoiceProvider() {
        var config = ChatWidgetConfig(backendUrl: "http://stub.local", agentKey: "agent")
        config.enableTTS = true
        config.ttsProviderPolicy = .disabled
        let apiClient = APIClient(config: config, storage: InMemoryStorage())

        let resolved = VoiceFactory.resolveProvider(config: config, apiClient: apiClient)

        XCTAssertEqual(resolved.mode, .disabled)
        XCTAssertNil(resolved.provider)
    }

    func testPrivateOnlyDoesNotSelectRemoteVoiceEndpoints() {
        APIClient.sessionConfigurator = { $0.protocolClasses = [MockURLProtocol.self] }
        var config = ChatWidgetConfig(backendUrl: "http://stub.local", agentKey: "agent")
        config.privateOnly = true
        config.enableTTS = true
        let apiClient = APIClient(config: config, storage: InMemoryStorage())

        _ = VoiceFactory.resolveProvider(config: config, apiClient: apiClient)

        XCTAssertFalse(MockURLProtocol.recorded.contains { $0.path.contains("/voice/token") })
        XCTAssertFalse(MockURLProtocol.recorded.contains { $0.path.contains("/voice/tts") })
    }
}
/// The optional per-turn and lookahead hooks ``VoiceController`` gives
/// providers (used by on-device engines such as `AgentKokoro`).
final class VoiceControllerProviderHookTests: XCTestCase {
    private final class RecordingProvider: TTSProvider {
        let name = "recording"
        var spoken: [String] = []
        var prefetched: [String] = []
        var newTurns = 0
        var holdFirst = true
        private var held: CheckedContinuation<Void, Error>?

        func speak(_ text: String, options: TTSSpeakOptions) async throws {
            spoken.append(text)
            if holdFirst {
                holdFirst = false
                try await withCheckedThrowingContinuation { held = $0 }
            }
        }
        func release() { held?.resume(); held = nil }
        func cancel() { held?.resume(throwing: CancellationError()); held = nil }
        func listVoices() async throws -> [VoiceDescriptor] { [] }
        func prepareForNewTurn() { newTurns += 1 }
        func prefetch(_ text: String, options: TTSSpeakOptions) { prefetched.append(text) }
    }

    /// Conforms with only the required members: the hooks are optional.
    private final class MinimalProvider: TTSProvider {
        let name = "minimal"
        func speak(_ text: String, options: TTSSpeakOptions) async throws {}
        func cancel() {}
        func listVoices() async throws -> [VoiceDescriptor] { [] }
    }

    @MainActor
    func testResetAnnouncesANewTurn() {
        let provider = RecordingProvider()
        let controller = VoiceController(provider: provider)
        controller.reset()
        controller.reset()
        XCTAssertEqual(provider.newTurns, 2)
    }

    @MainActor
    func testEveryQueuedChunkIsAnnouncedInOrderBeforeItIsSpoken() async throws {
        let provider = RecordingProvider()
        let controller = VoiceController(provider: provider, minChars: 10, maxChars: 240)
        let ended = expectation(description: "turn ended")
        let sub = controller.agentTurnDidEnd.sink { ended.fulfill() }
        defer { sub.cancel() }

        controller.reset()
        controller.pushDelta("The first sentence is here. ")
        // Let the drain loop start speaking (and hold) the first chunk.
        for _ in 0..<100 where provider.spoken.isEmpty { await Task.yield() }
        controller.pushDelta("The second one follows it. ")
        controller.pushDelta("And the third one too. ")
        controller.finishTurn()

        XCTAssertEqual(provider.prefetched, [
            "The first sentence is here.", "The second one follows it.", "And the third one too.",
        ])
        provider.release()
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertEqual(provider.spoken, ["The first sentence is here.", "The second one follows it.", "And the third one too."])
    }

    @MainActor
    func testProvidersWithoutHooksStillWork() async {
        let controller = VoiceController(provider: MinimalProvider(), minChars: 1)
        let ended = expectation(description: "turn ended")
        let sub = controller.agentTurnDidEnd.sink { ended.fulfill() }
        defer { sub.cancel() }
        controller.reset()
        controller.pushDelta("Hello there. ")
        controller.finishTurn()
        await fulfillment(of: [ended], timeout: 5)
    }
}
