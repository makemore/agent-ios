import Foundation

/// Available LLM model
public struct AgentModel: Identifiable, Codable, Equatable {
    public let id: String
    public let name: String
    public let provider: String
    public var description: String?
    public var supportsThinking: Bool
    
    public init(
        id: String,
        name: String,
        provider: String,
        description: String? = nil,
        supportsThinking: Bool = false
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.description = description
        self.supportsThinking = supportsThinking
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case provider
        case description
        case supportsThinking = "supports_thinking"
    }
}

/// Models list response
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
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case state
        case parentId = "parent_id"
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
    
    enum CodingKeys: String, CodingKey {
        case total
        case completed
        case percentComplete = "percent_complete"
    }
    
    public init(total: Int = 0, completed: Int = 0) {
        self.total = total
        self.completed = completed
        self.percentComplete = total > 0 ? Double(completed) / Double(total) * 100 : 0
    }
}

