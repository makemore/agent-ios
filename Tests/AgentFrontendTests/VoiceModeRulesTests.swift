import XCTest
import AgentClient
@testable import AgentFrontend

final class VoiceModeRulesTests: XCTestCase {
    private var enabledConfig: ChatWidgetConfig {
        var config = ChatWidgetConfig()
        config.enableVoice = true
        config.enableTTS = true
        config.enableContinuousVoice = true
        config.showVoiceModeBar = true
        return config
    }

    func testVoiceModeBarDefaultsOffAndRequiresAllVoiceFlags() {
        XCTAssertFalse(ChatWidgetConfig().showVoiceModeBar)
        XCTAssertTrue(VoiceModeRules.showsBar(config: enabledConfig))
        for keyPath in [\ChatWidgetConfig.showVoiceModeBar, \.enableVoice, \.enableTTS, \.enableContinuousVoice] {
            var config = enabledConfig
            config[keyPath: keyPath] = false
            XCTAssertFalse(VoiceModeRules.showsBar(config: config))
        }
    }

    func testBarModeMicIgnoresPersistedAutoSend() {
        XCTAssertFalse(VoiceModeRules.micUsesContinuous(config: enabledConfig, autoSend: true))
        XCTAssertFalse(VoiceModeRules.micUsesContinuous(config: enabledConfig, autoSend: false))
    }

    func testLegacyMicRetainsExplicitAutoSendPreference() {
        var config = enabledConfig
        config.showVoiceModeBar = false
        XCTAssertTrue(VoiceModeRules.micUsesContinuous(config: config, autoSend: true))
        XCTAssertFalse(VoiceModeRules.micUsesContinuous(config: config, autoSend: false))
        config.enableTTS = false
        XCTAssertFalse(VoiceModeRules.micUsesContinuous(config: config, autoSend: true))
    }

    func testDraftOrFilesBlockConversationStartIncludingWhitespaceDrafts() {
        XCTAssertTrue(VoiceModeRules.canStartConversation(text: "", hasFiles: false))
        XCTAssertFalse(VoiceModeRules.canStartConversation(text: "unsent draft", hasFiles: false))
        XCTAssertFalse(VoiceModeRules.canStartConversation(text: " \n", hasFiles: false))
        XCTAssertFalse(VoiceModeRules.canStartConversation(text: "", hasFiles: true))
        XCTAssertFalse(VoiceModeRules.canStartConversation(text: "draft", hasFiles: true))
    }

    func testAutoSendRequiresLiveListeningAndEverySafetyGate() {
        func allowed(recording: Bool = true, continuous: Bool = true, listening: Bool = true,
                     enabled: Bool = true, loading: Bool = false, speak: Bool = true,
                     output: Bool = true) -> Bool {
            VoiceModeRules.canAutoSend(recording: recording, continuous: continuous, listening: listening,
                                      allowed: enabled, loading: loading, speakReplies: speak, outputAvailable: output)
        }
        XCTAssertTrue(allowed())
        XCTAssertFalse(allowed(recording: false)) // Pending permissions or ended session.
        XCTAssertFalse(allowed(continuous: false)) // One-shot, including Whisper's final pass.
        XCTAssertFalse(allowed(listening: false)) // Agent speaking.
        XCTAssertFalse(allowed(enabled: false)) // Hidden/disabled input or sendDisabled.
        XCTAssertFalse(allowed(loading: true)) // Waiting for a reply.
        XCTAssertFalse(allowed(speak: false)) // External spoken-replies preference changed.
        XCTAssertFalse(allowed(output: false)) // Provider failure must not keep auto-sending.
    }

    func testOutputAvailabilityFailsClosedWithoutExposingProviderReason() {
        XCTAssertTrue(VoiceModeRules.outputAvailable(.local))
        XCTAssertTrue(VoiceModeRules.outputAvailable(.remote))
        XCTAssertFalse(VoiceModeRules.outputAvailable(.disabled))
        XCTAssertFalse(VoiceModeRules.outputAvailable(.unavailable(reason: "provider detail")))
    }

    func testPermissionIssuesOfferSettingsAndFailuresUseGenericCopy() {
        XCTAssertTrue(DictationEngine.Issue.microphoneDenied.offersSettings)
        XCTAssertTrue(DictationEngine.Issue.speechDenied.offersSettings)
        XCTAssertFalse(DictationEngine.Issue.simulator.offersSettings)
        XCTAssertTrue(DictationEngine.Issue.simulator.message.contains("physical device"))
        XCTAssertFalse(DictationEngine.Issue.audioUnavailable.message.isEmpty)
        XCTAssertFalse(DictationEngine.Issue.interrupted.offersSettings)
    }
}