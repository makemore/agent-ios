import XCTest
@testable import AgentClient

@MainActor
final class HistoryPagingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        APIClient.sessionConfigurator = { $0.protocolClasses = [MockURLProtocol.self] }
    }

    override func tearDown() {
        MockURLProtocol.reset()
        APIClient.sessionConfigurator = nil
        super.tearDown()
    }

    private func configuration(ephemeral: Bool = false) -> ChatWidgetConfig {
        var config = ChatWidgetConfig(backendUrl: "https://example.test", agentKey: "history-tests-\(UUID().uuidString)")
        config.authStrategy = .token
        config.authToken = "synthetic-history-owner"
        config.ephemeral = ephemeral
        return config
    }

    func testKeysetPagesPreserveIdsRepeatedTextAndLiveRows() async {
        let config = configuration()
        let storage = InMemoryStorage()
        let api = APIClient(config: config, storage: storage)
        let model = ChatViewModel(config: config, apiClient: api, storage: storage)
        MockURLProtocol.register { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertTrue(query.contains(URLQueryItem(name: "limit", value: "50")))
            if query.contains(URLQueryItem(name: "before_seq", value: "51")) {
                XCTAssertFalse(query.contains { $0.name == "offset" })
                return .json(status: 200, body: Data(#"{"id":"conversation","messages":[{"id":"old","seq":1,"role":"user","content":"same"},{"id":"recent","seq":51,"role":"user","content":"same"}],"has_more":false,"next_before_seq":null}"#.utf8))
            }
            return .json(status: 200, body: Data(#"{"id":"conversation","messages":[{"id":"recent","seq":51,"role":"user","content":"same"},{"id":"answer","seq":52,"role":"assistant","content":"answer"}],"has_more":true,"next_before_seq":51}"#.utf8))
        }
        await model.loadConversation("conversation")
        let existingIDs = model.messages.map(\.id)
        model.messages.append(Message(id: "live", role: .assistant, content: "live answer"))
        await model.loadMoreMessages()
        XCTAssertEqual(model.messages.map(\.id), ["message-old"] + existingIDs + ["live"])
        XCTAssertEqual(model.messages.filter { $0.content == "same" }.count, 2)
        XCTAssertFalse(model.hasMoreMessages)
    }

    func testLegacyResponseFallsBackToOffsetNotDisplayRowCount() async {
        let config = configuration()
        let storage = InMemoryStorage()
        let api = APIClient(config: config, storage: storage)
        let model = ChatViewModel(config: config, apiClient: api, storage: storage)
        MockURLProtocol.register { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertFalse(query.contains { $0.name == "before_seq" })
            if MockURLProtocol.recorded.count == 1 {
                return .json(status: 200, body: Data(#"{"id":"conversation","messages":[{"id":"tool","role":"assistant","content":"Looking","tool_calls":[{"id":"a","name":"lookup","arguments":{"q":"x"}},{"id":"b","name":"lookup"}]}],"hasMore":true}"#.utf8))
            }
            XCTAssertTrue(query.contains(URLQueryItem(name: "offset", value: "1")))
            return .json(status: 200, body: Data(#"{"id":"conversation","messages":[],"hasMore":false}"#.utf8))
        }
        await model.loadConversation("conversation")
        XCTAssertEqual(model.messages.count, 3, "Text accompanying tool calls must survive mapping")
        await model.loadMoreMessages()
        XCTAssertEqual(model.messages.count, 3)
        XCTAssertFalse(model.hasMoreMessages)
    }

    func testEarlierPageIsPartOfDurableRecoveryBase() async throws {
        let config = configuration()
        let storage = InMemoryStorage()
        let api = APIClient(config: config, storage: storage)
        let store = PendingRunStore(storage: storage)
        let pending = PendingRun(scope: api.recoveryScope(agentKey: config.agentKey)!, ownerScope: api.recoveryOwnerScope,
            idempotencyKey: "history-send", body: Data("{}".utf8), createdAt: Date(), runId: "run", conversationId: "conversation",
            transcript: [PendingMessage(from: Message(id: "user", role: .user, content: "new question"))],
            messagesOffset: 1, nextBeforeSeq: 51, hasMore: true)
        try store.save(pending)
        MockURLProtocol.register { request in
            if request.url!.path.contains("conversations") {
                return .json(status: 200, body: Data(#"{"id":"conversation","messages":[{"id":"old","seq":1,"role":"assistant","content":"earlier"}],"has_more":false,"next_before_seq":null}"#.utf8))
            }
            return .json(status: 200, body: Data(#"{"id":"run","status":"succeeded","output":{"final_messages":[{"role":"assistant","content":"finished"}]}}"#.utf8))
        }
        let model = ChatViewModel(config: config, apiClient: api, storage: storage)
        await model.loadMoreMessages()
        XCTAssertEqual(store.load(scope: pending.scope)?.transcript.map { $0.message.content }, ["earlier", "new question"])
        await model.reconcilePendingRun()
        XCTAssertEqual(model.messages.map(\.content), ["earlier", "new question", "finished"])
    }

    func testHistoryResponsesFromClearedSessionAreRejected() async {
        for list in [false, true] {
            MockURLProtocol.reset()
            let api = APIClient(config: configuration(), storage: InMemoryStorage())
            MockURLProtocol.register { _ in
                api.clearSession()
                let body = list ? #"{"results":[{"id":"old-account"}]}"# : #"{"id":"old-account","messages":[]}"#
                return .json(status: 200, body: Data(body.utf8))
            }
            do {
                if list { _ = try await api.loadConversations() }
                else { _ = try await api.loadConversation(id: "old-account") }
                XCTFail("History received after logout must be rejected")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    func testEphemeralSendKeepsFullContextRatherThanRecentUIPage() async throws {
        let config = configuration(ephemeral: true)
        let storage = InMemoryStorage()
        let api = APIClient(config: config, storage: storage)
        let model = ChatViewModel(config: config, apiClient: api, storage: storage)
        defer { model.purgeLocalHistory() }
        model.messages = (0..<120).map { Message(role: $0.isMultiple(of: 2) ? .user : .assistant, content: "turn \($0)") }
        await model.loadConversation("local-conversation")
        XCTAssertEqual(model.messages.count, 120)
        XCTAssertTrue(MockURLProtocol.recorded.isEmpty)
        MockURLProtocol.register { _ in .json(status: 401, body: Data()) }
        await model.sendMessage("new turn")
        let data = try XCTUnwrap(MockURLProtocol.recorded.first?.body)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 121)
        XCTAssertEqual(messages.first?["content"], "turn 0")
        XCTAssertEqual(messages.last?["content"], "new turn")
    }
}