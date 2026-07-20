import Foundation

/// A conversation containing messages
public struct Conversation: Identifiable, Codable {
    public let id: String
    public var title: String?
    public var messages: [APIMessage]?
    public var hasMore: Bool?
    public var createdAt: Date?
    public var updatedAt: Date?
    /// Server-persisted conversation metadata. Used by the client
    /// to restore the last known `context.usage` snapshot
    /// (`metadata["last_context_usage"]`) when a conversation is
    /// reloaded — the banner then shows the freshest known token
    /// count immediately, before the next LLM call has a chance to
    /// ship a fresh `context.usage` event.
    public var metadata: [String: AnyCodable]?

    public init(
        id: String,
        title: String? = nil,
        messages: [APIMessage]? = nil,
        hasMore: Bool? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        metadata: [String: AnyCodable]? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.hasMore = hasMore
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}

/// API message format (for decoding from backend)
public struct APIMessage: Codable {
    public let role: String
    public var content: String?
    public var timestamp: Date?
    public var toolCalls: [ToolCall]?
    public var toolCallId: String?
    public var metadata: APIMessageMetadata?
}

/// Metadata carried on an API message. The backend persists rich UI data
/// (e.g. contentBlocks from tool results) here so conversations can be
/// re-rendered faithfully on reload without replaying the SSE stream.
public struct APIMessageMetadata: Codable {
    public var contentBlocks: [ContentBlock]?
    public var toolName: String?
}

/// Tool call from API
public struct ToolCall: Codable {
    public let id: String?
    public let name: String?
    public let function: ToolFunction?
    public let arguments: String?
    
    public struct ToolFunction: Codable {
        public let name: String?
        public let arguments: String?
    }
}

/// Agent run response
public struct AgentRun: Codable {
    public let id: String
    public var conversationId: String?
}

/// Conversation list response
public struct ConversationListResponse: Codable {
    public let results: [Conversation]?
    public let count: Int?
    public let next: String?
    public let previous: String?
}

