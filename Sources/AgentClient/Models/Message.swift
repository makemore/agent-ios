import Foundation

/// A chat message
public struct Message: Identifiable, Equatable {
    public let id: String
    public let role: MessageRole
    public var content: String
    public let timestamp: Date
    public let type: MessageType
    public var metadata: MessageMetadata?
    public var files: [FileAttachment]?
    
    public init(
        id: String = UUID().uuidString,
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        type: MessageType = .message,
        metadata: MessageMetadata? = nil,
        files: [FileAttachment]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.type = type
        self.metadata = metadata
        self.files = files
    }
    
    public static func == (lhs: Message, rhs: Message) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content
    }
}

/// Message role
public enum MessageRole: String, Codable {
    case user
    case assistant
    case system
    case tool
}

/// Message type
public enum MessageType: String, Codable {
    case message
    case toolCall = "tool_call"
    case toolResult = "tool_result"
    case error
    case cancelled
    case requiredAction = "required_action"
    case subAgentStart = "sub_agent_start"
    case subAgentEnd = "sub_agent_end"
    case agentContext = "agent_context"
    case contentBlocks = "content_blocks"
}

/// Generic lifecycle state for a single run.
public enum RunState: String, Codable, Equatable {
    case idle, sending, streaming, waiting, cancelling, cancelled, failed, succeeded

    public func applying(eventType: String) -> RunState {
        switch eventType {
        case "run.started", "assistant.delta", "assistant.message", "tool.call", "tool.result", "content.blocks":
            return .streaming
        case "run.suspended", "client.action.required":
            return .waiting
        case "run.cancelled": return .cancelled
        case "run.failed", "run.timed_out": return .failed
        case "run.succeeded": return .succeeded
        default: return self
        }
    }
}

/// Message metadata
public struct MessageMetadata: Equatable {
    public var toolName: String?
    public var toolCallId: String?
    public var arguments: String?
    public var result: Any?
    public var subAgentKey: String?
    public var agentName: String?
    public var invocationMode: String?
    public var contentBlocks: [ContentBlock]?
    public var actionId: String?
    public var actionType: String?
    public var actionURL: String?
    public var actionLabel: String?
    public var resumeHint: Any?

    public init(
        toolName: String? = nil,
        toolCallId: String? = nil,
        arguments: String? = nil,
        result: Any? = nil,
        subAgentKey: String? = nil,
        agentName: String? = nil,
        invocationMode: String? = nil,
        contentBlocks: [ContentBlock]? = nil,
        actionId: String? = nil,
        actionType: String? = nil,
        actionURL: String? = nil,
        actionLabel: String? = nil,
        resumeHint: Any? = nil
    ) {
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.arguments = arguments
        self.result = result
        self.subAgentKey = subAgentKey
        self.agentName = agentName
        self.invocationMode = invocationMode
        self.contentBlocks = contentBlocks
        self.actionId = actionId
        self.actionType = actionType
        self.actionURL = actionURL
        self.actionLabel = actionLabel
        self.resumeHint = resumeHint
    }

    public static func == (lhs: MessageMetadata, rhs: MessageMetadata) -> Bool {
        lhs.toolName == rhs.toolName &&
        lhs.toolCallId == rhs.toolCallId &&
        lhs.arguments == rhs.arguments &&
        lhs.subAgentKey == rhs.subAgentKey &&
        lhs.agentName == rhs.agentName &&
        lhs.contentBlocks == rhs.contentBlocks &&
        lhs.actionId == rhs.actionId &&
        lhs.actionType == rhs.actionType &&
        lhs.actionURL == rhs.actionURL &&
        lhs.actionLabel == rhs.actionLabel
    }
}

/// File attachment
public struct FileAttachment: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let size: Int
    public let type: String
    public var url: URL?
    public var data: Data?
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        size: Int,
        type: String,
        url: URL? = nil,
        data: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.type = type
        self.url = url
        self.data = data
    }
}

