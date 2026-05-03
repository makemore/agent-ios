import XCTest
@testable import AgentClient

/// End-to-end tests for ephemeral mode local-history persistence.
/// Drives a real `ChatViewModel` + `APIClient` + `SSEClient` through
/// `MockURLProtocol` and verifies that completed runs are written to
/// `LocalHistoryStore`.
@MainActor
final class EphemeralPersistenceTests: XCTestCase {

    private var apiClient: APIClient!
    private var storage: InMemoryStorage!
    private var agentKey: String!

    override func setUp() {
        super.setUp()
        let injectMock: (URLSessionConfiguration) -> Void = { cfg in
            cfg.protocolClasses = [MockURLProtocol.self] + (cfg.protocolClasses ?? [])
        }
        SSEClient.sessionConfigurator = injectMock
        APIClient.sessionConfigurator = injectMock
        // Unique agent key per test isolates SQLite rows in the shared
        // ApplicationSupport database; teardown then purges them.
        agentKey = "test-agent-\(UUID().uuidString)"
        storage = InMemoryStorage()
    }

    override func tearDown() {
        // Purge anything this test wrote so we don't pollute the dev's
        // ApplicationSupport directory across runs.
        let cleanupConfig = makeConfig(ephemeral: true)
        let cleanupClient = APIClient(config: cleanupConfig, storage: storage)
        let vm = ChatViewModel(config: cleanupConfig, apiClient: cleanupClient, storage: storage)
        vm.purgeLocalHistory()

        MockURLProtocol.reset()
        SSEClient.sessionConfigurator = nil
        APIClient.sessionConfigurator = nil
        super.tearDown()
    }

    // MARK: - Tests

    func testEphemeralRunPersistsConversation() async throws {
        let fixture = try SSEFixture.load("simple_streaming")
        installHandlers(for: fixture)

        let config = makeConfig(ephemeral: true)
        apiClient = APIClient(config: config, storage: storage)
        let vm = ChatViewModel(config: config, apiClient: apiClient, storage: storage)

        await vm.sendMessage("hello world")
        try await waitForStreamSettled(vm: vm)
        try await waitUntil { vm.localConversations.count == 1 }

        XCTAssertEqual(vm.conversationId, fixture.conversationId)
        XCTAssertEqual(vm.localConversations.count, 1,
                       "expected one persisted conversation, got \(vm.localConversations)")
        let summary = vm.localConversations[0]
        XCTAssertEqual(summary.id, fixture.conversationId)
        XCTAssertEqual(summary.title, "hello world")
        XCTAssertEqual(summary.messageCount, 2, "expected user + assistant")
    }

    func testNonEphemeralRunDoesNotPersist() async throws {
        let fixture = try SSEFixture.load("simple_streaming")
        installHandlers(for: fixture)

        let config = makeConfig(ephemeral: false)
        apiClient = APIClient(config: config, storage: storage)
        let vm = ChatViewModel(config: config, apiClient: apiClient, storage: storage)

        await vm.sendMessage("hello world")
        try await waitForStreamSettled(vm: vm)

        XCTAssertEqual(vm.conversationId, fixture.conversationId)
        XCTAssertTrue(vm.localConversations.isEmpty,
                      "non-ephemeral mode must not persist locally")
    }

    func testTwoConsecutiveRunsProduceTwoRows() async throws {
        // First run uses the simple_streaming fixture.
        let firstFixture = try SSEFixture.load("simple_streaming")
        installHandlers(for: firstFixture)

        let config = makeConfig(ephemeral: true)
        apiClient = APIClient(config: config, storage: storage)
        let vm = ChatViewModel(config: config, apiClient: apiClient, storage: storage)

        await vm.sendMessage("first message")
        try await waitForStreamSettled(vm: vm)
        try await waitUntil { vm.localConversations.count == 1 }
        XCTAssertEqual(vm.localConversations.count, 1)

        // Start a fresh conversation; install a handler that returns a
        // different conversation/run id so the second persisted row is
        // distinct from the first.
        vm.clearMessages()
        MockURLProtocol.reset()
        let secondFixture = SSEFixture(
            name: firstFixture.name,
            runId: "test-run-second-002",
            conversationId: "test-conv-second-002",
            events: firstFixture.events
        )
        installHandlers(for: secondFixture)

        await vm.sendMessage("second message")
        try await waitForStreamSettled(vm: vm)
        try await waitUntil { vm.localConversations.count == 2 }

        XCTAssertEqual(vm.localConversations.count, 2,
                       "expected two distinct persisted conversations")
        let ids = Set(vm.localConversations.map(\.id))
        XCTAssertEqual(ids, [firstFixture.conversationId, secondFixture.conversationId])
        let titles = Set(vm.localConversations.map(\.title))
        XCTAssertEqual(titles, ["first message", "second message"])
    }

    // MARK: - Helpers

    private func makeConfig(ephemeral: Bool) -> ChatWidgetConfig {
        var config = ChatWidgetConfig(
            backendUrl: "http://stub.local",
            agentKey: agentKey
        )
        config.ephemeral = ephemeral
        return config
    }

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

    private func waitForStreamSettled(vm: ChatViewModel, timeout: TimeInterval = 8.0) async throws {
        let start = Date()
        while vm.isLoading {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("waitForStreamSettled timed out after \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // Let the drain timer flush the final tail characters.
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    private func waitUntil(timeout: TimeInterval = 5.0, _ predicate: () -> Bool) async throws {
        let start = Date()
        while !predicate() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("waitUntil timed out after \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
