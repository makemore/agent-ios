import XCTest
@testable import AgentClient

@MainActor
final class RunRecoveryTests: XCTestCase {
    private var config: ChatWidgetConfig!
    private var storage: InMemoryStorage!
    private var api: APIClient!

    override func setUp() {
        super.setUp()
        APIClient.sessionConfigurator = { $0.protocolClasses = [MockURLProtocol.self] }
        SSEClient.sessionConfigurator = { $0.protocolClasses = [MockURLProtocol.self] }
        config = ChatWidgetConfig(backendUrl: "https://example.test", agentKey: "recovery-test")
        config.authStrategy = .token
        config.authToken = "synthetic-test-owner"
        storage = InMemoryStorage()
        api = APIClient(config: config, storage: storage)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        APIClient.sessionConfigurator = nil
        SSEClient.sessionConfigurator = nil
        super.tearDown()
    }

    private func vm() -> ChatViewModel { ChatViewModel(config: config, apiClient: api, storage: storage) }

    private func pending(runId: String? = nil, age: TimeInterval = 0) -> PendingRun {
        PendingRun(scope: api.recoveryScope(agentKey: config.agentKey)!, ownerScope: api.recoveryOwnerScope,
            idempotencyKey: "test-send-key", body: Data(#"{"idempotency_key":"test-send-key","private_only":true,"messages":[{"role":"user","content":"question"}]}"#.utf8),
            createdAt: Date().addingTimeInterval(-age), runId: runId, conversationId: "conversation",
            transcript: [PendingMessage(from: Message(id: "user", role: .user, content: "question"))],
            messagesOffset: 0, hasMore: false)
    }

    private var finalJSON: Data {
        Data(#"{"id":"run","conversation_id":"conversation","status":"succeeded","output":{"final_messages":[{"id":"final","seq":2,"role":"assistant","content":"complete answer"}]},"error":null}"#.utf8)
    }

    func testColdLaunchRecoversByKeyWithoutPostOrSideEffects() async throws {
        let record = pending()
        try PendingRunStore(storage: storage).save(record)
        let response = finalJSON
        var callbacks = 0
        config.onEvent = { _, _ in callbacks += 1 }
        MockURLProtocol.register { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url!.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), "api/agent-runtime/runs/by-idempotency-key")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "idempotency_key", value: record.idempotencyKey)])
            return .json(status: 200, body: response)
        }
        let model = vm()
        await model.restoreConversationIfNeeded()
        XCTAssertEqual(model.messages.map(\.content), ["question", "complete answer"])
        XCTAssertEqual(model.runState, .succeeded)
        XCTAssertEqual(callbacks, 0)
        XCTAssertNil(PendingRunStore(storage: storage).load(scope: record.scope))
        XCTAssertEqual(MockURLProtocol.recorded.count, 1)
    }

    func testUnknownKeyRepostsExactOriginalBodyOnly() async throws {
        let record = pending()
        try PendingRunStore(storage: storage).save(record)
        let response = finalJSON
        MockURLProtocol.register { request in
            request.httpMethod == "GET" ? .json(status: 404, body: Data()) : .json(status: 201, body: response)
        }
        let model = vm()
        await model.reconcilePendingRun()
        let posts = MockURLProtocol.recorded.filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.body, record.body)
        XCTAssertEqual(model.runState, .succeeded)
    }

    func testExpiredKeyAndMissingAcknowledgedRunNeverPost() async throws {
        for (status, runId) in [(410, nil as String?), (404, "run")] {
            MockURLProtocol.reset()
            let record = pending(runId: runId)
            try PendingRunStore(storage: storage).save(record)
            MockURLProtocol.register { _ in .json(status: status, body: Data()) }
            let model = vm()
            await model.reconcilePendingRun()
            XCTAssertFalse(MockURLProtocol.recorded.contains { $0.method == "POST" })
            XCTAssertNil(PendingRunStore(storage: storage).load(scope: record.scope))
            XCTAssertEqual(model.runState, .failed)
        }
    }

    func testOldUnknownKeyIsNotRecreated() async throws {
        let record = pending(age: 86401)
        try PendingRunStore(storage: storage).save(record)
        MockURLProtocol.register { _ in .json(status: 404, body: Data()) }
        let model = vm()
        await model.reconcilePendingRun()
        XCTAssertEqual(MockURLProtocol.recorded.count, 1)
        XCTAssertEqual(model.runState, .failed)
    }

    func testWaitingSurvivesBackgroundAndColdLaunch() async throws {
        let record = pending(runId: "run")
        try PendingRunStore(storage: storage).save(record)
        MockURLProtocol.register { _ in .json(status: 200, body: Data(#"{"id":"run","status":"waiting"}"#.utf8)) }
        let model = vm()
        await model.reconcilePendingRun()
        model.pauseForBackground()
        XCTAssertTrue(PendingRunStore(storage: storage).load(scope: record.scope)?.waiting == true)
        XCTAssertEqual(vm().runState, .waiting)
        XCTAssertFalse(MockURLProtocol.recorded.contains { $0.method == "POST" })
        model.clearAllLocalData()
        XCTAssertNil(PendingRunStore(storage: storage).load(scope: record.scope))
    }

    func testLostAcknowledgementUsesLookupNotAnotherGeneration() async {
        let response = finalJSON
        MockURLProtocol.register { request in
            if request.httpMethod == "POST" { return .error(URLError(.networkConnectionLost)) }
            return .json(status: 200, body: response)
        }
        let model = vm()
        await model.sendMessage("question")
        XCTAssertEqual(MockURLProtocol.recorded.filter { $0.method == "POST" }.count, 1)
        XCTAssertEqual(model.messages.last?.content, "complete answer")
        XCTAssertEqual(model.runState, .succeeded)
    }

    func testSecurePendingPayloadExistsBeforePost() async {
        let store = PendingRunStore(storage: storage)
        let scope = api.recoveryScope(agentKey: config.agentKey)!
        let response = finalJSON
        MockURLProtocol.register { request in
            guard request.httpMethod == "POST" else { return nil }
            let saved = store.load(scope: scope)
            XCTAssertNotNil(saved)
            XCTAssertEqual(saved?.body, MockURLProtocol.recorded.last?.body)
            XCTAssertEqual(saved?.transcript.first?.message.content, "question")
            return .json(status: 201, body: response)
        }
        let model = vm()
        await model.sendMessage("question")
        XCTAssertEqual(model.messages.last?.content, "complete answer")
        XCTAssertEqual(MockURLProtocol.recorded.count, 1, "An authoritative create response needs no SSE round trip")
    }

    func testFailedDurableWriteDoesNotPost() async {
        final class UnavailableStorage: StorageService {
            func get(_ key: String) -> String? { nil }
            func set(_ key: String, value: String?) {}
        }
        let model = ChatViewModel(config: config, apiClient: api, storage: storage, pendingStorage: UnavailableStorage())
        await model.sendMessage("question")
        XCTAssertTrue(MockURLProtocol.recorded.isEmpty)
        XCTAssertEqual(model.runState, .failed)
    }

    func testEOFRecoversMissedFinalWithoutAnotherPost() async throws {
        let partial = try frame("assistant.delta", seq: 0, payload: ["delta": "incomplete"])
        let final = finalJSON
        MockURLProtocol.register { request in
            if request.httpMethod == "POST" { return .json(status: 201, body: Data(#"{"id":"run","conversation_id":"conversation","status":"running"}"#.utf8)) }
            if request.url!.path.contains("stream") { return .sse(chunks: [partial]) }
            return .json(status: 200, body: final)
        }
        let model = vm()
        await model.sendMessage("question")
        try await waitUntil { model.runState == .succeeded }
        XCTAssertEqual(model.messages.map(\.content), ["question", "complete answer"])
        XCTAssertEqual(MockURLProtocol.recorded.filter { $0.method == "POST" }.count, 1)
        XCTAssertNil(PendingRunStore(storage: storage).load(scope: api.recoveryScope(agentKey: config.agentKey)!))
    }

    func testFinalRepairsLargePartialAndDuplicateSequenceIsIgnoredImmediately() async throws {
        let final = String(repeating: "authoritative 👩🏽‍💻 ", count: 1000)
        let delta = try frame("assistant.delta", seq: 0, payload: ["delta": "wrong partial"])
        let answer = try frame("assistant.message", seq: 1, payload: ["content": final])
        let corrected = try frame("assistant.message", seq: 2, payload: ["content": final + "corrected"])
        let terminal = try frame("run.succeeded", seq: 3)
        var events = 0
        config.onEvent = { _, _ in events += 1 }
        installStream([delta + delta + answer + answer + corrected + terminal])
        let model = vm()
        await model.sendMessage("question")
        // No sleep/drain grace: receipt of the final is enough to render it.
        XCTAssertEqual(model.messages.map(\.content), ["question", final + "corrected"])
        XCTAssertEqual(events, 4)
        XCTAssertEqual(model.runState, .succeeded)
    }

    func testWaitingActionDetailsSurviveColdLaunchWithoutReplayActions() async throws {
        let action = try frame("run.suspended", seq: 1, payload: ["required_action": [
            "action_id": "connect", "action_type": "oauth", "message": "Connect to continue",
            "action_url": "https://example.test/connect", "action_label": "Connect"
        ]])
        installStream([action])
        let first = vm()
        await first.sendMessage("question")
        first.pauseForBackground()
        var callbacks = 0
        config.onEvent = { _, _ in callbacks += 1 }
        let restored = vm()
        XCTAssertEqual(restored.runState, .waiting)
        XCTAssertEqual(restored.messages.last?.metadata?.actionId, "connect")
        XCTAssertEqual(restored.messages.last?.metadata?.actionURL, "https://example.test/connect")
        MockURLProtocol.register { _ in .json(status: 200, body: Data(#"{"id":"run","status":"waiting"}"#.utf8)) }
        await restored.reconcilePendingRun()
        XCTAssertEqual(restored.messages.filter { $0.type == .requiredAction }.count, 1)
        XCTAssertEqual(callbacks, 0)
    }

    func testLogoutDuringEventDropsRestOfPacketAndStopsRecovery() async throws {
        let delta = try frame("assistant.delta", seq: 0, payload: ["delta": "discarded"])
        let final = try frame("assistant.message", seq: 1, payload: ["content": "must not reappear"])
        let terminal = try frame("run.succeeded", seq: 2)
        var model: ChatViewModel?
        config.onEvent = { _, _ in model?.clearAllLocalData() }
        installStream([delta + final + terminal])
        model = vm()
        let scope = api.recoveryScope(agentKey: config.agentKey)!
        await model?.sendMessage("question")
        await model?.reconcilePendingRun()
        XCTAssertTrue(model?.messages.isEmpty == true)
        XCTAssertNil(PendingRunStore(storage: storage).load(scope: scope))
        XCTAssertFalse(MockURLProtocol.recorded.contains { $0.path.contains("by-idempotency-key") })
        model = nil
    }

    func testNewAccountCannotRestoreOldPendingRun() throws {
        let record = pending()
        try PendingRunStore(storage: storage).save(record)
        api.setAuthToken("different-synthetic-owner")
        XCTAssertTrue(vm().messages.isEmpty)
        XCTAssertNil(PendingRunStore(storage: storage).load(scope: record.scope))
    }

    func testAuthChangeInsideEventCallbackReleasesSendAndDropsPacket() async throws {
        let client = api!
        let scope = client.recoveryScope(agentKey: config.agentKey)!
        config.onEvent = { type, _ in
            if type == "assistant.message" { client.setAuthToken("replacement-synthetic-owner") }
        }
        let delta = try frame("assistant.delta", seq: 0, payload: ["delta": "stale buffered text"])
        let answer = try frame("assistant.message", seq: 1, payload: ["content": "stale answer"])
        let terminal = try frame("run.succeeded", seq: 2)
        installStream([delta + answer + terminal])
        let model = vm()
        let finished = expectation(description: "obsolete send released")
        let send = Task { await model.sendMessage("question"); finished.fulfill() }
        defer { model.invalidateForReplacement(); send.cancel() }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(model.messages.map(\.content), ["question"])
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(PendingRunStore(storage: storage).load(scope: scope))
        XCTAssertEqual(MockURLProtocol.recorded.count, 2, "No recovery request under the replacement account")
    }

    func testReplayedSuspensionDoesNotTruncateResumedRunOrSpeak() async throws {
        try PendingRunStore(storage: storage).save(pending(runId: "run"))
        let suspended = try frame("run.suspended", seq: 0, payload: ["message": "Old action"])
        let answer = try frame("assistant.message", seq: 1, payload: ["content": "resumed answer"])
        let terminal = try frame("run.succeeded", seq: 2)
        var callbacks = 0
        config.onEvent = { _, _ in callbacks += 1 }
        MockURLProtocol.register { request in
            if request.url!.path.contains("stream") { return .sse(chunks: [suspended + answer + terminal]) }
            return .json(status: 200, body: Data(#"{"id":"run","status":"running"}"#.utf8))
        }
        let model = vm()
        let voice = VoiceController(provider: SilentRecoveryTTS())
        voice.setEnabled(true)
        voice.autoSpeakReplies = true
        model.voiceController = voice
        await model.reconcilePendingRun()
        XCTAssertEqual(model.runState, .succeeded)
        XCTAssertEqual(model.messages.last?.content, "resumed answer")
        XCTAssertEqual(callbacks, 0)
        XCTAssertFalse(MockURLProtocol.recorded.contains { $0.method == "POST" })
        await Task.yield()
    }

    func testAuthChangeBeforeStreamDataOrEOFDropsCallbacksAndReleasesSend() async throws {
        let answer = try frame("assistant.message", seq: 0, payload: ["content": "stale answer"])
        for chunks in [[], [answer]] as [[Data]] {
            MockURLProtocol.reset()
            let client = APIClient(config: config, storage: storage)
            MockURLProtocol.register { request in
                if request.httpMethod == "POST" {
                    return .json(status: 201, body: Data(#"{"id":"run","status":"running"}"#.utf8))
                }
                client.clearSession()
                return .sse(chunks: chunks)
            }
            let model = ChatViewModel(config: config, apiClient: client, storage: storage)
            let finished = expectation(description: "obsolete stream released")
            let send = Task { await model.sendMessage("question"); finished.fulfill() }
            await fulfillment(of: [finished], timeout: 2)
            model.invalidateForReplacement()
            send.cancel()
            XCTAssertEqual(model.messages.map(\.content), ["question"])
            XCTAssertFalse(model.isLoading)
            XCTAssertEqual(MockURLProtocol.recorded.count, 2)
        }
    }

    func testBackgroundRetainsKeyAndForegroundRecoversSameRun() async throws {
        let delta = try frame("assistant.delta", seq: 0, payload: ["delta": "paused"])
        installStream([delta])
        var model: ChatViewModel?
        config.onEvent = { _, _ in model?.pauseForBackground() }
        model = vm()
        await model?.sendMessage("question")
        let scope = api.recoveryScope(agentKey: config.agentKey)!
        XCTAssertNotNil(PendingRunStore(storage: storage).load(scope: scope))
        let response = finalJSON
        MockURLProtocol.register { _ in .json(status: 200, body: response) }
        await model?.reconcilePendingRun()
        XCTAssertEqual(model?.messages.last?.content, "complete answer")
        XCTAssertEqual(model?.runState, .succeeded)
        XCTAssertEqual(MockURLProtocol.recorded.filter { $0.method == "POST" }.count, 1)
        model = nil
    }

    func testAnonymousAcknowledgementCannotResurrectLoggedOutSession() async {
        var anonymousConfig = config!
        anonymousConfig.authStrategy = .anonymous
        anonymousConfig.authToken = nil
        let anonymous = APIClient(config: anonymousConfig, storage: storage)
        MockURLProtocol.register { _ in
            anonymous.clearSession()
            return .json(status: 200, body: Data(#"{"token":"synthetic-anonymous-owner"}"#.utf8))
        }
        do {
            _ = try await anonymous.getOrCreateSession()
            XCTFail("A response received after logout must be rejected")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(storage.get(config.anonymousTokenKey))
        XCTAssertNil(anonymous.recoveryOwnerScope)
    }

    private func frame(_ type: String, seq: Int, payload: [String: Any] = [:]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: ["run_id": "run", "seq": seq, "payload": payload])
        return Data("event: \(type)\ndata: \(String(decoding: data, as: UTF8.self))\n\n".utf8)
    }

    private func installStream(_ chunks: [Data]) {
        MockURLProtocol.register { request in
            if request.httpMethod == "POST" { return .json(status: 201, body: Data(#"{"id":"run","conversation_id":"conversation","status":"running"}"#.utf8)) }
            if request.url!.path.contains("stream") { return .sse(chunks: chunks) }
            return nil
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "Recovery should settle within the test deadline")
    }
}

private final class SilentRecoveryTTS: TTSProvider {
    let name = "silent-recovery-test"
    func speak(_ text: String, options: TTSSpeakOptions) async throws { XCTFail("Reconstruction must never request TTS") }
    func cancel() {}
    func listVoices() async throws -> [VoiceDescriptor] { [] }
}