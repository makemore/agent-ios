import XCTest
@testable import AgentClient

@MainActor
final class RunReconciliationTests: XCTestCase {
    private var config: ChatWidgetConfig!
    private var storage: InMemoryStorage!
    private var api: APIClient!
    private var models: [ChatViewModel] = []
    private let runId = "run-reconcile-001"
    private let conversationId = "conversation-reconcile-001"

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        APIClient.sessionConfigurator = { $0.protocolClasses = [MockURLProtocol.self] }
        SSEClient.sessionConfigurator = { $0.protocolClasses = [MockURLProtocol.self] }
        // Ephemeral SQLite history is agent-scoped, even with in-memory pending storage.
        config = ChatWidgetConfig(backendUrl: "https://example.test", agentKey: "reconcile-test-\(UUID().uuidString)")
        config.authStrategy = .token
        config.authToken = "synthetic-reconciliation-owner"
        storage = InMemoryStorage()
        api = APIClient(config: config, storage: storage)
    }

    override func tearDown() {
        models.forEach { $0.invalidateForReplacement() }
        // Only this test's unique synthetic agent can have written these rows.
        if config.ephemeral { models.first?.purgeLocalHistory() }
        models.removeAll()
        MockURLProtocol.reset()
        APIClient.sessionConfigurator = nil
        SSEClient.sessionConfigurator = nil
        api = nil
        storage = nil
        config = nil
        super.tearDown()
    }

    func testPendingRunSurvivesNetworkDisconnect() async throws {
        let scope = try XCTUnwrap(api.recoveryScope(agentKey: config.agentKey))
        let store = PendingRunStore(storage: storage)
        // Automatic recovery settles at waiting, retaining the send without backoff/retries.
        installResponses(create: runDetail(status: "running"),
                         detail: .json(status: 200, body: runDetail(status: "waiting")),
                         stream: .error(URLError(.networkConnectionLost)))
        let vm = makeViewModel()
        await sendAndWait(vm)
        try await waitUntil { vm.runState == .waiting && !vm.isLoading }

        let saved = try XCTUnwrap(store.load(scope: scope))
        XCTAssertEqual(saved.runId, runId)
        XCTAssertEqual(saved.conversationId, conversationId)
        XCTAssertEqual(saved.ownerScope, api.recoveryOwnerScope)
        XCTAssertEqual(saved.transcript.map { $0.message.content }, ["Please finish this"])
        XCTAssertTrue(saved.waiting)
        XCTAssertFalse(saved.idempotencyKey.isEmpty)
        let posts = MockURLProtocol.recorded.filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.body, saved.body)
        XCTAssertEqual(MockURLProtocol.recorded.count, 3)
        XCTAssertNil(vm.error)

        vm.invalidateForReplacement()
        let restored = makeViewModel()
        XCTAssertEqual(restored.runState, .waiting)
        XCTAssertEqual(restored.messages.first?.content, "Please finish this")
        XCTAssertEqual(store.load(scope: scope)?.idempotencyKey, saved.idempotencyKey)
    }

    func testRetainedRunRestoresFinalMessagesAfterRelaunch() async throws {
        var record = try pending()
        record.transcript.insert(contentsOf: [
            PendingMessage(from: Message(id: "earlier-user", role: .user, content: "Earlier question")),
            PendingMessage(from: Message(id: "earlier-answer", role: .assistant, content: "Earlier answer")),
        ], at: 0)
        record.messagesOffset = 3
        record.hasMore = true
        try PendingRunStore(storage: storage).save(record)
        storage.set(config.conversationIdKey, value: conversationId)
        installResponses(detail: .json(status: 200, body: runDetail(status: "succeeded")))

        let vm = makeViewModel()
        await vm.restoreConversationIfNeeded()

        XCTAssertEqual(vm.messages.map(\.content), [
            "Earlier question", "Earlier answer", "Please finish this", "Finished on the server",
        ])
        XCTAssertEqual(vm.conversationId, conversationId)
        XCTAssertTrue(vm.hasMoreMessages)
        XCTAssertEqual(vm.runState, .succeeded)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.error)
        XCTAssertNil(PendingRunStore(storage: storage).load(scope: record.scope))
        XCTAssertEqual(MockURLProtocol.recorded.count, 1, "The retained run snapshot needs no conversation reload")
        XCTAssertEqual(MockURLProtocol.recorded.first?.method, "GET")
    }

    func testEphemeralRunReplaysEventsAndPersistsRecoveredMessages() async throws {
        config.ephemeral = true
        let record = try pending()
        try PendingRunStore(storage: storage).save(record)
        let partial = frame("assistant.delta", seq: 0, payload: ["delta": "Incomplete answer"])
        let final = frame("assistant.message", seq: 1, payload: ["content": "Finished on the server"])
        let terminal = frame("run.succeeded", seq: 2)
        var callbacks = 0
        config.onEvent = { _, _ in callbacks += 1 }
        installResponses(detail: .json(status: 200, body: runDetail(status: "running")),
                         stream: .sse(chunks: [partial + final + terminal]))

        let vm = makeViewModel()
        await vm.restoreConversationIfNeeded()

        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.messages.map(\.content), ["Please finish this", "Finished on the server"])
        XCTAssertEqual(vm.runState, .succeeded)
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(callbacks, 0, "Recovery must not replay host side effects")
        XCTAssertNil(PendingRunStore(storage: storage).load(scope: record.scope))
        XCTAssertEqual(vm.localConversations.map(\.id), [conversationId])

        vm.invalidateForReplacement()
        let restored = makeViewModel()
        XCTAssertTrue(restored.loadLocalConversation(id: conversationId))
        XCTAssertEqual(restored.messages.map(\.content), ["Please finish this", "Finished on the server"])
        XCTAssertEqual(MockURLProtocol.recorded.count, 2)
        XCTAssertTrue(MockURLProtocol.recorded.allSatisfy { $0.method == "GET" })
    }

    func testExpiredOrMissingAcknowledgedRunClearsPendingWithoutReposting() async throws {
        config.ephemeral = true
        for status in [410, 404] {
            MockURLProtocol.reset()
            let record = try pending()
            try PendingRunStore(storage: storage).save(record)
            installResponses(detail: .json(status: status, body: Data()))

            let vm = makeViewModel()
            await vm.restoreConversationIfNeeded()

            XCTAssertEqual(vm.runState, .failed)
            XCTAssertFalse(vm.isLoading)
            let failure: PendingRunFailure = status == 410 ? .expired : .unavailable
            XCTAssertEqual(vm.error, failure.localizedDescription)
            XCTAssertNil(PendingRunStore(storage: storage).load(scope: record.scope))
            XCTAssertEqual(MockURLProtocol.recorded.count, 1)
            XCTAssertFalse(MockURLProtocol.recorded.contains { $0.method == "POST" })
            vm.invalidateForReplacement()
        }
    }

    func testTimedOutEventShowsRetryMessageAndClearsPendingRun() async throws {
        let scope = try XCTUnwrap(api.recoveryScope(agentKey: config.agentKey))
        let partial = frame("assistant.delta", seq: 0, payload: ["delta": "Partial answer"])
        let terminal = frame("run.timed_out", seq: 1)
        var timeoutEvents = 0
        config.onEvent = { type, _ in
            if type == "run.timed_out" { timeoutEvents += 1 }
        }
        installResponses(create: runDetail(status: "running"), stream: .sse(chunks: [partial + terminal]))
        let vm = makeViewModel()
        await sendAndWait(vm)

        XCTAssertEqual(timeoutEvents, 1)
        XCTAssertEqual(vm.runState, .failed)
        XCTAssertFalse(vm.isLoading)
        XCTAssertEqual(vm.error, "The response timed out. Please try again.")
        XCTAssertEqual(vm.messages.map(\.content), ["Please finish this", "Partial answer"])
        XCTAssertNil(PendingRunStore(storage: storage).load(scope: scope))
        XCTAssertEqual(MockURLProtocol.recorded.count, 2, "A terminal timeout must not schedule recovery")
    }

    private func makeViewModel() -> ChatViewModel {
        let client = APIClient(config: config, storage: storage)
        let vm = ChatViewModel(config: config, apiClient: client, storage: storage)
        models.append(vm)
        return vm
    }

    private func pending() throws -> PendingRun {
        let body = json([
            "idempotency_key": "reconcile-send-key",
            "agent_key": config.agentKey,
            "private_only": true,
            "ephemeral": config.ephemeral,
            "conversation_id": conversationId,
            "messages": [["role": "user", "content": "Please finish this"]],
        ])
        return PendingRun(scope: try XCTUnwrap(api.recoveryScope(agentKey: config.agentKey)),
                          ownerScope: api.recoveryOwnerScope, idempotencyKey: "reconcile-send-key",
                          body: body, createdAt: Date(), runId: runId, conversationId: conversationId,
                          transcript: [PendingMessage(from: Message(id: "user", role: .user, content: "Please finish this"))],
                          messagesOffset: 1, hasMore: false)
    }

    private func installResponses(create: Data? = nil, detail: MockURLProtocol.Response? = nil,
                                  stream: MockURLProtocol.Response? = nil) {
        let runsPath = "api/agent-runtime/runs"
        let runPath = "\(runsPath)/\(runId)"
        MockURLProtocol.register { request in
            let path = (request.url?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if request.httpMethod == "POST", path == runsPath, let create {
                return .json(status: 201, body: create)
            }
            if request.httpMethod == "GET", path == runPath, let detail { return detail }
            if request.httpMethod == "GET", path == "\(runPath)/stream", let stream {
                return stream
            }
            XCTFail("Unexpected request: \(request.httpMethod ?? "?") \(path)")
            // Fail closed without triggering retryable transport errors or live HTTP.
            return .json(status: 400, body: Data())
        }
    }

    private func runDetail(status: String) -> Data {
        var response: [String: Any] = [
            "id": runId,
            "conversation_id": conversationId,
            "status": status,
        ]
        if status == "succeeded" {
            response["output"] = ["final_messages": [
                ["id": "final", "seq": 4, "role": "assistant", "content": "Finished on the server"],
            ]]
        }
        return json(response)
    }

    private func frame(_ type: String, seq: Int, payload: [String: Any] = [:]) -> Data {
        let data = json(["run_id": runId, "seq": seq, "payload": payload])
        return Data("event: \(type)\ndata: \(String(decoding: data, as: UTF8.self))\n\n".utf8)
    }

    private func sendAndWait(_ vm: ChatViewModel) async {
        let finished = expectation(description: "send released after stream completion or disconnect")
        let send = Task { await vm.sendMessage("Please finish this"); finished.fulfill() }
        defer { send.cancel() }
        await fulfillment(of: [finished], timeout: 2)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "Recovery should settle within the test deadline")
    }

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}