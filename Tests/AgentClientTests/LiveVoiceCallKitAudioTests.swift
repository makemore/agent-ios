import Foundation
import XCTest
@testable import AgentClient

@MainActor
final class LiveVoiceCallKitAudioTests: XCTestCase {
    func testAudioRequiresAnswerAndActivationInEitherOrderAndStopsOnHold() throws {
        defer { LiveVoiceCallKitAudio.reset() }
        for activationFirst in [true, false] {
            LiveVoiceCallKitAudio.prepare()
            LiveVoiceCallKitAudio.prepare() // Idempotent before the answer.
            XCTAssertTrue(LiveVoiceCallKitAudio.isPrepared)
            XCTAssertFalse(LiveVoiceCallKitAudio.isAudioEnabled)
            if activationFirst { LiveVoiceCallKitAudio.activationChanged(true) }
            XCTAssertFalse(LiveVoiceCallKitAudio.isAudioEnabled)
            let lease = try XCTUnwrap(LiveVoiceCallKitAudio.claim())
            XCTAssertNil(LiveVoiceCallKitAudio.claim(), "Only one transport may own a preparation")
            XCTAssertFalse(LiveVoiceCallKitAudio.isAudioEnabled)
            LiveVoiceCallKitAudio.setMediaReady(true, for: lease)
            XCTAssertEqual(LiveVoiceCallKitAudio.isAudioEnabled, activationFirst)
            LiveVoiceCallKitAudio.activationChanged(true)
            XCTAssertTrue(LiveVoiceCallKitAudio.isAudioEnabled)
            LiveVoiceCallKitAudio.activationChanged(false)
            XCTAssertFalse(LiveVoiceCallKitAudio.isAudioEnabled)
            LiveVoiceCallKitAudio.activationChanged(true)
            XCTAssertTrue(LiveVoiceCallKitAudio.isAudioEnabled)
            LiveVoiceCallKitAudio.setMediaReady(false, for: lease)
            LiveVoiceCallKitAudio.activationChanged(true)
            XCTAssertFalse(LiveVoiceCallKitAudio.isAudioEnabled, "A late activation cannot undo stopMedia")
            LiveVoiceCallKitAudio.release(lease)
            XCTAssertFalse(LiveVoiceCallKitAudio.isPrepared)
            XCTAssertEqual(AudioSessionCoordinator.owner, .unclaimed)
        }
    }

    func testResetKeepsGateClosedUntilPeerReleaseAndIgnoresStaleLease() throws {
        LiveVoiceCallKitAudio.prepare()
        defer { LiveVoiceCallKitAudio.reset() }
        let lease = try XCTUnwrap(LiveVoiceCallKitAudio.claim())
        LiveVoiceCallKitAudio.setMediaReady(true, for: lease)
        LiveVoiceCallKitAudio.activationChanged(true)
        LiveVoiceCallKitAudio.reset()
        XCTAssertFalse(LiveVoiceCallKitAudio.isPrepared)
        XCTAssertEqual(AudioSessionCoordinator.owner, .liveVoice, "Reserve audio until tracks are gone")
        LiveVoiceCallKitAudio.prepare()
        XCTAssertFalse(LiveVoiceCallKitAudio.isPrepared)
        LiveVoiceCallKitAudio.setMediaReady(true, for: lease)
        LiveVoiceCallKitAudio.activationChanged(true)
        XCTAssertFalse(LiveVoiceCallKitAudio.isAudioEnabled)
        LiveVoiceCallKitAudio.release(lease)
        XCTAssertEqual(AudioSessionCoordinator.owner, .unclaimed)

        LiveVoiceCallKitAudio.prepare()
        let next = try XCTUnwrap(LiveVoiceCallKitAudio.claim())
        LiveVoiceCallKitAudio.release(lease)
        LiveVoiceCallKitAudio.setMediaReady(true, for: lease)
        LiveVoiceCallKitAudio.activationChanged(true)
        XCTAssertTrue(LiveVoiceCallKitAudio.isPrepared)
        XCTAssertFalse(LiveVoiceCallKitAudio.isAudioEnabled)
        LiveVoiceCallKitAudio.release(next)
    }

    func testDelayedResetAndPreparationNeverStealNewOutgoingAudio() throws {
        let previousOwner = AudioSessionCoordinator.owner
        defer { LiveVoiceCallKitAudio.reset(); AudioSessionCoordinator.owner = previousOwner }
        LiveVoiceCallKitAudio.prepare()
        let lease = try XCTUnwrap(LiveVoiceCallKitAudio.claim())
        LiveVoiceCallKitAudio.release(lease)
        // A new ordinary Live transport has claimed the shared session.
        AudioSessionCoordinator.owner = .liveVoice
        LiveVoiceCallKitAudio.reset()
        LiveVoiceCallKitAudio.activationChanged(false)
        LiveVoiceCallKitAudio.release(lease)
        LiveVoiceCallKitAudio.prepare()
        XCTAssertFalse(LiveVoiceCallKitAudio.isPrepared)
        XCTAssertEqual(AudioSessionCoordinator.owner, .liveVoice)
    }

    /// The iOS-only adapter and UIApplication wiring are excluded on macOS.
    /// Check just these contracts without starting WebRTC or any provider.
    func testNativeActivationAndBackgroundPolicyWiring() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentClient/Voice")
        guard FileManager.default.fileExists(atPath: root.path) else { throw XCTSkip("Requires a checkout") }
        let native = try String(contentsOf: root.appendingPathComponent("NativeLiveVoiceTransport.swift"), encoding: .utf8)
        XCTAssertTrue(native.contains("if callKitAudioLease == nil {\n            try audio.setActive(true)"))
        XCTAssertTrue(native.contains("if activatedAudio { try? audio.setActive(false) }"))
        XCTAssertTrue(native.contains("LiveVoiceCallKitAudio.setMediaReady(true, for: callKitAudioLease)"))
        XCTAssertTrue(native.contains("LiveVoiceCallKitAudio.setMediaReady(false, for: callKitAudioLease)"))
        XCTAssertTrue(native.contains("LiveVoiceCallKitAudio.release(callKitAudioLease)"))
        let bridge = try String(contentsOf: root.appendingPathComponent("LiveVoiceCallKitAudio.swift"), encoding: .utf8)
        XCTAssertTrue(bridge.contains("RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)"))
        XCTAssertTrue(bridge.contains("RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)"))
        XCTAssertFalse(bridge.contains(".setActive("))
        let attempt = try String(contentsOf: root.appendingPathComponent("LiveVoiceAttempt.swift"), encoding: .utf8)
        XCTAssertTrue(attempt.contains("guard usesCallKitAudio || UIApplication.shared.applicationState == .active"))
        XCTAssertTrue(attempt.contains("if !usesCallKitAudio { terminalEvents.append(UIApplication.didEnterBackgroundNotification) }"))
        XCTAssertTrue(attempt.contains("guard let self, !self.usesCallKitAudio else { return }"))
        XCTAssertTrue(attempt.contains("AVAudioSession.mediaServicesWereLostNotification"))
    }
}