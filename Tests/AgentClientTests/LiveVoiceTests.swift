import Combine
import XCTest
@testable import AgentClient

@MainActor
final class LiveVoiceTests: XCTestCase {
    private func model(_ signaling: any LiveVoiceSignaling, _ peer: LivePeerMock,
                       permission: @escaping @MainActor () async -> Bool = { true },
                       closeTimeout: UInt64 = 1_000_000_000,
                       connectionTimeout: UInt64 = 5_000_000_000,
                       finalizationTimeout: UInt64 = 1_000_000_000) -> LiveVoiceSession {
        LiveVoiceSession(signaling: signaling, conversationId: "existing-conversation", permission: permission,
                         makeTransport: { peer }, connectionTimeoutNanoseconds: connectionTimeout,
                         closeTimeoutNanoseconds: closeTimeout,
                         finalizationTimeoutNanoseconds: finalizationTimeout,
                         finalizationPollIntervalNanoseconds: 1_000_000)
    }

    private func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for live voice state", file: file, line: line)
    }

    private func connect(_ session: LiveVoiceSession, _ peer: LivePeerMock) async throws {
        session.start()
        try await eventually { peer.answers.count == 1 }
        XCTAssertEqual(session.state, .connecting, "SDP alone must not mark the session active")
        peer.message(["type": "session.started", "session": ["id": "live_fixture"]])
        XCTAssertEqual(session.state, .active)
    }

    func testNativeSignalingConvenienceInitializerDoesNotStart() {
        let signaling = LiveSignalingMock()
        let session = LiveVoiceSession(signaling: signaling, conversationId: "incoming-conversation")
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.conversationId, "incoming-conversation")
        XCTAssertNil(LiveVoiceSession(signaling: signaling).conversationId)
        XCTAssertTrue(signaling.offers.isEmpty)
        XCTAssertTrue(signaling.closedIds.isEmpty)
    }

    func testCallKitPreparedSessionBecomesActiveWithoutAudioActivation() async throws {
        LiveVoiceCallKitAudio.prepare()
        defer { LiveVoiceCallKitAudio.reset() }
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        let session = model(signaling, peer)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(peer.offerCount, 0, "Preparation must not implicitly start the session")
        XCTAssertFalse(LiveVoiceCallKitAudio.isAudioActive)
        try await connect(session, peer)
        XCTAssertFalse(LiveVoiceCallKitAudio.isAudioActive)
        XCTAssertFalse(LiveVoiceCallKitAudio.isAudioEnabled)
        XCTAssertEqual(session.state, .active, "session.started must not wait on CallKit audio")
        session.end()
        peer.message(["type": "session.closed"])
        try await eventually { session.state == .ended }
    }

    func testAttemptLatchesCallKitLifecyclePolicyWithoutChangingLaterOutgoingAttempts() {
        let signaling = LiveSignalingMock()
        @MainActor func attempt() -> LiveVoiceAttempt {
            LiveVoiceAttempt(signaling: signaling, closeTimeout: 1_000_000,
                             finalizationTimeout: 1_000_000, finalizationPollInterval: 1_000_000)
        }
        let outgoing = attempt()
        XCTAssertFalse(outgoing.usesCallKitAudio)
        LiveVoiceCallKitAudio.prepare()
        defer { LiveVoiceCallKitAudio.reset() }
        let incoming = attempt()
        XCTAssertTrue(incoming.usesCallKitAudio)
        XCTAssertFalse(outgoing.usesCallKitAudio)
        LiveVoiceCallKitAudio.reset()
        XCTAssertTrue(incoming.usesCallKitAudio)
        XCTAssertFalse(attempt().usesCallKitAudio)
    }

    func testDeniedPermissionNeverCreatesPeerOrSignals() async throws {
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        let session = model(signaling, peer, permission: { false })
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(peer.offerCount, 0)
        session.start()
        try await eventually { if case .failed = session.state { return true }; return false }
        XCTAssertEqual(peer.offerCount, 0)
        XCTAssertEqual(signaling.offers, [])
    }

    func testStartRegistersHandlersAndOnlyWaitsForStarted() async throws {
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        let session = model(signaling, peer)
        try await connect(session, peer)
        XCTAssertTrue(peer.handlersInstalledAtOffer)
        XCTAssertEqual(signaling.offers, ["gathered-offer"])
        XCTAssertEqual(signaling.conversations, ["existing-conversation"])
        XCTAssertEqual(peer.answers, ["provider-answer"])
        XCTAssertEqual(session.conversationId, "result-conversation")
        XCTAssertTrue(session.isListening)
        XCTAssertTrue(peer.commands.isEmpty, "HTTP starts GPT-Live; no session.start/response.create")
        session.end()
        peer.message(["type": "session.closed"])
    }

    func testEndBeforePermissionDoesNotActivateMicrophone() async throws {
        let gate = LiveGate<Bool>()
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        let session = model(signaling, peer, permission: { await gate.wait() })
        session.start()
        try await eventually { gate.isWaiting }
        session.end()
        XCTAssertEqual(session.state, .ended)
        gate.resolve(true)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(peer.offerCount, 0)
        XCTAssertFalse(peer.microphoneEnabled)
        XCTAssertTrue(signaling.offers.isEmpty)
    }

    func testImmediateEndDoesNotEvenShowPermissionPrompt() async throws {
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        var permissionRequests = 0
        let session = model(signaling, peer, permission: { permissionRequests += 1; return true })
        session.start()
        session.end()
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(permissionRequests, 0)
        XCTAssertEqual(peer.offerCount, 0)
    }

    func testEndDuringPostClosesLateCreationWithoutApplyingAnswer() async throws {
        let gate = LiveGate<LiveSessionResponse>()
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        signaling.create = { await gate.wait() }
        let session = model(signaling, peer)
        session.start()
        try await eventually { gate.isWaiting }
        session.end()
        XCTAssertTrue(peer.mediaStopped)
        XCTAssertTrue(peer.closed)
        gate.resolve(LiveSignalingMock.response)
        try await eventually { signaling.closedIds.count == 1 }
        XCTAssertEqual(signaling.closedIds, [LiveSignalingMock.response.id])
        XCTAssertTrue(peer.answers.isEmpty)
        XCTAssertFalse(peer.microphoneEnabled)
        XCTAssertEqual(session.state, .ended)
        XCTAssertEqual(session.conversationId, "existing-conversation")
    }

    func testSignalingFailureAndProviderErrorStopMedia() async throws {
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        signaling.create = { throw LiveVoiceError.connectionFailed }
        let session = model(signaling, peer)
        session.start()
        try await eventually { peer.closed }
        guard case .failed = session.state else { return XCTFail("Expected failure") }
        XCTAssertTrue(peer.mediaStopped)

        let nextSignal = LiveSignalingMock(), nextPeer = LivePeerMock()
        let next = model(nextSignal, nextPeer)
        try await connect(next, nextPeer)
        nextPeer.message(["type": "error", "error": ["message": "private provider details"]])
        XCTAssertTrue(nextPeer.closed)
        XCTAssertFalse(nextPeer.microphoneEnabled)
        guard case .failed(let message) = next.state else { return XCTFail("Expected failure") }
        XCTAssertFalse(message.contains("private provider details"))
        try await eventually { nextSignal.closedIds.count == 1 }
    }

    func testMuteIsImmediateAndOldAcknowledgmentsCannotUnmute() async throws {
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        let session = model(signaling, peer)
        try await connect(session, peer)
        session.setMuted(true)
        XCTAssertFalse(peer.microphoneEnabled)
        XCTAssertTrue(session.isMuted)
        XCTAssertNil(session.acknowledgedMuted)
        let mute = try XCTUnwrap(peer.commands.last)
        XCTAssertEqual(mute.0, .mute)
        peer.message(["type": "session.input_audio.unmuted", "client_event_id": mute.1])
        XCTAssertNil(session.acknowledgedMuted, "An acknowledgment must match the requested state as well as its ID")
        XCTAssertFalse(peer.microphoneEnabled)
        peer.message(["type": "session.input_audio.muted", "client_event_id": mute.1])
        XCTAssertEqual(session.acknowledgedMuted, true)
        session.setMuted(false)
        let unmute = try XCTUnwrap(peer.commands.last)
        XCTAssertTrue(peer.microphoneEnabled)
        session.setMuted(true)
        peer.message(["type": "session.input_audio.unmuted", "client_event_id": unmute.1])
        XCTAssertNil(session.acknowledgedMuted)
        XCTAssertFalse(peer.microphoneEnabled)
        XCTAssertTrue(session.isMuted)
        session.end()
        session.setMuted(false)
        XCTAssertFalse(peer.microphoneEnabled)
        peer.message(["type": "session.closed"])
    }

    func testFailedMuteDeliveryFailsClosed() async throws {
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        let session = model(signaling, peer)
        try await connect(session, peer)
        peer.canSend = false
        session.setMuted(true)
        XCTAssertTrue(peer.closed)
        XCTAssertFalse(peer.microphoneEnabled)
        guard case .failed = session.state else { return XCTFail("Expected failure") }
    }

    func testCloseStopsMediaButWaitsForServerHistoryCommit() async throws {
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        let gate = LiveGate<LiveSessionStatus>()
        var polls = 0
        signaling.status = {
            polls += 1
            switch polls {
            case 1: return LiveSignalingMock.status(state: "ready")
            case 2: return LiveSignalingMock.status(state: "closing", finalized: true)
            default: return await gate.wait()
            }
        }
        let session = model(signaling, peer)
        var endedCount = 0
        let observation = session.$state.sink { if $0 == .ended { endedCount += 1 } }
        defer { observation.cancel() }
        try await connect(session, peer)
        peer.onEvent?(.levels(input: 0.4, output: 0.6))
        session.end()
        XCTAssertEqual(session.state, .ending)
        XCTAssertTrue(peer.mediaStopped)
        XCTAssertFalse(peer.closed)
        XCTAssertEqual(peer.commands.last?.0, .close)
        XCTAssertEqual(session.outputLevel, 0)
        peer.message(["type": "session.usage.updated", "usage": ["seconds": 8]])
        peer.message(["type": "session.closed", "usage": ["seconds": 12]])
        XCTAssertEqual(session.state, .ending)
        XCTAssertTrue(peer.closed, "RTC resources must not survive the history wait")
        XCTAssertNil(peer.onEvent)
        try await eventually { gate.isWaiting }
        XCTAssertEqual(session.state, .ending, "Neither usage nor provider close proves the worker committed history")
        XCTAssertEqual(endedCount, 0, "The host must not be notified before the commit")
        XCTAssertEqual(signaling.statusIds, Array(repeating: LiveSignalingMock.response.id, count: 3))
        session.start()
        session.end()
        XCTAssertEqual(signaling.offers.count, 1, "No new session while finalization is pending")
        gate.resolve(LiveSignalingMock.status())
        try await eventually { session.state == .ended }
        XCTAssertEqual(endedCount, 1)
        XCTAssertTrue(session.finalUsageConfirmed)
        XCTAssertFalse(session.finalizationIncomplete)
        XCTAssertEqual(session.usageSeconds, 12)
        XCTAssertTrue(peer.closed)
        XCTAssertTrue(signaling.closedIds.isEmpty)
    }

    func testFinalTimeoutFallsBackToBackendAndClearsHandlers() async throws {
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        signaling.status = { LiveSignalingMock.status(state: "incomplete") }
        let session = model(signaling, peer, closeTimeout: 1_000_000)
        try await connect(session, peer)
        session.end()
        try await eventually { session.state == .ended && signaling.closedIds.count == 1 }
        XCTAssertFalse(session.finalUsageConfirmed)
        XCTAssertTrue(session.finalizationIncomplete)
        XCTAssertTrue(peer.closed)
        XCTAssertNil(peer.onEvent)
        XCTAssertEqual(signaling.statusIds, [LiveSignalingMock.response.id])
        session.end()
        XCTAssertEqual(signaling.closedIds.count, 1)
    }

    func testCloseTimeoutCanStillConfirmServerFinalization() async throws {
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        let session = model(signaling, peer, closeTimeout: 1_000_000)
        try await connect(session, peer)
        session.end()
        try await eventually { session.state == .ended && signaling.closedIds.count == 1 }
        XCTAssertTrue(session.finalUsageConfirmed)
        XCTAssertFalse(session.finalizationIncomplete)
        XCTAssertEqual(signaling.offers.count, 1)
        XCTAssertEqual(signaling.statusIds, [LiveSignalingMock.response.id])
    }

    func testRemoteCloseAndDisconnectDuringCloseBothWaitForHistory() async throws {
        for remoteClose in [true, false] {
            let signaling = LiveSignalingMock(), peer = LivePeerMock()
            let gate = LiveGate<LiveSessionStatus>()
            signaling.status = { await gate.wait() }
            let session = model(signaling, peer)
            try await connect(session, peer)
            let stale = peer.onEvent
            if remoteClose { peer.message(["type": "session.closed"]) }
            else { session.end(); peer.onEvent?(.disconnected) }
            XCTAssertEqual(session.state, .ending)
            XCTAssertTrue(peer.closed)
            XCTAssertTrue(peer.mediaStopped)
            XCTAssertTrue(session.isMuted)
            try await eventually { gate.isWaiting }
            stale?(.disconnected)
            stale?(.message(Data(#"{"type":"session.closed"}"#.utf8)))
            XCTAssertEqual(session.state, .ending)
            XCTAssertEqual(signaling.statusIds.count, 1)
            gate.resolve(LiveSignalingMock.status())
            try await eventually { session.state == .ended }
            XCTAssertFalse(session.finalizationIncomplete)
        }
    }

    func testNonterminalServerStatusTimesOutWithoutRetryingCreation() async throws {
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        signaling.status = { LiveSignalingMock.status(state: "closing", finalized: true) }
        let session = model(signaling, peer, finalizationTimeout: 50_000_000)
        try await connect(session, peer)
        session.end()
        peer.message(["type": "session.closed"])
        try await eventually { session.state == .ended }
        XCTAssertTrue(session.finalUsageConfirmed)
        XCTAssertTrue(session.finalizationIncomplete, "Final usage must not hide missing history confirmation")
        XCTAssertGreaterThan(signaling.statusIds.count, 1)
        let requests = signaling.statusIds.count
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(signaling.statusIds.count, requests)
        XCTAssertEqual(signaling.offers.count, 1)
        XCTAssertTrue(signaling.closedIds.isEmpty)
    }

    func testHungStatusRequestIsBoundedAndLateSuccessCannotClearWarning() async throws {
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        let gate = LiveGate<LiveSessionStatus>()
        var cancelled = false
        signaling.status = {
            let result = await gate.wait() // Intentionally ignores cancellation until resolved.
            cancelled = Task.isCancelled
            return result
        }
        let session = model(signaling, peer, finalizationTimeout: 50_000_000)
        var endedCount = 0
        let observation = session.$state.sink { if $0 == .ended { endedCount += 1 } }
        defer { observation.cancel() }
        try await connect(session, peer)
        session.end()
        peer.message(["type": "session.closed"])
        try await eventually { gate.isWaiting }
        XCTAssertTrue(peer.closed)
        try await eventually { session.state == .ended }
        XCTAssertTrue(session.finalizationIncomplete)
        XCTAssertEqual(endedCount, 1)
        gate.resolve(LiveSignalingMock.status())
        try await eventually { cancelled }
        XCTAssertTrue(session.finalizationIncomplete)
        XCTAssertEqual(endedCount, 1)
        XCTAssertEqual(signaling.statusIds.count, 1)
        XCTAssertEqual(signaling.offers.count, 1)
    }

    func testSynchronousCloseAcknowledgmentDoesNotReplaceHistoryDeadline() async throws {
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        let gate = LiveGate<LiveSessionStatus>()
        signaling.status = { await gate.wait() }
        peer.onSend = { [weak peer] command in
            if command == .close { peer?.message(["type": "session.closed"]) }
        }
        let session = model(signaling, peer, closeTimeout: 1_000_000, finalizationTimeout: 50_000_000)
        try await connect(session, peer)
        session.end()
        XCTAssertTrue(peer.closed)
        try await eventually { gate.isWaiting }
        try await eventually { session.state == .ended }
        XCTAssertTrue(session.finalizationIncomplete)
        gate.resolve(LiveSignalingMock.status())
    }

    func testServerTerminalErrorsDoNotClaimCompleteHistory() async throws {
        for state in ["incomplete", "failed", "closed"] {
            let signaling = LiveSignalingMock(), peer = LivePeerMock()
            signaling.status = { LiveSignalingMock.status(state: state, finalized: false) }
            let session = model(signaling, peer)
            try await connect(session, peer)
            session.end()
            peer.message(["type": "session.closed"])
            try await eventually { session.state == .ended }
            XCTAssertTrue(session.finalizationIncomplete, state)
            XCTAssertTrue(session.finalUsageConfirmed, "Keep the provider usage acknowledgment separate")
            XCTAssertEqual(signaling.statusIds.count, 1)
            XCTAssertTrue(peer.closed)
            XCTAssertEqual(signaling.offers.count, 1)
        }
    }

    func testStatusErrorsAndAuthenticationCancellationSurfaceIncompleteHistory() async throws {
        let errors: [Error] = [APIError.unauthorized, APIError.httpError(statusCode: 404),
                               APIError.httpError(statusCode: 503), APIError.invalidResponse, CancellationError()]
        for error in errors {
            let signaling = LiveSignalingMock(), peer = LivePeerMock()
            signaling.status = { throw error }
            let session = model(signaling, peer)
            try await connect(session, peer)
            session.end()
            peer.message(["type": "session.closed"])
            try await eventually { session.state == .ended }
            XCTAssertTrue(session.finalizationIncomplete)
            XCTAssertEqual(signaling.statusIds.count, 1)
            XCTAssertEqual(signaling.offers.count, 1)
            XCTAssertTrue(peer.closed)
        }
    }

    func testLegacySignalingAdapterDoesNotPretendHistoryWasFinalized() async throws {
        let peer = LivePeerMock()
        let session = model(LegacyLiveSignalingMock(), peer)
        try await connect(session, peer)
        session.end()
        peer.message(["type": "session.closed"])
        try await eventually { session.state == .ended }
        XCTAssertTrue(session.finalizationIncomplete)
    }

    func testDeinitCancelsPendingHistoryRequestWithoutRetainingModel() async throws {
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        let gate = LiveGate<LiveSessionStatus>()
        var cancelled = false
        signaling.status = {
            let status = await gate.wait()
            cancelled = Task.isCancelled
            return status
        }
        var session: LiveVoiceSession? = model(signaling, peer)
        try await connect(session!, peer)
        session?.end()
        peer.message(["type": "session.closed"])
        try await eventually { gate.isWaiting }
        weak var weakSession = session
        session = nil
        XCTAssertNil(weakSession)
        XCTAssertTrue(peer.closed)
        gate.resolve(LiveSignalingMock.status())
        try await eventually { cancelled }
        XCTAssertEqual(signaling.statusIds.count, 1)
        XCTAssertTrue(signaling.closedIds.isEmpty)
    }

    func testMissingStartedTimesOutWithoutAutoReconnect() async throws {
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        let session = model(signaling, peer, connectionTimeout: 20_000_000)
        session.start()
        try await eventually { peer.closed }
        guard case .failed = session.state else { return XCTFail("Expected timeout") }
        XCTAssertEqual(signaling.offers.count, 1)
        XCTAssertFalse(peer.microphoneEnabled)
    }

    func testStaleEventsAndLatePostCannotAffectNewAttempt() async throws {
        let gate = LiveGate<LiveSessionResponse>()
        let signaling = LiveSignalingMock(), first = LivePeerMock(), second = LivePeerMock()
        signaling.create = { await gate.wait() }
        var nextPeer = first
        let session = LiveVoiceSession(signaling: signaling, permission: { true }, makeTransport: { nextPeer })
        session.start()
        try await eventually { gate.isWaiting }
        let stale = first.onEvent
        session.end()
        nextPeer = second
        signaling.create = nil
        session.start()
        try await eventually { second.answers.count == 1 }
        second.message(["type": "session.started"])
        let late = LiveSessionResponse(id: "CFBB1505-77B7-411F-A638-4B29315B26DC", conversationId: "old-conversation",
                                       session: .init(id: "live_old"), transport: .init(sdp: "old-answer"))
        gate.resolve(late)
        try await eventually { signaling.closedIds.count == 1 }
        XCTAssertEqual(signaling.closedIds, [late.id])
        stale?(.disconnected)
        stale?(.levels(input: 1, output: 1))
        stale?(.message(Data(#"{"type":"session.closed"}"#.utf8)))
        XCTAssertEqual(session.state, .active)
        XCTAssertTrue(second.microphoneEnabled)
        XCTAssertEqual(session.outputLevel, 0)
        session.end()
        second.message(["type": "session.closed"])
    }

    func testOverlappingTranscriptsPreserveRawDeltasAndNeverDriveSpeech() async throws {
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        let session = model(signaling, peer)
        try await connect(session, peer)
        peer.message(["type": "session.input_transcript.delta", "delta": " I I", "start_ms": 100, "end_ms": 300])
        peer.message(["type": "session.output_transcript.delta", "delta": "Hello ", "start_ms": 150, "end_ms": 250])
        peer.message(["type": "session.input_transcript.delta", "delta": " agree", "start_ms": 300, "end_ms": 500])
        peer.message(["type": "session.output_transcript.delta", "delta": " there", "start_ms": 250, "end_ms": 450])
        peer.message(["type": "session.input_transcript.delta", "delta": " late", "start_ms": 50, "end_ms": 90])
        XCTAssertEqual(session.inputTranscript, " I I agree late")
        XCTAssertEqual(session.outputTranscript, "Hello  there")
        XCTAssertEqual(session.captions.map(\.startMilliseconds), [100, 150, 300, 250, 50])
        XCTAssertEqual(Set(session.captions.map(\.id)).count, 5)
        XCTAssertFalse(session.isSpeaking)
        XCTAssertEqual(session.outputLevel, 0)
        peer.onEvent?(.levels(input: 0.5, output: 0.4))
        XCTAssertTrue(session.isSpeaking)
        XCTAssertTrue(session.isListening, "Full duplex: listening and speaking coexist")
        peer.onEvent?(.levels(input: .nan, output: .infinity))
        XCTAssertFalse(session.isSpeaking)
        XCTAssertEqual(session.inputLevel, 0)
        session.end()
        peer.message(["type": "session.closed"])
    }

    func testUnknownToolAndAudioEventsNeverSendCommands() async throws {
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        let session = model(signaling, peer)
        try await connect(session, peer)
        peer.message(["type": "response.function_call_arguments.done", "name": "delete_all"])
        peer.message(["type": "session.output_audio.delta", "delta": "ignored"])
        peer.message(["type": "session.update"])
        XCTAssertTrue(peer.commands.isEmpty)
        XCTAssertTrue(session.captions.isEmpty)
        XCTAssertEqual(signaling.offers.count, 1)
        session.end()
        peer.message(["type": "session.closed"])
    }

    func testDisconnectStopsAudioAndLateStartedNeverResumes() async throws {
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        let session = model(signaling, peer)
        try await connect(session, peer)
        let stale = peer.onEvent
        peer.onEvent?(.disconnected)
        XCTAssertTrue(peer.closed)
        XCTAssertFalse(peer.microphoneEnabled)
        stale?(.message(Data(#"{"type":"session.started"}"#.utf8)))
        try await Task.sleep(nanoseconds: 10_000_000)
        guard case .failed = session.state else { return XCTFail("Expected disconnected state") }
        XCTAssertEqual(signaling.offers.count, 1)
        XCTAssertFalse(peer.microphoneEnabled)
    }

    func testDeinitStopsActiveAudioAndClosesBackend() async throws {
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        var session: LiveVoiceSession? = model(signaling, peer)
        try await connect(session!, peer)
        weak var weakSession = session
        session = nil
        XCTAssertNil(weakSession)
        XCTAssertFalse(peer.microphoneEnabled)
        XCTAssertTrue(peer.closed)
        try await eventually { signaling.closedIds.count == 1 }
    }

    func testDeinitDuringPermissionDoesNotRetainModelOrOpenMic() async throws {
        let gate = LiveGate<Bool>()
        let signaling = LiveSignalingMock(), peer = LivePeerMock()
        var session: LiveVoiceSession? = model(signaling, peer, permission: { await gate.wait() })
        session?.start()
        try await eventually { gate.isWaiting }
        weak var weakSession = session
        session = nil
        XCTAssertNil(weakSession)
        gate.resolve(true)
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(peer.offerCount, 0)
    }

    func testLiveOwnershipSuppressesQueuedTTSWithoutDisablingFutureTTS() async throws {
        let previousOwner = AudioSessionCoordinator.owner
        defer { AudioSessionCoordinator.owner = previousOwner }
        let provider = LiveTTSSpy()
        let voice = VoiceController(provider: provider, minChars: 1)
        voice.setEnabled(true)
        AudioSessionCoordinator.owner = .liveVoice
        voice.pushDelta("Must not play.")
        voice.finishTurn()
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(provider.speakCount, 0)
        XCTAssertFalse(voice.isSpeaking)
        AudioSessionCoordinator.owner = .unclaimed
        voice.reset()
        voice.pushDelta("May play now.")
        voice.finishTurn()
        try await eventually { provider.speakCount == 1 }
        voice.stop()
    }
}

private final class LiveTTSSpy: TTSProvider {
    let name = "live-tts-test-spy"
    private let lock = NSLock()
    private var count = 0
    var speakCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    private func recordSpeak() { lock.lock(); count += 1; lock.unlock() }
    func speak(_ text: String, options: TTSSpeakOptions) async throws { recordSpeak() }
    func cancel() {}
    func listVoices() async throws -> [VoiceDescriptor] { [] }
}

@MainActor
private final class LiveGate<Value> {
    private var continuation: CheckedContinuation<Value, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async -> Value { await withCheckedContinuation { continuation = $0 } }
    func resolve(_ value: Value) { continuation?.resume(returning: value); continuation = nil }
}

@MainActor
private final class LiveSignalingMock: LiveVoiceSignaling {
    static let response = LiveSessionResponse(id: "7E2B1866-BE77-42DA-AC2B-4D159CBAF8FC",
        conversationId: "result-conversation", session: .init(id: "live_fixture"), transport: .init(sdp: "provider-answer"))
    var create: (() async throws -> LiveSessionResponse)?
    var status: (() async throws -> LiveSessionStatus)?
    static func status(state: String = "closed", finalized: Bool? = nil) -> LiveSessionStatus {
        LiveSessionStatus(id: response.id, state: state, usageFinalized: finalized ?? (state == "closed"))
    }
    var offers: [String] = []
    var conversations: [String?] = []
    var closedIds: [String] = []
    var statusIds: [String] = []
    func createLiveSession(sdp: String, conversationId: String?) async throws -> LiveSessionResponse {
        offers.append(sdp)
        conversations.append(conversationId)
        if let create { return try await create() }
        return Self.response
    }
    func closeLiveSession(id: String) async throws { closedIds.append(id) }
    func liveSessionStatus(id: String) async throws -> LiveSessionStatus {
        statusIds.append(id)
        if let status { return try await status() }
        return Self.status()
    }
}

@MainActor
private struct LegacyLiveSignalingMock: LiveVoiceSignaling {
    func createLiveSession(sdp: String, conversationId: String?) async throws -> LiveSessionResponse {
        LiveSignalingMock.response
    }
    func closeLiveSession(id: String) async throws {}
}

@MainActor
private final class LivePeerMock: LiveVoiceTransport {
    var onEvent: ((LiveVoiceTransportEvent) -> Void)?
    var handlersInstalledAtOffer = false
    var offerCount = 0
    var answers: [String] = []
    var microphoneEnabled = false
    var mediaStopped = false
    var closed = false
    var canSend = true
    var onSend: ((LiveVoiceCommand) -> Void)?
    var commands: [(LiveVoiceCommand, String)] = []
    func makeOffer() async throws -> String {
        handlersInstalledAtOffer = onEvent != nil
        offerCount += 1
        microphoneEnabled = true
        return "gathered-offer"
    }
    func acceptAnswer(_ sdp: String) async throws { answers.append(sdp) }
    func setMicrophoneEnabled(_ enabled: Bool) { if !mediaStopped { microphoneEnabled = enabled } }
    func send(_ command: LiveVoiceCommand, eventId: String) -> Bool {
        commands.append((command, eventId))
        if canSend { onSend?(command) }
        return canSend
    }
    func stopMedia() { mediaStopped = true; microphoneEnabled = false }
    func close() { closed = true; stopMedia(); onEvent = nil }
    func message(_ event: [String: Any]) {
        onEvent?(.message(try! JSONSerialization.data(withJSONObject: event)))
    }
}