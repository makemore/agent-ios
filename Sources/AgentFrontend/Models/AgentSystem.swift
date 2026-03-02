import Foundation

/// An agent system — a named collection of agents that work together
public struct AgentSystem: Identifiable, Codable, Equatable {
    public let id: String
    public let slug: String
    public let name: String
    public var description: String?
    public var isActive: Bool
    public var entryAgent: AgentDefinitionSummary?
    public var members: [AgentSystemMember]?
    public var versions: [AgentSystemVersionSummary]?
    public var activeVersion: String?

    public init(
        id: String,
        slug: String,
        name: String,
        description: String? = nil,
        isActive: Bool = true,
        entryAgent: AgentDefinitionSummary? = nil,
        members: [AgentSystemMember]? = nil,
        versions: [AgentSystemVersionSummary]? = nil,
        activeVersion: String? = nil
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.description = description
        self.isActive = isActive
        self.entryAgent = entryAgent
        self.members = members
        self.versions = versions
        self.activeVersion = activeVersion
    }

    enum CodingKeys: String, CodingKey {
        case id, slug, name, description
        case isActive = "is_active"
        case entryAgent = "entry_agent"
        case members, versions
        case activeVersion = "active_version"
    }
}

/// Summary of an agent definition (used in system listings)
public struct AgentDefinitionSummary: Identifiable, Codable, Equatable {
    public let id: String
    public let slug: String
    public let name: String
    public var description: String?
    public var icon: String?
    public var isActive: Bool
    public var activeVersion: String?
    public var versions: [AgentVersionSummary]?

    enum CodingKeys: String, CodingKey {
        case id, slug, name, description, icon
        case isActive = "is_active"
        case activeVersion = "active_version"
        case versions
    }
}

/// Summary of an agent version
public struct AgentVersionSummary: Identifiable, Codable, Equatable {
    public let id: String
    public let version: String
    public var isActive: Bool
    public var isDraft: Bool
    public var model: String?
    public var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, version, model
        case isActive = "is_active"
        case isDraft = "is_draft"
        case createdAt = "created_at"
    }
}

/// A member agent within a system
public struct AgentSystemMember: Identifiable, Codable, Equatable {
    public let id: String
    public let agent: AgentDefinitionSummary
    public var role: String
    public var order: Int
    public var notes: String?
}

/// Summary of a system version
public struct AgentSystemVersionSummary: Identifiable, Codable, Equatable {
    public let id: String
    public let version: String
    public var isActive: Bool
    public var isDraft: Bool
    public var releaseNotes: String?
    public var publishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, version
        case isActive = "is_active"
        case isDraft = "is_draft"
        case releaseNotes = "release_notes"
        case publishedAt = "published_at"
    }
}

/// Response wrapper for paginated system lists
public struct SystemsListResponse: Codable {
    public let results: [AgentSystem]?
    public let count: Int?
}

/// Response wrapper for paginated agent definition lists
public struct AgentDefinitionsListResponse: Codable {
    public let results: [AgentDefinitionSummary]?
    public let count: Int?
}

