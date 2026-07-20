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