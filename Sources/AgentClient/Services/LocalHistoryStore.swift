import Foundation
import SQLite3

// MARK: - Types

/// Summary of a locally-persisted ephemeral conversation (index entry).
public struct LocalConversationSummary: Identifiable, Equatable {
    public let id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messageCount: Int

    public init(id: String, title: String, createdAt: Date = Date(), updatedAt: Date = Date(), messageCount: Int = 0) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
    }
}

/// A full locally-persisted ephemeral conversation.
public struct LocalConversation {
    public let id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var messages: [LocalMessage]

    public init(id: String, title: String, createdAt: Date = Date(), updatedAt: Date = Date(), messages: [LocalMessage] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }
}

/// Lightweight message for local persistence (subset of Message fields).
public struct LocalMessage {
    public let id: String
    public let role: String
    public var content: String
    public let timestamp: Date
    public let type: String

    public init(id: String, role: String, content: String, timestamp: Date, type: String) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.type = type
    }
}

// MARK: - LocalHistoryStore (SQLite)

/// Manages on-device persistence of ephemeral conversations using SQLite.
/// Database location defaults to Application Support; pass `:memory:` for tests.
public class LocalHistoryStore {

    private var db: OpaquePointer?
    private let agentKey: String
    private let maxConversations: Int

    /// Open (or create) a SQLite database.
    /// - Parameters:
    ///   - agentKey: Scopes all data — different agents never collide.
    ///   - maxConversations: Eviction cap per agent (default 50).
    ///   - path: File path for the database. `":memory:"` gives an in-memory DB (tests).
    ///           `nil` uses `<ApplicationSupport>/agent_local_history.sqlite`.
    public init(agentKey: String, maxConversations: Int = 50, path: String? = nil) {
        self.agentKey = agentKey
        self.maxConversations = maxConversations

        let dbPath = path ?? Self.defaultDatabasePath()
        if let dir = path == nil ? URL(fileURLWithPath: dbPath).deletingLastPathComponent().path : nil {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("[LocalHistoryStore] Failed to open database at \(dbPath)")
        }
        if dbPath != ":memory:" {
            Self.protectFileAtRest(dbPath)
        }
        createTables()
    }

    deinit { sqlite3_close(db) }

    /// Encrypt the on-disk conversation database at rest. On iOS this ties the
    /// file to the device's hardware-backed class key with
    /// `.completeUnlessOpen`: unreadable on a locked, captured device, while a
    /// handle opened before lock keeps working so a backgrounded stream isn't
    /// killed mid-write. No-op on macOS (no data protection) and for in-memory
    /// databases. Also excludes the DB (and its -wal/-shm siblings) from
    /// iCloud/iTunes backups.
    private static func protectFileAtRest(_ dbPath: String) {
        #if os(iOS)
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let p = dbPath + suffix
            guard fm.fileExists(atPath: p) else { continue }
            try? fm.setAttributes(
                [.protectionKey: FileProtectionType.completeUnlessOpen],
                ofItemAtPath: p
            )
            var url = URL(fileURLWithPath: p)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        #endif
    }

    // MARK: - Schema

    private func createTables() {
        exec("""
            CREATE TABLE IF NOT EXISTS conversations (
                id         TEXT NOT NULL,
                agent_key  TEXT NOT NULL,
                title      TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                message_count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (id, agent_key)
            );
            CREATE TABLE IF NOT EXISTS messages (
                conversation_id TEXT NOT NULL,
                agent_key       TEXT NOT NULL,
                sort_order      INTEGER NOT NULL,
                msg_id          TEXT NOT NULL,
                role            TEXT NOT NULL,
                content         TEXT NOT NULL DEFAULT '',
                timestamp       INTEGER NOT NULL,
                type            TEXT NOT NULL DEFAULT 'message',
                PRIMARY KEY (conversation_id, agent_key, sort_order)
            );
        """)
    }

    // MARK: - Index

    /// Load the conversation index, newest first.
    public func loadIndex() -> [LocalConversationSummary] {
        var results: [LocalConversationSummary] = []
        let sql = "SELECT id, title, created_at, updated_at, message_count FROM conversations WHERE agent_key = ? ORDER BY updated_at DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (agentKey as NSString).utf8String, -1, nil)
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(LocalConversationSummary(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                title: String(cString: sqlite3_column_text(stmt, 1)),
                createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2)) / 1000.0),
                updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 3)) / 1000.0),
                messageCount: Int(sqlite3_column_int(stmt, 4))
            ))
        }
        return results
    }

    // MARK: - CRUD

    /// Upsert a conversation — creates/updates the row + replaces all messages.
    /// Trims to `maxConversations`, dropping oldest by `updatedAt`.
    public func upsert(_ conversation: LocalConversation) {
        exec("BEGIN TRANSACTION")

        // Upsert conversation row
        let upsertSQL = """
            INSERT INTO conversations (id, agent_key, title, created_at, updated_at, message_count)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id, agent_key) DO UPDATE SET
                title = excluded.title,
                updated_at = excluded.updated_at,
                message_count = excluded.message_count
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, upsertSQL, -1, &stmt, nil) == SQLITE_OK {
            bind(stmt, 1, conversation.id)
            bind(stmt, 2, agentKey)
            bind(stmt, 3, conversation.title)
            bind(stmt, 4, conversation.createdAt)
            bind(stmt, 5, conversation.updatedAt)
            sqlite3_bind_int(stmt, 6, Int32(conversation.messages.count))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }

        // Replace messages: delete + re-insert
        execBind("DELETE FROM messages WHERE conversation_id = ? AND agent_key = ?",
                 conversation.id, agentKey)

        let insertMsg = """
            INSERT INTO messages (conversation_id, agent_key, sort_order, msg_id, role, content, timestamp, type)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        for (i, m) in conversation.messages.enumerated() {
            var mStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, insertMsg, -1, &mStmt, nil) == SQLITE_OK {
                bind(mStmt, 1, conversation.id)
                bind(mStmt, 2, agentKey)
                sqlite3_bind_int(mStmt, 3, Int32(i))
                bind(mStmt, 4, m.id)
                bind(mStmt, 5, m.role)
                bind(mStmt, 6, m.content)
                bind(mStmt, 7, m.timestamp)
                bind(mStmt, 8, m.type)
                sqlite3_step(mStmt)
                sqlite3_finalize(mStmt)
            }
        }

        // Eviction
        evictIfNeeded()

        exec("COMMIT")
    }

    /// Load a full conversation by ID.
    public func load(_ conversationId: String) -> LocalConversation? {
        // Conversation row
        let sql = "SELECT title, created_at, updated_at FROM conversations WHERE id = ? AND agent_key = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, conversationId)
        bind(stmt, 2, agentKey)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let title = String(cString: sqlite3_column_text(stmt, 0))
        let createdAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1)) / 1000.0)
        let updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2)) / 1000.0)

        // Messages
        let messages = loadMessages(conversationId: conversationId)

        return LocalConversation(id: conversationId, title: title,
                                 createdAt: createdAt, updatedAt: updatedAt,
                                 messages: messages)
    }

    /// Delete a single conversation and its messages.
    public func delete(_ conversationId: String) {
        execBind("DELETE FROM messages WHERE conversation_id = ? AND agent_key = ?",
                 conversationId, agentKey)
        execBind("DELETE FROM conversations WHERE id = ? AND agent_key = ?",
                 conversationId, agentKey)
    }

    /// Purge all local conversations for this agent.
    public func purgeAll() {
        execBind("DELETE FROM messages WHERE agent_key = ?", agentKey)
        execBind("DELETE FROM conversations WHERE agent_key = ?", agentKey)
    }

    // MARK: - Private helpers

    private func loadMessages(conversationId: String) -> [LocalMessage] {
        var msgs: [LocalMessage] = []
        let sql = "SELECT msg_id, role, content, timestamp, type FROM messages WHERE conversation_id = ? AND agent_key = ? ORDER BY sort_order"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, conversationId)
        bind(stmt, 2, agentKey)
        while sqlite3_step(stmt) == SQLITE_ROW {
            msgs.append(LocalMessage(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                role: String(cString: sqlite3_column_text(stmt, 1)),
                content: String(cString: sqlite3_column_text(stmt, 2)),
                timestamp: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 3)) / 1000.0),
                type: String(cString: sqlite3_column_text(stmt, 4))
            ))
        }
        return msgs
    }

    private func evictIfNeeded() {
        // Find IDs to evict (oldest beyond the cap)
        let sql = """
            SELECT id FROM conversations WHERE agent_key = ?
            ORDER BY updated_at DESC LIMIT -1 OFFSET ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, agentKey)
        sqlite3_bind_int(stmt, 2, Int32(maxConversations))
        var idsToDelete: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            idsToDelete.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        for id in idsToDelete {
            execBind("DELETE FROM messages WHERE conversation_id = ? AND agent_key = ?", id, agentKey)
            execBind("DELETE FROM conversations WHERE id = ? AND agent_key = ?", id, agentKey)
        }
    }

    // MARK: - SQLite micro-helpers

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func execBind(_ sql: String, _ args: String...) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        for (i, arg) in args.enumerated() {
            bind(stmt, Int32(i + 1), arg)
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Date) {
        sqlite3_bind_int64(stmt, index, Int64(value.timeIntervalSince1970 * 1000))
    }

    private static func defaultDatabasePath() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("agent_local_history.sqlite").path
    }
}

// MARK: - Message ↔ LocalMessage conversion

public extension LocalMessage {
    init(from message: Message) {
        self.init(
            id: message.id,
            role: message.role.rawValue,
            content: message.content,
            timestamp: message.timestamp,
            type: message.type.rawValue
        )
    }

    func toMessage() -> Message {
        Message(
            id: id,
            role: MessageRole(rawValue: role) ?? .user,
            content: content,
            timestamp: timestamp,
            type: MessageType(rawValue: type) ?? .message
        )
    }
}