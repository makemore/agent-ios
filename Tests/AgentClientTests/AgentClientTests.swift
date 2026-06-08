import XCTest
@testable import AgentClient

final class AgentClientTests: XCTestCase {
    
    // MARK: - Configuration Tests
    
    func testDefaultConfiguration() {
        let config = ChatWidgetConfig()
        
        XCTAssertEqual(config.backendUrl, "http://localhost:8000")
        XCTAssertEqual(config.agentKey, "default-agent")
        XCTAssertEqual(config.title, "Chat Assistant")
        XCTAssertTrue(config.showTasksTab)
        // Model selector is opt-in: hidden unless the host turns it on.
        XCTAssertFalse(config.showModelSelector)
    }

    func testCustomConfiguration() {
        var config = ChatWidgetConfig(backendUrl: "https://api.example.com", agentKey: "my-agent")
        config.title = "My Chat"
        config.showTasksTab = false
        config.showModelSelector = true

        XCTAssertEqual(config.backendUrl, "https://api.example.com")
        XCTAssertEqual(config.agentKey, "my-agent")
        XCTAssertEqual(config.title, "My Chat")
        XCTAssertFalse(config.showTasksTab)
        XCTAssertTrue(config.showModelSelector)
    }
    
    // MARK: - API Paths Tests
    
    func testDefaultAPIPaths() {
        let paths = APIPaths()
        
        XCTAssertEqual(paths.conversations, "/api/agent-runtime/conversations/")
        XCTAssertEqual(paths.runs, "/api/agent-runtime/runs/")
    }
    
    func testRunEventsUrl() {
        let paths = APIPaths()
        let url = paths.runEventsUrl(for: "abc123")
        
        XCTAssertEqual(url, "/api/agent-runtime/runs/abc123/stream/")
    }
    
    func testCancelRunUrl() {
        let paths = APIPaths()
        let url = paths.cancelRunUrl(for: "abc123")
        
        XCTAssertEqual(url, "/api/agent-runtime/runs/abc123/cancel/")
    }
    
    // MARK: - Auth Strategy Tests
    
    func testAuthStrategyDefaults() {
        XCTAssertEqual(AuthStrategy.token.defaultHeader, "Authorization")
        XCTAssertEqual(AuthStrategy.token.defaultPrefix, "Token")
        
        XCTAssertEqual(AuthStrategy.jwt.defaultHeader, "Authorization")
        XCTAssertEqual(AuthStrategy.jwt.defaultPrefix, "Bearer")
        
        XCTAssertEqual(AuthStrategy.anonymous.defaultHeader, "X-Anonymous-Token")
        XCTAssertEqual(AuthStrategy.anonymous.defaultPrefix, "")
    }
    
    // MARK: - Storage Tests
    
    func testInMemoryStorage() {
        let storage = InMemoryStorage()
        
        XCTAssertNil(storage.get("test_key"))
        
        storage.set("test_key", value: "test_value")
        XCTAssertEqual(storage.get("test_key"), "test_value")
        
        storage.set("test_key", value: nil)
        XCTAssertNil(storage.get("test_key"))
    }
    
    // MARK: - Message Tests
    
    func testMessageCreation() {
        let message = Message(
            role: .user,
            content: "Hello, world!"
        )
        
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content, "Hello, world!")
        XCTAssertEqual(message.type, .message)
        XCTAssertNotNil(message.id)
    }
    
    func testMessageEquality() {
        let message1 = Message(id: "test-id", role: .user, content: "Hello")
        let message2 = Message(id: "test-id", role: .user, content: "Hello")
        let message3 = Message(id: "test-id", role: .user, content: "Different")
        
        XCTAssertEqual(message1, message2)
        XCTAssertNotEqual(message1, message3)
    }
    
    // MARK: - APIMessage metadata decoding

    func testAPIMessageDecodesContentBlocksInMetadata() throws {
        let json = """
        {
          "role": "tool",
          "content": "Found a calming video",
          "toolCallId": "call_vid",
          "metadata": {
            "toolName": "get_video",
            "contentBlocks": [
              {"type": "video", "url": "https://example.com/a.mp4", "title": "Calm"}
            ]
          }
        }
        """.data(using: .utf8)!

        let msg = try JSONDecoder().decode(APIMessage.self, from: json)
        XCTAssertEqual(msg.role, "tool")
        XCTAssertEqual(msg.toolCallId, "call_vid")
        XCTAssertEqual(msg.metadata?.toolName, "get_video")
        guard case .video(let v) = msg.metadata?.contentBlocks?.first else {
            return XCTFail("expected video block")
        }
        XCTAssertEqual(v.url, "https://example.com/a.mp4")
        XCTAssertEqual(v.title, "Calm")
    }

    func testAPIMessageWithoutMetadataDecodesCleanly() throws {
        let json = """
        { "role": "user", "content": "hi" }
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(APIMessage.self, from: json)
        XCTAssertNil(msg.metadata)
    }

    // MARK: - Task State Tests

    func testTaskStateTransitions() {
        XCTAssertEqual(TaskState.notStarted.next, .inProgress)
        XCTAssertEqual(TaskState.inProgress.next, .complete)
        XCTAssertEqual(TaskState.complete.next, .notStarted)
        XCTAssertEqual(TaskState.cancelled.next, .notStarted)
    }
    
    func testTaskStateIcons() {
        XCTAssertEqual(TaskState.notStarted.icon, "○")
        XCTAssertEqual(TaskState.inProgress.icon, "◐")
        XCTAssertEqual(TaskState.complete.icon, "●")
        XCTAssertEqual(TaskState.cancelled.icon, "⊘")
    }

    // MARK: - Ephemeral conversationId rehydration

    @MainActor
    func testEphemeralModeDoesNotRehydrateConversationId() {
        // Pre-populate storage with a stale server-side conversation ID
        let storage = InMemoryStorage()
        storage.set("chat_widget_conversation_id", value: "stale-server-id")

        var config = ChatWidgetConfig(backendUrl: "http://stub.local", agentKey: "test-agent")
        config.ephemeral = true

        let apiClient = APIClient(config: config, storage: storage)
        let vm = ChatViewModel(config: config, apiClient: apiClient, storage: storage)

        XCTAssertNil(vm.conversationId,
                     "Ephemeral VM should not rehydrate a stale server conversationId")
    }

    @MainActor
    func testNonEphemeralModeRehydratesConversationId() {
        // Pre-populate storage with a server-side conversation ID
        let storage = InMemoryStorage()
        storage.set("chat_widget_conversation_id", value: "server-id-123")

        var config = ChatWidgetConfig(backendUrl: "http://stub.local", agentKey: "test-agent")
        config.ephemeral = false

        let apiClient = APIClient(config: config, storage: storage)
        let vm = ChatViewModel(config: config, apiClient: apiClient, storage: storage)

        XCTAssertEqual(vm.conversationId, "server-id-123",
                       "Non-ephemeral VM should rehydrate the saved conversationId")
    }
}
