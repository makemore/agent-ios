import XCTest
@testable import AgentFrontend
import AgentClient

final class DictationStartGateTests: XCTestCase {
    /// Stores completions instead of asking the OS or creating audio objects.
    private final class Harness {
        let gate = DictationStartGate()
        var microphones: [(Bool) -> Void] = []
        var speeches: [(Bool) -> Void] = []
        var active = true
        var activeChecks = 0
        var starts = 0
        var failures: [DictationStartGate.Failure] = []

        func start(requiresSpeech: Bool = true) {
            gate.start(requiresSpeech: requiresSpeech,
                       requestMicrophone: { [weak self] in self?.microphones.append($0) },
                       requestSpeech: { [weak self] in self?.speeches.append($0) },
                       isActive: { [weak self] in
                           self?.activeChecks += 1
                           return self?.active ?? false
                       },
                       onReady: { [weak self] in self?.starts += 1 },
                       onFailure: { [weak self] in self?.failures.append($0) })
        }
    }

    func testDoesNotStartBeforeBothPermissionsResolve() {
        let h = Harness()
        h.start()
        XCTAssertTrue(h.gate.isPending)
        XCTAssertEqual(h.starts, 0)
        XCTAssertEqual(h.speeches.count, 0)
        h.microphones[0](true)
        XCTAssertEqual(h.speeches.count, 1)
        XCTAssertEqual(h.starts, 0)
        h.speeches[0](true)
        XCTAssertEqual(h.starts, 1)
        XCTAssertFalse(h.gate.isPending)
    }

    func testCancelBeforeMicrophoneResolutionCannotStartOrRequestSpeech() {
        let h = Harness()
        h.start()
        h.gate.cancel()
        h.microphones[0](true)
        XCTAssertEqual(h.starts, 0)
        XCTAssertTrue(h.speeches.isEmpty)
        XCTAssertTrue(h.failures.isEmpty)
        XCTAssertFalse(h.gate.isPending)
    }

    func testCancelBeforeSpeechResolutionCannotStart() {
        let h = Harness()
        h.start()
        h.microphones[0](true)
        h.gate.cancel()
        h.speeches[0](true)
        XCTAssertEqual(h.starts, 0)
        XCTAssertEqual(h.activeChecks, 0)
        XCTAssertTrue(h.failures.isEmpty)
    }

    func testMicrophoneDenialFailsClosedWithoutSpeechPrompt() {
        let h = Harness()
        h.start()
        h.microphones[0](false)
        h.microphones[0](true)
        XCTAssertEqual(h.failures, [.microphoneDenied])
        XCTAssertTrue(h.speeches.isEmpty)
        XCTAssertEqual(h.starts, 0)
        XCTAssertFalse(h.gate.isPending)
    }

    func testSpeechDenialFailsClosedEvenIfCallbackLaterGrants() {
        let h = Harness()
        h.start()
        h.microphones[0](true)
        h.speeches[0](false)
        h.speeches[0](true)
        XCTAssertEqual(h.failures, [.speechDenied])
        XCTAssertEqual(h.starts, 0)
        XCTAssertFalse(h.gate.isPending)
    }

    func testRepeatedTapsDoNotRequestPermissionsTwice() {
        let h = Harness()
        h.start()
        h.start()
        h.microphones[0](true)
        h.start()
        XCTAssertEqual(h.microphones.count, 1)
        XCTAssertEqual(h.speeches.count, 1)
        h.speeches[0](true)
        XCTAssertEqual(h.starts, 1)
    }

    func testDuplicateCallbacksStartExactlyOnce() {
        let h = Harness()
        h.start()
        h.microphones[0](true)
        h.microphones[0](true)
        h.microphones[0](false)
        XCTAssertEqual(h.speeches.count, 1)
        h.speeches[0](true)
        h.speeches[0](true)
        h.speeches[0](false)
        XCTAssertEqual(h.starts, 1)
        XCTAssertTrue(h.failures.isEmpty)
    }

    func testOldPermissionCompletionCannotSatisfyNewRequest() {
        let h = Harness()
        h.start()
        h.microphones[0](true)
        h.gate.cancel()
        h.start()
        h.speeches[0](true)
        h.microphones[0](true)
        XCTAssertEqual(h.starts, 0)
        h.microphones[1](true)
        h.speeches[1](true)
        XCTAssertEqual(h.starts, 1)
    }

    func testInactiveAtAudioBoundaryFailsWithoutAutomaticResume() {
        let h = Harness()
        h.start()
        h.microphones[0](true)
        h.active = false
        h.speeches[0](true)
        XCTAssertEqual(h.failures, [.inactive])
        h.active = true
        h.speeches[0](true)
        XCTAssertEqual(h.starts, 0)
        XCTAssertFalse(h.gate.isPending)
    }

    func testPermissionPromptInactivityIsNotCheckedUntilAudioStart() {
        let h = Harness()
        h.active = false
        h.start()
        h.microphones[0](true)
        XCTAssertEqual(h.activeChecks, 0)
        h.active = true
        h.speeches[0](true)
        XCTAssertEqual(h.activeChecks, 1)
        XCTAssertEqual(h.starts, 1)
    }

    func testWhisperOneShotRequiresOnlyMicrophone() {
        let h = Harness()
        h.start(requiresSpeech: false)
        XCTAssertEqual(h.starts, 0)
        h.microphones[0](true)
        h.microphones[0](true)
        XCTAssertEqual(h.starts, 1)
        XCTAssertTrue(h.speeches.isEmpty)
    }

    func testPermissionRequirementsCoverSystemAndWhisperBargeIn() {
        XCTAssertTrue(DictationEngine.requiresSpeechPermission(backend: .system, continuous: false))
        XCTAssertTrue(DictationEngine.requiresSpeechPermission(backend: .system, continuous: true))
        let whisper = DictationBackend.whisper(model: "not-downloaded")
        XCTAssertFalse(DictationEngine.requiresSpeechPermission(backend: whisper, continuous: false))
        #if targetEnvironment(simulator)
        XCTAssertFalse(DictationEngine.requiresSpeechPermission(backend: whisper, continuous: true))
        #else
        XCTAssertTrue(DictationEngine.requiresSpeechPermission(backend: whisper, continuous: true))
        #endif
    }
}