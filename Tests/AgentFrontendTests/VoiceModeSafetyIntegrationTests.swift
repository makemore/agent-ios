import Foundation
import XCTest

/// SwiftUI lifecycle closures cannot be driven without mounting a view/audio
/// stack. Keep just their wiring checks source-level; handshake and mode rules
/// are exercised behaviorally in the other two test files.
final class VoiceModeSafetyIntegrationTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/AgentFrontend/" + relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Source wiring checks require a checkout on the test host.")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func section(_ source: String, from start: String, to end: String) throws -> String {
        let first = try XCTUnwrap(source.range(of: start))
        let last = try XCTUnwrap(source.range(of: end, range: first.upperBound..<source.endIndex))
        return String(source[first.lowerBound..<last.lowerBound])
    }

    func testEndVoiceCancelsTimerAndEngineWithoutFinishingOrSendingDraft() throws {
        let input = try source("Views/InputView.swift")
        let end = try section(input, from: "private func endVoice()", to: "private var continuousAvailable")
        XCTAssertTrue(end.contains("cancelSilenceTimer()"))
        XCTAssertTrue(end.contains("dictation.cancel()"))
        XCTAssertTrue(end.contains("voiceController?.stop()"))
        XCTAssertFalse(end.contains("dictation.stop()"))
        XCTAssertFalse(end.contains("inputText ="))
        XCTAssertFalse(end.contains("sendMessage()"))
        XCTAssertFalse(end.contains("onSend("))
    }

    func testDisappearDisabledInputAndExternalSpeechPreferenceAreWired() throws {
        let input = try source("Views/InputView.swift")
        let disappear = try section(input, from: ".onDisappear {", to: ".onChange(of: scenePhase)")
        XCTAssertTrue(disappear.contains("inputVisible = false"))
        XCTAssertTrue(disappear.contains("endVoice()"))
        let disabled = try section(input, from: ".onChange(of: voiceInputAllowed)", to: ".onChange(of: config.enableContinuousVoice)")
        XCTAssertTrue(disabled.contains("if !allowed { endVoice() }"))
        XCTAssertTrue(input.contains(".onChange(of: speakRepliesEnabled)"))
        let preference = try section(input, from: "private func syncSpeakReplies()", to: "private func circularIconButton")
        XCTAssertTrue(preference.contains("autoSpeakReplies = config.enableTTS && speakRepliesEnabled"))
        XCTAssertTrue(preference.contains("if isContinuous { endVoice() }"))
    }

    func testLifecycleCancelsPendingStartAndNeverRestartsInterruptedAudio() throws {
        let engine = try source("DictationEngine.swift")
        XCTAssertTrue(engine.contains("UIApplication.didEnterBackgroundNotification"))
        XCTAssertTrue(engine.contains("UIApplication.willResignActiveNotification"))
        XCTAssertTrue(engine.contains("AVAudioSession.interruptionNotification"))
        let cancel = try section(engine, from: "func cancel() {\n        startGate.cancel()", to: "private func teardownAudio()")
        XCTAssertTrue(cancel.contains("sessionToken &+= 1"))
        let recycle = try section(engine, from: "private func recycleRecognitionRequest()", to: "func beginUserTurn()")
        XCTAssertTrue(recycle.contains("fail(.interrupted)"))
        XCTAssertFalse(recycle.contains("audioEngine.start()"))
    }

    func testAbsentTapIsGuardedAndWhisperFinalCallbacksCheckSessionToken() throws {
        let engine = try source("DictationEngine.swift")
        let tap = try section(engine, from: "private func removeSharedTap()", to: "private func configureAudioSession")
        let guardRange = try XCTUnwrap(tap.range(of: "guard tapInstalled else { return }"))
        let nodeRange = try XCTUnwrap(tap.range(of: "audioEngine.inputNode"))
        XCTAssertLessThan(guardRange.lowerBound, nodeRange.lowerBound)
        let whisper = try section(engine, from: "private func installWhisperConsumer", to: "private func requestMicPermission")
        XCTAssertEqual(whisper.components(separatedBy: "self.sessionToken == token").count - 1, 2)
    }

    func testVoiceBarIsExplicitAndEndRemainsAvailableDuringLoading() throws {
        let input = try source("Views/InputView.swift")
        let appear = try section(input, from: ".onAppear {", to: ".onDisappear {")
        XCTAssertFalse(appear.contains("dictation.start("))
        XCTAssertFalse(appear.contains("toggleRecording("))
        XCTAssertFalse(appear.contains("preload("))
        let bar = try section(input, from: "private var voiceModeBar:", to: "private func endVoice()")
        XCTAssertTrue(bar.contains("toggleRecording(handsFreeRequested: true)"))
        XCTAssertTrue(bar.contains(".disabled(!voiceSessionInProgress &&"))
        XCTAssertTrue(bar.contains("minHeight: 44"))
        XCTAssertTrue(bar.contains("UIApplication.openSettingsURLString"))
    }

    func testProviderFailureEndsVoiceAndKeepsErrorsGeneric() throws {
        let input = try source("Views/InputView.swift")
        let failure = try section(input, from: ".onReceive(voiceOutputAvailability)", to: "private var canSend")
        XCTAssertTrue(failure.contains("if !available, isContinuous"))
        XCTAssertTrue(failure.contains("endVoice()"))
        XCTAssertTrue(failure.contains("You can keep typing"))
        XCTAssertFalse(failure.contains("localizedDescription"))
    }
}