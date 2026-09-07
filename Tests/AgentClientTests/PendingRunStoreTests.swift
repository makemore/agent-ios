import XCTest
@testable import AgentClient

final class PendingRunStoreTests: XCTestCase {
    private func pending(scope: String, owner: String = "owner") -> PendingRun {
        PendingRun(scope: scope, ownerScope: owner, idempotencyKey: UUID().uuidString,
            body: Data(#"{"messages":[{"role":"user","content":"fixture"}]}"#.utf8), createdAt: Date(),
            transcript: [], messagesOffset: 0, hasMore: false)
    }

    func testScopeSeparatesBackendAgentAndPrincipal() {
        let scope = PendingRunStore.scope(backend: "https://one.test", agent: "one", principal: "one")
        XCTAssertNotEqual(scope, PendingRunStore.scope(backend: "https://two.test", agent: "one", principal: "one"))
        XCTAssertNotEqual(scope, PendingRunStore.scope(backend: "https://one.test", agent: "two", principal: "one"))
        XCTAssertNotEqual(scope, PendingRunStore.scope(backend: "https://one.test", agent: "one", principal: "two"))
    }

    func testExactBodyBackoffAndMatchingCleanupRoundTrip() throws {
        let store = PendingRunStore(storage: InMemoryStorage())
        var record = pending(scope: "scope")
        record.retryCount = 3
        record.nextRetryAt = Date().addingTimeInterval(20)
        try store.save(record)
        XCTAssertEqual(store.load(scope: "scope")?.body, record.body)
        XCTAssertEqual(store.load(scope: "scope")?.retryCount, 3)
        XCTAssertEqual(store.load(scope: "scope")?.nextRetryAt, record.nextRetryAt)
        store.clear(scope: "scope", matching: "different-send")
        XCTAssertNotNil(store.load(scope: "scope"))
        store.clear(scope: "scope", matching: record.idempotencyKey)
        XCTAssertNil(store.load(scope: "scope"))
    }

    func testPurgeReachesInactiveAgentsOnlyForMatchingOwner() throws {
        let store = PendingRunStore(storage: InMemoryStorage())
        try store.save(pending(scope: "agent-a"))
        try store.save(pending(scope: "agent-b"))
        try store.save(pending(scope: "other-account", owner: "other"))
        store.clearAll(owner: "owner")
        XCTAssertNil(store.load(scope: "agent-a"))
        XCTAssertNil(store.load(scope: "agent-b"))
        XCTAssertNotNil(store.load(scope: "other-account"))
    }

    func testWriteFailureIsDetectedBeforeCallerCanPost() {
        final class UnavailableStorage: StorageService {
            func get(_ key: String) -> String? { nil }
            func set(_ key: String, value: String?) {}
        }
        let store = PendingRunStore(storage: UnavailableStorage())
        XCTAssertThrowsError(try store.save(pending(scope: "scope")))
    }

    func testAnotherViewModelCannotOverwriteUnresolvedSend() throws {
        let store = PendingRunStore(storage: InMemoryStorage())
        let original = pending(scope: "scope")
        try store.save(original)
        XCTAssertThrowsError(try store.save(pending(scope: "scope")))
        XCTAssertEqual(store.load(scope: "scope")?.idempotencyKey, original.idempotencyKey)
    }

    func testSecureRoutingAndRichSnapshotRoundTrip() throws {
        let secure = InMemoryStorage()
        let standard = InMemoryStorage()
        let storage = SecureStorageService(secure: secure, standard: standard)
        storage.set("pending_run_scope", value: "fixture")
        XCTAssertNil(standard.get("pending_run_scope"))
        XCTAssertEqual(secure.get("pending_run_scope"), "fixture")
        let message = Message(id: "tool", role: .system, content: "Done", type: .toolResult,
            metadata: MessageMetadata(toolName: "lookup", toolCallId: "call", result: ["ok": true]))
        let restored = try JSONDecoder().decode(PendingMessage.self, from: JSONEncoder().encode(PendingMessage(from: message))).toMessage()
        XCTAssertEqual(restored.id, message.id)
        XCTAssertEqual(restored.metadata?.toolCallId, "call")
        XCTAssertEqual((restored.metadata?.result as? [String: Bool])?["ok"], true)
    }
}