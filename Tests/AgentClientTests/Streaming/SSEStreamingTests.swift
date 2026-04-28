import XCTest
@testable import AgentClient

/// End-to-end Level-A streaming tests. These wire the *real*
/// `ChatViewModel`, `APIClient` and `SSEClient` together but route every
/// HTTP request through `MockURLProtocol` so each scenario plays back a
/// JSON fixture from `clients/test-fixtures/sse/`. No network, no real
/// `agent_studio` instance — but the same code paths the production app
/// exercises.
@MainActor
final class SSEStreamingTests: XCTestCase {

    private var config: ChatWidgetConfig!
    private var apiClient: APIClient!
    private var storage: InMemoryStorage!

    override func setUp() {
        super.setUp()
        let injectMock: (URLSessionConfiguration) -> Void = { cfg in
            cfg.protocolClasses = [MockURLProtocol.self] + (cfg.protocolClasses ?? [])
        }
        SSEClient.sessionConfigurator = injectMock
        APIClient.sessionConfigurator = injectMock
        config = ChatWidgetConfig(
            backendUrl: "http://stub.local",
            agentKey: "test-agent"
        )
        storage = InMemoryStorage()
        apiClient = APIClient(config: config, storage: storage)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        SSEClient.sessionConfigurator = nil
        APIClient.sessionConfigurator = nil
        super.tearDown()
    }

    // MARK: - Tests

    func testSimpleStreamingFlowFinalisesAssistantMessage() async throws {
        let fixture = try SSEFixture.load("simple_streaming")
        installHandlers(for: fixture)
        let expected = "Hello there! How can I help you today?"

        let vm = ChatViewModel(config: config, apiClient: apiClient, storage: storage)
        await vm.sendMessage("Hi")
        try await waitForStreamSettled(vm: vm, expectedLastAssistantContent: expected)

        // user + assistant
        XCTAssertEqual(vm.messages.count, 2, "expected user + assistant only, got \(dump(vm.messages))")
        XCTAssertEqual(vm.messages[0].role, .user)
        XCTAssertEqual(vm.messages[0].content, "Hi")
        XCTAssertEqual(vm.messages[1].role, .assistant)
        XCTAssertEqual(vm.messages[1].type, .message)
        XCTAssertEqual(vm.messages[1].content, expected)
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.conversationId, fixture.conversationId)
    }

    func testToolCallEmitsContentBlocksMessage() async throws {
        let fixture = try SSEFixture.load("tool_call_with_content_blocks")
        installHandlers(for: fixture)

        let vm = ChatViewModel(config: config, apiClient: apiClient, storage: storage)
        await vm.sendMessage("Find me a beach house")
        try await waitForStreamSettled(vm: vm, expectedLastAssistantContent: "I found 2 options that match.")

        let types = vm.messages.map { ($0.role, $0.type) }
        // Sequence: user, assistant prelude, tool.call, tool.result, content.blocks, assistant final
        XCTAssertTrue(types.contains(where: { $0.0 == .assistant && $0.1 == .toolCall }), "missing tool.call: \(types)")
        XCTAssertTrue(types.contains(where: { $0.0 == .system    && $0.1 == .toolResult }), "missing tool.result: \(types)")

        let blocksMsg = vm.messages.first { $0.type == .contentBlocks }
        XCTAssertNotNil(blocksMsg, "expected a contentBlocks message")
        let blocks = blocksMsg?.metadata?.contentBlocks ?? []
        XCTAssertEqual(blocks.count, 2, "expected card + table")
        if case .card(let card) = blocks[0] {
            XCTAssertEqual(card.title, "Beach House")
            XCTAssertEqual(card.metadata?.count, 2)
        } else { XCTFail("first block should be a card, got \(blocks[0])") }
        if case .table(let table) = blocks[1] {
            XCTAssertEqual(table.headers, ["Listing", "Price", "Sleeps"])
            XCTAssertEqual(table.rows?.count, 2)
        } else { XCTFail("second block should be a table, got \(blocks[1])") }

        XCTAssertEqual(vm.messages.last?.role, .assistant)
        XCTAssertEqual(vm.messages.last?.content, "I found 2 options that match.")
    }

    func testMultiAgentHandoffSuppressesParentEcho() async throws {
        let fixture = try SSEFixture.load("sai_multi_agent_handoff")
        installHandlers(for: fixture)

        let vm = ChatViewModel(config: config, apiClient: apiClient, storage: storage)
        await vm.sendMessage("I'm anxious about something")
        let therapistReply = "Hi, I'm here to listen. Could you tell me a little about what's on your mind?"
        try await waitForStreamSettled(vm: vm, expectedLastAssistantContent: therapistReply)

        let assistantMessages = vm.messages.filter { $0.role == .assistant && $0.type == .message }
        let assistantText = assistantMessages.map(\.content)

        // The parent's *re-stream* of the sub-agent's reply must be suppressed
        // so we never see the same long sentence twice.
        XCTAssertEqual(
            assistantText.filter { $0 == therapistReply }.count, 1,
            "sub-agent reply should appear exactly once, got: \(assistantText)"
        )

        // Sub-agent markers exist in order.
        let starts = vm.messages.filter { $0.type == .subAgentStart }
        let ends = vm.messages.filter { $0.type == .subAgentEnd }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(ends.count, 1)
        XCTAssertEqual(starts.first?.metadata?.agentName, "S'Ai Therapist")
    }

    func testMultiAgentWithBlocksRendersSubAgentBlocks() async throws {
        let fixture = try SSEFixture.load("sai_multi_agent_with_blocks")
        installHandlers(for: fixture)

        let vm = ChatViewModel(config: config, apiClient: apiClient, storage: storage)
        await vm.sendMessage("Show me my account")
        try await waitForStreamSettled(vm: vm)

        let blocksMsg = vm.messages.first { $0.type == .contentBlocks }
        let blocks = blocksMsg?.metadata?.contentBlocks ?? []
        XCTAssertEqual(blocks.count, 3, "expected callout + cardList + actionButtons, got \(blocks)")
        if case .callout(let c) = blocks[0] {
            XCTAssertEqual(c.style, "info")
            XCTAssertEqual(c.title, "Account in good standing")
        } else { XCTFail("expected callout") }
        if case .cardList(let list) = blocks[1] {
            XCTAssertEqual(list.items.count, 2)
            XCTAssertEqual(list.items[0].title, "Plan")
        } else { XCTFail("expected cardList") }
        if case .actionButtons(let ab) = blocks[2] {
            XCTAssertEqual(ab.buttons.count, 2)
            XCTAssertEqual(ab.buttons[0].callbackId, "pay_invoice")
        } else { XCTFail("expected actionButtons") }
    }

    func testRunFailedSurfacesError() async throws {
        let fixture = try SSEFixture.load("run_failed")
        installHandlers(for: fixture)

        let vm = ChatViewModel(config: config, apiClient: apiClient, storage: storage)
        await vm.sendMessage("Hello")
        try await waitForStreamSettled(vm: vm)

        XCTAssertEqual(vm.error, "Upstream provider unavailable")
        XCTAssertTrue(
            vm.messages.contains { $0.type == .error && $0.role == .system },
            "expected an error message in the list, got \(dump(vm.messages))"
        )
    }

    // MARK: - Helpers

    /// Wire MockURLProtocol to satisfy the three endpoints `ChatViewModel`
    /// + `APIClient` will hit during a single `sendMessage`.
    private func installHandlers(for fixture: SSEFixture) {
        let runResponse: [String: Any] = [
            "id": fixture.runId,
            "conversationId": fixture.conversationId,
            "status": "running",
        ]
        let runJSON = try! JSONSerialization.data(withJSONObject: runResponse)
        let chunks = fixture.sseChunks()

        MockURLProtocol.register { request in
            guard let url = request.url else { return nil }
            // `URL.path` drops a trailing slash on iOS 16+, so normalise
            // both the incoming request and our match patterns by trimming.
            let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
            let method = request.httpMethod ?? "GET"
            switch (method, path) {
            case ("POST", "/api/accounts/anonymous-session"):
                return .json(status: 200, body: Data(#"{"token":"stub-anon-token"}"#.utf8))
            case ("POST", "/api/agent-runtime/runs"):
                return .json(status: 200, body: runJSON)
            case (_, _) where path.hasSuffix("/stream"):
                return .sse(chunks: chunks)
            default:
                return nil
            }
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping () -> Bool
    ) async throws {
        let start = Date()
        while !predicate() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("waitUntil timed out after \(timeout)s", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }
    }

    /// Wait for the run to terminate (`isLoading == false`) **and** the
    /// drain timer's typewriter buffer to fully reveal. Optionally wait
    /// until the most recent assistant text bubble matches the expected
    /// final string — this is the only reliable way to assert content
    /// because `isLoading` flips on `run.succeeded` while the drain
    /// continues to reveal characters for another ~100–500ms.
    private func waitForStreamSettled(
        vm: ChatViewModel,
        expectedLastAssistantContent expected: String? = nil,
        timeout: TimeInterval = 8.0,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await waitUntil(timeout: timeout, file: file, line: line) {
            guard !vm.isLoading else { return false }
            if let expected = expected {
                let lastAssistantText = vm.messages
                    .last(where: { $0.role == .assistant && $0.type == .message })?.content
                return lastAssistantText == expected
            }
            return true
        }
        // Even with no `expected` text, give the drain timer a couple of
        // ticks of grace to commit any tail characters into the bubble.
        try await Task.sleep(nanoseconds: 120_000_000)
    }

    private func dump(_ messages: [Message]) -> String {
        messages.map { "\($0.role)/\($0.type): \($0.content.prefix(40))" }.joined(separator: " | ")
    }
}
