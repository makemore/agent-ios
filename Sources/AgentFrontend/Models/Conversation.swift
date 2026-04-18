import Foundation

/// A conversation containing messages
public struct Conversation: Identifiable, Codable {
    public let id: String
    public var title: String?
    public var messages: [APIMessage]?
    public var hasMore: Bool?
    public var createdAt: Date?
    public var updatedAt: Date?
    
    public init(
        id: String,
        title: String? = nil,
        messages: [APIMessage]? = nil,
        hasMore: Bool? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.hasMore = hasMore
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case title
        case messages
        case hasMore = "has_more"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
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

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case timestamp
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
        case metadata
    }
}

/// Metadata carried on an API message. The backend persists rich UI data
/// (e.g. contentBlocks from tool results) here so conversations can be
/// re-rendered faithfully on reload without replaying the SSE stream.
public struct APIMessageMetadata: Codable {
    public var contentBlocks: [ContentBlock]?
    public var toolName: String?

    enum CodingKeys: String, CodingKey {
        case contentBlocks
        case toolName = "tool_name"
    }
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
    
    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
    }
}

/// Conversation list response
public struct ConversationListResponse: Codable {
    public let results: [Conversation]?
    public let count: Int?
    public let next: String?
    public let previous: String?
}

