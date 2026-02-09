import XCTest
@testable import AgentFrontend

final class AgentFrontendTests: XCTestCase {
    
    // MARK: - Configuration Tests
    
    func testDefaultConfiguration() {
        let config = ChatWidgetConfig()
        
        XCTAssertEqual(config.backendUrl, "http://localhost:8000")
        XCTAssertEqual(config.agentKey, "default-agent")
        XCTAssertEqual(config.title, "Chat Assistant")
        XCTAssertTrue(config.showTasksTab)
    }
    
    func testCustomConfiguration() {
        var config = ChatWidgetConfig(backendUrl: "https://api.example.com", agentKey: "my-agent")
        config.title = "My Chat"
        config.showTasksTab = false

        XCTAssertEqual(config.backendUrl, "https://api.example.com")
        XCTAssertEqual(config.agentKey, "my-agent")
        XCTAssertEqual(config.title, "My Chat")
        XCTAssertFalse(config.showTasksTab)
    }
    
    func testConfigurationMake() {
        let config = ChatWidgetConfig.make(
            backendUrl: "https://api.example.com",
            agentKey: "test-agent",
            title: "Test Chat"
        )
        
        XCTAssertEqual(config.backendUrl, "https://api.example.com")
        XCTAssertEqual(config.agentKey, "test-agent")
        XCTAssertEqual(config.title, "Test Chat")
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
        
        XCTAssertEqual(url, "/api/agent-runtime/runs/abc123/events/")
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
}

