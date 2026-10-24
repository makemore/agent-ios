import Combine
import XCTest
@testable import AgentClient

@MainActor
final class LiveVoiceCallKitControllerTests: XCTestCase {
    private var system: FakeCallSystem!
    private var audioLog: [String] = []
    private var audioFails = false
    private var allowed = true

    override func setUp() async throws {
        system = FakeCallSystem()
        audioLog = []
        audioFails = false
        allowed = true
    }

    private func controller(startTimeout: UInt64 = 2_000_000_000) -> LiveVoiceCallKitController {
        let audio = LiveVoiceCallAudio(prepare: { [unowned self] in
            if self.audioFails { throw LiveVoiceError.unavailable }
            self.audioLog.append("prepare")
        }, reset: { [unowned self] in self.audioLog.append("reset") })
        return LiveVoiceCallKitController(system: system, audio: audio, permission: { [unowned self] in self.allowed },
                                          startTimeoutNanoseconds: startTimeout,
                                          finalizationTimeoutNanoseconds: 2_000_000_000)
    }

    private func systemCall(_ signaling: CallSignalingFake, _ peer: CallPeerFake) -> LiveVoiceSystemCall {
        LiveVoiceSystemCall(signaling: signaling, conversationId: "thread-conversation") { adapter, id in
            LiveVoiceSession(signaling: adapter, conversationId: id, permission: { true },
                             makeTransport: { [unowned self] in
                                 // The transport is made only after CallKit's start action prepared audio.
                                 self.audioLog.append("transport")
                                 return peer
                             },
                             closeTimeoutNanoseconds: 1_000_000, finalizationTimeoutNanoseconds: 50_000_000,
                             finalizationPollIntervalNanoseconds: 1_000_000)
        }
    }

    private func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for the call", file: file, line: line)
    }

    private func connect(_ controller: LiveVoiceCallKitController, _ peer: CallPeerFake,
                         signaling: CallSignalingFake) async throws -> LiveVoiceCallKitController.Call {
        let call = try await controller.startCall(systemCall(signaling, peer), handle: "agent:ferguson", displayName: "Ferguson")
        try await eventually { peer.answers.count == 1 }
        peer.message(["type": "session.started"])
        try await eventually { controller.call?.phase == .active }
        return call
    }

    func testOutgoingCallPreparesAudioBeforeStartingAndReportsProgress() async throws {
        let controller = controller(), signaling = CallSignalingFake(), peer = CallPeerFake()
        let call = try await connect(controller, peer, signaling: signaling)
        XCTAssertEqual(system.starts.map(\.handle), ["agent:ferguson"])
        XCTAssertEqual(system.starts.map(\.displayName), ["Ferguson"])
        XCTAssertEqual(system.starts.first?.id, call.id)
        XCTAssertEqual(system.startFulfilled, 1)
        XCTAssertEqual(Array(audioLog.prefix(2)), ["prepare", "transport"])
        XCTAssertEqual(system.reports, ["connecting", "connected"])
        XCTAssertEqual(signaling.conversations, ["thread-conversation"])
        XCTAssertEqual(controller.call?.session.state, .active)
    }

    func testEndCallGoesThroughTheSystemAndReleasesTheCallAfterFinalizing() async throws {
        let controller = controller(), signaling = CallSignalingFake(), peer = CallPeerFake()
        var ended: [LiveVoiceCallKitController.Call] = []
        controller.onCallEnded = { ended.append($0) }
        let call = try await connect(controller, peer, signaling: signaling)
        controller.endCall()
        try await eventually { controller.call == nil }
        XCTAssertEqual(system.endRequests, [call.id])
        XCTAssertEqual(system.reports, ["connecting", "connected"], "The system's own end is not reported back")
        XCTAssertTrue(peer.closed)
        XCTAssertEqual(signaling.closedIds.count, 1)
        XCTAssertEqual(ended.map(\.id), [call.id])
        XCTAssertEqual(ended.first?.session.state, .ended)
        XCTAssertTrue(audioLog.contains("reset"))
        controller.endCall()
        XCTAssertEqual(system.endRequests.count, 1)
    }

    func testRemoteHangUpEndsTheSystemCallOnce() async throws {
        let controller = controller(), signaling = CallSignalingFake(), peer = CallPeerFake()
        _ = try await connect(controller, peer, signaling: signaling)
        peer.message(["type": "session.closed"])
        try await eventually { controller.call == nil }
        XCTAssertEqual(system.reports, ["connecting", "connected", "ended:remoteEnded"])
        XCTAssertTrue(system.endRequests.isEmpty)
    }

    func testSessionFailureEndsTheSystemCallAsFailed() async throws {
        let controller = controller(), signaling = CallSignalingFake(), peer = CallPeerFake()
        _ = try await connect(controller, peer, signaling: signaling)
        peer.message(["type": "error"])
        try await eventually { controller.call == nil }
        XCTAssertEqual(system.reports.last, "ended:failed")
        XCTAssertEqual(system.reports.filter { $0.hasPrefix("ended") }.count, 1)
    }

    func testSystemEndActionHangsUp() async throws {
        let controller = controller(), signaling = CallSignalingFake(), peer = CallPeerFake()
        let call = try await connect(controller, peer, signaling: signaling)
        system.events?.systemEnd(call.id) // The lock screen's or a headset's hang-up.
        XCTAssertEqual(controller.call?.phase, .ending)
        XCTAssertFalse(peer.microphoneEnabled)
        try await eventually { controller.call == nil }
        XCTAssertFalse(system.reports.contains { $0.hasPrefix("ended") })
    }

    func testMuteFollowsTheSystemAndOnlyWhenConnected() async throws {
        let controller = controller(), signaling = CallSignalingFake(), peer = CallPeerFake()
        system.performStart = false
        let starting = Task { try await controller.startCall(systemCall(signaling, peer), handle: "a", displayName: "A") }
        try await eventually { system.starts.count == 1 }
        let id = try XCTUnwrap(system.starts.first?.id)
        XCTAssertEqual(system.events?.systemSetMuted(id, muted: true), false, "Not connected yet")
        system.events?.systemStart(id, fulfill: { self.system.startFulfilled += 1 }, fail: {})
        _ = try await starting.value
        try await eventually { peer.answers.count == 1 }
        peer.message(["type": "session.started"])
        try await eventually { controller.call?.phase == .active }
        XCTAssertEqual(system.events?.systemSetMuted(UUID(), muted: true), false, "Another call's action")
        XCTAssertEqual(system.events?.systemSetMuted(id, muted: true), true)
        XCTAssertTrue(controller.call?.session.isMuted == true)
        XCTAssertFalse(peer.microphoneEnabled)
        controller.setMuted(false)
        try await eventually { controller.call?.session.isMuted == false }
        XCTAssertEqual(system.muteRequests.map(\.muted), [false])
    }

    func testBusyAndPermissionAreCheckedBeforeAskingTheSystem() async throws {
        let controller = controller(), signaling = CallSignalingFake(), peer = CallPeerFake()
        _ = try await connect(controller, peer, signaling: signaling)
        let second = systemCall(CallSignalingFake(), CallPeerFake())
        do {
            _ = try await controller.startCall(second, handle: "b", displayName: "B")
            XCTFail("A second call must not start")
        } catch { XCTAssertEqual(error as? LiveVoiceCallKitError, .busy) }
        XCTAssertEqual(second.session.state, .ended, "The refused call can never start")
        XCTAssertEqual(system.starts.count, 1)

        let other = self.controller()
        allowed = false
        do {
            _ = try await other.startCall(systemCall(CallSignalingFake(), CallPeerFake()), handle: "c", displayName: "C")
            XCTFail("No call without the microphone")
        } catch { XCTAssertEqual(error as? LiveVoiceCallKitError, .microphonePermission) }
        XCTAssertEqual(system.starts.count, 1)
    }

    func testRejectedTransactionThrowsAFixedReasonAndNeverStarts() async throws {
        let controller = controller(), signaling = CallSignalingFake(), peer = CallPeerFake()
        system.startError = .unentitled
        let call = systemCall(signaling, peer)
        do {
            _ = try await controller.startCall(call, handle: "a", displayName: "A")
            XCTFail("Expected a refusal")
        } catch { XCTAssertEqual(error as? LiveVoiceCallKitError, .unentitled) }
        XCTAssertNil(controller.call)
        XCTAssertTrue(system.reports.isEmpty, "CallKit has no call to end")
        XCTAssertFalse(audioLog.contains("prepare"))
        XCTAssertFalse(call.start(), "The refused call can never start")
        XCTAssertEqual(peer.offerCount, 0)
    }

    func testAudioPreparationFailureFailsTheStartAction() async throws {
        let controller = controller(), signaling = CallSignalingFake(), peer = CallPeerFake()
        audioFails = true
        do {
            _ = try await controller.startCall(systemCall(signaling, peer), handle: "a", displayName: "A")
            XCTFail("Expected an audio failure")
        } catch { XCTAssertEqual(error as? LiveVoiceCallKitError, .audioBusy) }
        XCTAssertEqual(system.startFailed, 1)
        XCTAssertEqual(system.startFulfilled, 0)
        XCTAssertEqual(system.reports, ["ended:failed"])
        XCTAssertEqual(peer.offerCount, 0)
        XCTAssertNil(controller.call)
    }

    func testStartActionThatNeverComesTimesOut() async throws {
        let controller = controller(startTimeout: 20_000_000), signaling = CallSignalingFake(), peer = CallPeerFake()
        system.performStart = false
        do {
            _ = try await controller.startCall(systemCall(signaling, peer), handle: "a", displayName: "A")
            XCTFail("Expected a timeout")
        } catch { XCTAssertEqual(error as? LiveVoiceCallKitError, .timedOut) }
        XCTAssertEqual(system.reports, ["ended:failed"])
        XCTAssertNil(controller.call)
        // A late start action cannot bring the call back.
        let id = try XCTUnwrap(system.starts.first?.id)
        var failed = false
        system.events?.systemStart(id, fulfill: { XCTFail("Late start must fail") }, fail: { failed = true })
        XCTAssertTrue(failed)
        XCTAssertEqual(peer.offerCount, 0)
    }

    func testUnknownStartActionAndSystemResetAreSafe() async throws {
        let controller = controller(), signaling = CallSignalingFake(), peer = CallPeerFake()
        var failed = false
        system.events?.systemStart(UUID(), fulfill: { XCTFail("Unknown start") }, fail: { failed = true })
        XCTAssertTrue(failed)
        XCTAssertFalse(system.events?.systemAudioActivationAllowed() ?? true)
        _ = try await connect(controller, peer, signaling: signaling)
        XCTAssertTrue(system.events?.systemAudioActivationAllowed() ?? false)
        system.events?.systemReset()
        XCTAssertFalse(peer.microphoneEnabled)
        try await eventually { controller.call == nil }
        XCTAssertFalse(system.reports.contains { $0.hasPrefix("ended") }, "After a reset CallKit has no calls")
    }

    #if !os(iOS)
    func testPlatformsWithoutCallKitRefuseCalls() async throws {
        XCTAssertFalse(LiveVoiceCallKitController.isSupported)
        let controller = LiveVoiceCallKitController(system: UnsupportedLiveVoiceCallSystem(), audio: .callKit,
                                                    permission: { true })
        do {
            _ = try await controller.startCall(systemCall(CallSignalingFake(), CallPeerFake()), handle: "a", displayName: "A")
            XCTFail("Expected unsupported")
        } catch { XCTAssertEqual(error as? LiveVoiceCallKitError, .unsupported) }
        XCTAssertNil(controller.call)
    }
    #endif

    func testErrorMessagesAreFixedText() {
        let all: [LiveVoiceCallKitError] = [.unsupported, .busy, .microphonePermission, .audioBusy, .unentitled,
                                            .providerUnavailable, .callLimitReached, .invalidAction,
                                            .rejected(code: 9), .timedOut, .cancelled]
        for error in all { XCTAssertFalse((error.errorDescription ?? "").isEmpty) }
    }
}

@MainActor
private final class FakeCallSystem: LiveVoiceCallSystem {
    weak var events: (any LiveVoiceCallSystemEvents)?
    var startError: LiveVoiceCallKitError?
    /// Whether CallKit performs the start action straight after accepting the transaction.
    var performStart = true
    var starts: [(id: UUID, handle: String, displayName: String)] = []
    var startFulfilled = 0
    var startFailed = 0
    var endRequests: [UUID] = []
    var muteRequests: [(id: UUID, muted: Bool)] = []
    var reports: [String] = []

    func requestStart(_ id: UUID, handle: String, displayName: String) async throws {
        starts.append((id, handle, displayName))
        if let startError { throw startError }
        if performStart {
            events?.systemStart(id, fulfill: { self.startFulfilled += 1 }, fail: { self.startFailed += 1 })
        }
    }

    func requestEnd(_ id: UUID) async throws {
        endRequests.append(id)
        events?.systemEnd(id)
    }

    func requestMute(_ id: UUID, muted: Bool) async throws {
        muteRequests.append((id, muted))
        guard events?.systemSetMuted(id, muted: muted) == true else { throw LiveVoiceCallKitError.invalidAction }
    }

    func reportConnecting(_ id: UUID) { reports.append("connecting") }
    func reportConnected(_ id: UUID) { reports.append("connected") }
    func reportEnded(_ id: UUID, reason: LiveVoiceCallEndReason) { reports.append("ended:\(reason)") }
}

@MainActor
private final class CallSignalingFake: LiveVoiceSignaling {
    static let response = LiveSessionResponse(id: "2C9F6F38-0B7E-4F57-9C59-6E1D7B3E6A11", conversationId: "thread-conversation",
                                              session: .init(id: "live_call"), transport: .init(sdp: "answer"))
    var conversations: [String?] = []
    var closedIds: [String] = []
    func createLiveSession(sdp: String, conversationId: String?) async throws -> LiveSessionResponse {
        conversations.append(conversationId)
        return Self.response
    }
    func closeLiveSession(id: String) async throws { closedIds.append(id) }
    func liveSessionStatus(id: String) async throws -> LiveSessionStatus {
        LiveSessionStatus(id: id, state: "closed", usageFinalized: true)
    }
}

@MainActor
private final class CallPeerFake: LiveVoiceTransport {
    var onEvent: ((LiveVoiceTransportEvent) -> Void)?
    var offerCount = 0
    var answers: [String] = []
    var microphoneEnabled = false
    var closed = false
    private var stopped = false
    func makeOffer() async throws -> String { offerCount += 1; microphoneEnabled = true; return "offer" }
    func acceptAnswer(_ sdp: String) async throws { answers.append(sdp) }
    func setMicrophoneEnabled(_ enabled: Bool) { if !stopped { microphoneEnabled = enabled } }
    func send(_ command: LiveVoiceCommand, eventId: String) -> Bool { true }
    func stopMedia() { stopped = true; microphoneEnabled = false }
    func close() { closed = true; stopMedia(); onEvent = nil }
    func message(_ event: [String: Any]) {
        onEvent?(.message(try! JSONSerialization.data(withJSONObject: event)))
    }
}
