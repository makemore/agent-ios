import XCTest
@testable import AgentClient

final class LocalHistoryStoreTests: XCTestCase {

    /// Each test gets a fresh in-memory SQLite database via `:memory:`.
    private func makeStore(agentKey: String = "test-agent", maxConversations: Int = 50) -> LocalHistoryStore {
        LocalHistoryStore(agentKey: agentKey, maxConversations: maxConversations, path: ":memory:")
    }

    private func makeConversation(id: String = "conv-1", title: String = "Hello", messageCount: Int = 2) -> LocalConversation {
        let msgs = (0..<messageCount).map { i in
            LocalMessage(id: "m\(i)", role: i % 2 == 0 ? "user" : "assistant",
                         content: "msg \(i)", timestamp: Date(), type: "message")
        }
        return LocalConversation(id: id, title: title, messages: msgs)
    }

    // MARK: - Index

    func testEmptyStoreReturnsEmptyIndex() {
        let store = makeStore()
        XCTAssertEqual(store.loadIndex(), [])
    }

    func testUpsertCreatesIndexEntry() {
        let store = makeStore()
        store.upsert(makeConversation())

        let index = store.loadIndex()
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index[0].id, "conv-1")
        XCTAssertEqual(index[0].title, "Hello")
        XCTAssertEqual(index[0].messageCount, 2)
    }

    func testUpsertUpdatesExistingEntry() {
        let store = makeStore()
        store.upsert(makeConversation(title: "First"))
        store.upsert(makeConversation(title: "Updated", messageCount: 5))

        let index = store.loadIndex()
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index[0].title, "Updated")
        XCTAssertEqual(index[0].messageCount, 5)
    }

    func testIndexOrderedNewestFirst() {
        let store = makeStore()
        store.upsert(makeConversation(id: "old", title: "Old"))
        Thread.sleep(forTimeInterval: 0.01)
        store.upsert(makeConversation(id: "new", title: "New"))

        let index = store.loadIndex()
        XCTAssertEqual(index[0].id, "new")
        XCTAssertEqual(index[1].id, "old")
    }

    // MARK: - Load / Delete

    func testLoadConversation() {
        let store = makeStore()
        store.upsert(makeConversation())

        let loaded = store.load("conv-1")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, "conv-1")
        XCTAssertEqual(loaded?.messages.count, 2)
        XCTAssertEqual(loaded?.messages[0].role, "user")
    }

    func testLoadMissingReturnsNil() {
        let store = makeStore()
        XCTAssertNil(store.load("nonexistent"))
    }

    func testDeleteConversation() {
        let store = makeStore()
        store.upsert(makeConversation(id: "a"))
        store.upsert(makeConversation(id: "b"))

        store.delete("a")
        XCTAssertEqual(store.loadIndex().count, 1)
        XCTAssertNil(store.load("a"))
        XCTAssertNotNil(store.load("b"))
    }

    // MARK: - Purge

    func testPurgeAll() {
        let store = makeStore()
        store.upsert(makeConversation(id: "a"))
        store.upsert(makeConversation(id: "b"))

        store.purgeAll()
        XCTAssertEqual(store.loadIndex(), [])
        XCTAssertNil(store.load("a"))
        XCTAssertNil(store.load("b"))
    }

    // MARK: - Eviction

    func testEvictionDropsOldest() {
        let store = makeStore(maxConversations: 3)

        for i in 0..<5 {
            Thread.sleep(forTimeInterval: 0.01)
            store.upsert(makeConversation(id: "conv-\(i)", title: "Conv \(i)"))
        }

        let index = store.loadIndex()
        XCTAssertEqual(index.count, 3)
        let ids = Set(index.map { $0.id })
        XCTAssertFalse(ids.contains("conv-0"))
        XCTAssertFalse(ids.contains("conv-1"))
        XCTAssertTrue(ids.contains("conv-2"))
        XCTAssertTrue(ids.contains("conv-3"))
        XCTAssertTrue(ids.contains("conv-4"))

        XCTAssertNil(store.load("conv-0"))
        XCTAssertNil(store.load("conv-1"))
    }

    // MARK: - Scope isolation
    // With SQLite, agent_key is a column-level scope within the same DB.
    // In-memory DBs are per-connection, so for this test we use a shared
    // temp file so both stores share the same database.

    func testAgentKeyIsolation() {
        let tmpPath = NSTemporaryDirectory() + "test_isolation_\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let storeA = LocalHistoryStore(agentKey: "agent-a", path: tmpPath)
        let storeB = LocalHistoryStore(agentKey: "agent-b", path: tmpPath)

        storeA.upsert(makeConversation(id: "conv-a"))
        storeB.upsert(makeConversation(id: "conv-b"))

        XCTAssertEqual(storeA.loadIndex().count, 1)
        XCTAssertEqual(storeA.loadIndex()[0].id, "conv-a")

        XCTAssertEqual(storeB.loadIndex().count, 1)
        XCTAssertEqual(storeB.loadIndex()[0].id, "conv-b")
    }

    // MARK: - Message conversion

    func testLocalMessageRoundTrip() {
        let original = Message(role: .assistant, content: "Hello!", type: .message)
        let local = LocalMessage(from: original)
        let roundTripped = local.toMessage()

        XCTAssertEqual(roundTripped.id, original.id)
        XCTAssertEqual(roundTripped.role, .assistant)
        XCTAssertEqual(roundTripped.content, "Hello!")
        XCTAssertEqual(roundTripped.type, .message)
    }
}
