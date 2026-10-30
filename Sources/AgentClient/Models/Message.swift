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
    /// Elapsed wall-clock seconds between a `sub_agent.start` and its
    /// matching `sub_agent.end`. Populated on the collapsed `.subAgentEnd`
    /// row that the pill-mode reducer leaves behind so the history can
    /// render a quiet "Consulted X · 4s" caption on reload without having
    /// to re-walk the original event stream. Distinct from any
    /// reasoning-token duration the underlying LLM may report — this is
    /// pure orchestration wall-clock, not model "extended thinking".
    public var subAgentDurationSeconds: Double?

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
        resumeHint: Any? = nil,
        subAgentDurationSeconds: Double? = nil
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
        self.subAgentDurationSeconds = subAgentDurationSeconds
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
        lhs.actionLabel == rhs.actionLabel &&
        lhs.subAgentDurationSeconds == rhs.subAgentDurationSeconds
    }
}

/// File attachment
public struct FileAttachment: Identifiable, Equatable, Codable {
    public let id: String
    public let name: String
    public let size: Int
    public let type: String
    public var url: URL?
    public var data: Data?
    /// The host's id for this file once uploaded to `APIPaths.attachments`; a message
    /// sends these as `attachment_ids`, and history rows carry them for thumbnails.
    public var attachmentId: String?

    /// Photos show as thumbnails; every other file as an icon, name and size.
    public var isImage: Bool { type.hasPrefix("image/") }

    /// An SF Symbol for this file's kind (from its type, else its extension).
    public var symbolName: String { Self.symbolName(type: type, name: name) }

    /// "1.2 MB", or an empty string when the size is unknown.
    public var sizeText: String {
        size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) : ""
    }

    public static func symbolName(type: String, name: String) -> String {
        let type = type.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("video/") { return "film" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type == "application/pdf" || ext == "pdf" { return "doc.richtext" }
        if ["zip", "gz", "tar", "tgz", "7z", "rar", "bz2"].contains(ext) || type.contains("zip") { return "doc.zipper" }
        if ["xls", "xlsx", "csv", "tsv", "numbers", "ods"].contains(ext) || type.contains("spreadsheet") || type == "text/csv" { return "tablecells" }
        if ["ppt", "pptx", "key", "odp"].contains(ext) || type.contains("presentation") { return "rectangle.on.rectangle" }
        if ["json", "xml", "yaml", "yml", "html", "css", "js", "ts", "py", "swift", "java", "c", "cpp", "h", "rb", "go", "rs", "sh", "sql"].contains(ext) { return "chevron.left.forwardslash.chevron.right" }
        if type.hasPrefix("text/") || ["txt", "md", "rtf", "doc", "docx", "pages", "odt", "log"].contains(ext) { return "doc.text" }
        return "doc"
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        size: Int,
        type: String,
        url: URL? = nil,
        data: Data? = nil,
        attachmentId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.type = type
        self.url = url
        self.data = data
        self.attachmentId = attachmentId
    }
}

