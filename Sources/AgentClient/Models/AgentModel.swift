import Foundation

/// Available LLM model, as advertised by `GET /api/agent-runtime/models/`.
/// The runtime emits snake_case keys (`supports_thinking`, `supports_tools`,
/// `supports_vision`) regardless of the shared JSON decoder's strategy, so
/// the mapping is spelt out explicitly via `CodingKeys`.
public struct AgentModel: Identifiable, Codable, Equatable {
    public let id: String
    public let name: String
    public let provider: String
    public var description: String?
    public var supportsThinking: Bool
    public var supportsTools: Bool
    public var supportsVision: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, description
        case supportsThinking = "supports_thinking"
        case supportsTools = "supports_tools"
        case supportsVision = "supports_vision"
    }

    public init(
        id: String,
        name: String,
        provider: String,
        description: String? = nil,
        supportsThinking: Bool = false,
        supportsTools: Bool = true,
        supportsVision: Bool = false
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.description = description
        self.supportsThinking = supportsThinking
        self.supportsTools = supportsTools
        self.supportsVision = supportsVision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.provider = try c.decode(String.self, forKey: .provider)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.supportsThinking = (try? c.decodeIfPresent(Bool.self, forKey: .supportsThinking)) ?? false
        self.supportsTools = (try? c.decodeIfPresent(Bool.self, forKey: .supportsTools)) ?? true
        self.supportsVision = (try? c.decodeIfPresent(Bool.self, forKey: .supportsVision)) ?? false
    }
}

/// Models list response from `/api/agent-runtime/models/`. `default` is the
/// runtime's configured fallback (`DEFAULT_MODEL`) — used by the picker
/// to pre-select something sensible when the user hasn't chosen yet.
public struct ModelsResponse: Codable {
    public let models: [AgentModel]
    public let `default`: String?
}

/// Task item
public struct TaskItem: Identifiable, Codable, Equatable {
    public let id: String
    public var name: String
    public var description: String?
    public var state: TaskState
    public var parentId: String?
    
    public init(
        id: String,
        name: String,
        description: String? = nil,
        state: TaskState = .notStarted,
        parentId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.state = state
        self.parentId = parentId
    }
}

/// Task state
public enum TaskState: String, Codable {
    case notStarted = "not_started"
    case inProgress = "in_progress"
    case complete
    case cancelled
    
    /// Next state in the cycle
    public var next: TaskState {
        switch self {
        case .notStarted: return .inProgress
        case .inProgress: return .complete
        case .complete: return .notStarted
        case .cancelled: return .notStarted
        }
    }
    
    /// Display icon
    public var icon: String {
        switch self {
        case .notStarted: return "○"
        case .inProgress: return "◐"
        case .complete: return "●"
        case .cancelled: return "⊘"
        }
    }
    
    /// Display label
    public var label: String {
        switch self {
        case .notStarted: return "Not Started"
        case .inProgress: return "In Progress"
        case .complete: return "Complete"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Task list with progress
public struct TaskList: Codable {
    public let id: String
    public var tasks: [TaskItem]
    public var progress: TaskProgress
}

/// Task progress
public struct TaskProgress: Codable {
    public var total: Int
    public var completed: Int
    public var percentComplete: Double

    public init(total: Int = 0, completed: Int = 0) {
        self.total = total
        self.completed = completed
        self.percentComplete = total > 0 ? Double(completed) / Double(total) * 100 : 0
    }
}

