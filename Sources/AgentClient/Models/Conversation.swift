import Foundation

/// A conversation containing messages
public struct Conversation: Identifiable, Codable {
    public let id: String
    public var title: String?
    public var messages: [APIMessage]?
    public var hasMore: Bool?
    public var nextBeforeSeq: Int?
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
        metadata: [String: AnyCodable]? = nil,
        nextBeforeSeq: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.hasMore = hasMore
        self.nextBeforeSeq = nextBeforeSeq
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, messages, hasMore, nextBeforeSeq, createdAt, updatedAt, metadata
        case has_more, next_before_seq, created_at, updated_at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        messages = try c.decodeIfPresent([APIMessage].self, forKey: .messages)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? c.decodeIfPresent(Bool.self, forKey: .has_more)
        nextBeforeSeq = try c.decodeIfPresent(Int.self, forKey: .nextBeforeSeq) ?? c.decodeIfPresent(Int.self, forKey: .next_before_seq)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? c.decodeIfPresent(Date.self, forKey: .created_at)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? c.decodeIfPresent(Date.self, forKey: .updated_at)
        metadata = try c.decodeIfPresent([String: AnyCodable].self, forKey: .metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(messages, forKey: .messages)
        try c.encodeIfPresent(hasMore, forKey: .hasMore)
        try c.encodeIfPresent(nextBeforeSeq, forKey: .nextBeforeSeq)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(metadata, forKey: .metadata)
    }
}

/// API message format (for decoding from backend)
public struct APIMessage: Codable {
    public let role: String
    public var id: String? = nil
    public var seq: Int? = nil
    public var content: String?
    public var rawContent: AnyCodable? = nil
    public var timestamp: Date?
    public var toolCalls: [ToolCall]?
    public var toolCallId: String?
    public var metadata: APIMessageMetadata?

    public init(role: String, content: String? = nil, timestamp: Date? = nil,
                toolCalls: [ToolCall]? = nil, toolCallId: String? = nil,
                metadata: APIMessageMetadata? = nil, id: String? = nil, seq: Int? = nil) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.metadata = metadata
        self.id = id
        self.seq = seq
    }

    private enum CodingKeys: String, CodingKey {
        case role, id, seq, content, timestamp, toolCalls, toolCallId, metadata, tool_calls, tool_call_id
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        seq = try c.decodeIfPresent(Int.self, forKey: .seq)
        // Structured text blocks are legal final-message content too.
        let value = try c.decodeIfPresent(AnyCodable.self, forKey: .content)
        rawContent = value
        if case .array(let parts)? = value {
            content = parts.compactMap { $0.field("text")?.stringValue() }.joined()
        } else { content = value?.stringValue() }
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp)
        toolCalls = try c.decodeIfPresent([ToolCall].self, forKey: .toolCalls) ?? c.decodeIfPresent([ToolCall].self, forKey: .tool_calls)
        toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId) ?? c.decodeIfPresent(String.self, forKey: .tool_call_id)
        metadata = try c.decodeIfPresent(APIMessageMetadata.self, forKey: .metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(seq, forKey: .seq)
        if let rawContent { try c.encode(rawContent, forKey: .content) }
        else { try c.encodeIfPresent(content, forKey: .content) }
        try c.encodeIfPresent(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(toolCallId, forKey: .toolCallId)
        try c.encodeIfPresent(metadata, forKey: .metadata)
    }
}

/// Metadata carried on an API message. The backend persists rich UI data
/// (e.g. contentBlocks from tool results) here so conversations can be
/// re-rendered faithfully on reload without replaying the SSE stream.
public struct APIMessageMetadata: Codable {
    public var contentBlocks: [ContentBlock]?
    public var toolName: String?

    public init(contentBlocks: [ContentBlock]? = nil, toolName: String? = nil) {
        self.contentBlocks = contentBlocks
        self.toolName = toolName
    }

    private enum CodingKeys: String, CodingKey { case contentBlocks, content_blocks, toolName, tool_name }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentBlocks = try c.decodeIfPresent([ContentBlock].self, forKey: .contentBlocks) ?? c.decodeIfPresent([ContentBlock].self, forKey: .content_blocks)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName) ?? c.decodeIfPresent(String.self, forKey: .tool_name)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(contentBlocks, forKey: .contentBlocks)
        try c.encodeIfPresent(toolName, forKey: .toolName)
    }
}

/// Tool call from API
public struct ToolCall: Codable {
    public let id: String?
    public let name: String?
    public let function: ToolFunction?
    public let arguments: String?

    public init(id: String? = nil, name: String? = nil, function: ToolFunction? = nil, arguments: String? = nil) {
        self.id = id; self.name = name; self.function = function; self.arguments = arguments
    }
    private enum CodingKeys: String, CodingKey { case id, name, function, arguments }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        function = try c.decodeIfPresent(ToolFunction.self, forKey: .function)
        arguments = try Self.argumentText(c.decodeIfPresent(AnyCodable.self, forKey: .arguments))
    }

    private static func argumentText(_ value: AnyCodable?) -> String? {
        guard let value else { return nil }
        if let text = value.stringValue() { return text }
        return (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }
    
    public struct ToolFunction: Codable {
        public let name: String?
        public let arguments: String?

        public init(name: String? = nil, arguments: String? = nil) { self.name = name; self.arguments = arguments }
        private enum CodingKeys: String, CodingKey { case name, arguments }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            arguments = try ToolCall.argumentText(c.decodeIfPresent(AnyCodable.self, forKey: .arguments))
        }
    }
}

/// Agent run response
public struct AgentRun: Codable {
    public let id: String
    public var conversationId: String?
    public var status: String? = nil
    public var output: [String: AnyCodable]? = nil
    public var error: AnyCodable? = nil

    public init(id: String, conversationId: String? = nil, status: String? = nil,
                output: [String: AnyCodable]? = nil, error: AnyCodable? = nil) {
        self.id = id
        self.conversationId = conversationId
        self.status = status
        self.output = output
        self.error = error
    }

    public var normalizedStatus: String { (status ?? "").lowercased() }

    /// Only final_messages is authoritative. Do not mistake cumulative legacy
    /// `messages` context or a partial checkpoint for a finished answer.
    public var finalMessages: [APIMessage]? {
        guard let value = output?["final_messages"] ?? output?["finalMessages"],
              let data = try? JSONEncoder().encode(value) else { return nil }
        let decoder = JSONDecoder()
        // APIMessage handles both casings explicitly. Globally converting keys
        // would mutate opaque nested tool/content-block metadata as well.
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([APIMessage].self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case id, conversationId, conversation_id, status, output, error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        conversationId = try c.decodeIfPresent(String.self, forKey: .conversationId) ?? c.decodeIfPresent(String.self, forKey: .conversation_id)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        output = try c.decodeIfPresent([String: AnyCodable].self, forKey: .output)
        error = try c.decodeIfPresent(AnyCodable.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(conversationId, forKey: .conversationId)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(output, forKey: .output)
        try c.encodeIfPresent(error, forKey: .error)
    }
}

/// Conversation list response
public struct ConversationListResponse: Codable {
    public let results: [Conversation]?
    public let count: Int?
    public let next: String?
    public let previous: String?
}

