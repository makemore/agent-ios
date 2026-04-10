import Foundation

// MARK: - Content Block Types

/// A structured content block returned by tools for rich UI rendering.
/// Each block has a `type` discriminator; unknown types are silently skipped.
public enum ContentBlock: Codable, Equatable, Identifiable {
    case card(CardBlock)
    case cardList(CardListBlock)
    case actionButtons(ActionButtonsBlock)
    case callout(CalloutBlock)
    case image(ImageBlock)
    case divider
    case table(TableBlock)
    case code(CodeBlock)
    case file(FileBlock)
    case collapsible(CollapsibleBlock)
    case status(StatusBlock)
    case location(LocationBlock)
    case video(VideoBlock)
    case unknown

    public var id: String {
        switch self {
        case .card(let b): return "card-\(b.title)"
        case .cardList(let b): return "cardList-\(b.items.count)"
        case .actionButtons: return "actionButtons-\(UUID().uuidString)"
        case .callout(let b): return "callout-\(b.body.prefix(20))"
        case .image(let b): return "image-\(b.url)"
        case .divider: return "divider-\(UUID().uuidString)"
        case .table: return "table-\(UUID().uuidString)"
        case .code(let b): return "code-\(b.code.prefix(20))"
        case .file(let b): return "file-\(b.filename)"
        case .collapsible(let b): return "collapsible-\(b.title)"
        case .status(let b): return "status-\(b.title)"
        case .location(let b): return "location-\(b.label)"
        case .video(let b): return "video-\(b.url)"
        case .unknown: return "unknown"
        }
    }

    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "card": self = .card(try CardBlock(from: decoder))
        case "cardList": self = .cardList(try CardListBlock(from: decoder))
        case "actionButtons": self = .actionButtons(try ActionButtonsBlock(from: decoder))
        case "callout": self = .callout(try CalloutBlock(from: decoder))
        case "image": self = .image(try ImageBlock(from: decoder))
        case "divider": self = .divider
        case "table": self = .table(try TableBlock(from: decoder))
        case "code": self = .code(try CodeBlock(from: decoder))
        case "file": self = .file(try FileBlock(from: decoder))
        case "collapsible": self = .collapsible(try CollapsibleBlock(from: decoder))
        case "status": self = .status(try StatusBlock(from: decoder))
        case "location": self = .location(try LocationBlock(from: decoder))
        case "video": self = .video(try VideoBlock(from: decoder))
        default: self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .card(let b): try b.encode(to: encoder)
        case .cardList(let b): try b.encode(to: encoder)
        case .actionButtons(let b): try b.encode(to: encoder)
        case .callout(let b): try b.encode(to: encoder)
        case .image(let b): try b.encode(to: encoder)
        case .divider: var c = encoder.container(keyedBy: CodingKeys.self); try c.encode("divider", forKey: .type)
        case .table(let b): try b.encode(to: encoder)
        case .code(let b): try b.encode(to: encoder)
        case .file(let b): try b.encode(to: encoder)
        case .collapsible(let b): try b.encode(to: encoder)
        case .status(let b): try b.encode(to: encoder)
        case .location(let b): try b.encode(to: encoder)
        case .video(let b): try b.encode(to: encoder)
        case .unknown: break
        }
    }
}

// MARK: - Block Action

public struct BlockAction: Codable, Equatable {
    public let type: String          // "link", "message", "callback"
    public let label: String
    public var url: String?
    public var message: String?
    public var callbackId: String?
    public var style: String?        // "primary" | "secondary"
}

// MARK: - Individual Block Types

public struct CardBlock: Codable, Equatable {
    public let type: String
    public var title: String
    public var subtitle: String?
    public var image: String?
    public var badge: String?
    public var metadata: [MetadataPair]?
    public var actions: [BlockAction]?
}

public struct MetadataPair: Codable, Equatable {
    public let label: String
    public let value: String
}

public struct CardListBlock: Codable, Equatable {
    public let type: String
    public var layout: String?       // "horizontal" | "vertical"
    public var items: [CardBlock]
}

public struct ActionButtonsBlock: Codable, Equatable {
    public let type: String
    public var buttons: [BlockAction]
}

public struct CalloutBlock: Codable, Equatable {
    public let type: String
    public var style: String?        // "info" | "success" | "warning"
    public var title: String?
    public var body: String
}

public struct ImageBlock: Codable, Equatable {
    public let type: String
    public var url: String
    public var alt: String?
    public var caption: String?
}

public struct TableBlock: Codable, Equatable {
    public let type: String
    public var headers: [String]?
    public var rows: [[String]]?
}

public struct CodeBlock: Codable, Equatable {
    public let type: String
    public var language: String?
    public var code: String
    public var filename: String?
    public var copyable: Bool?
}

public struct FileBlock: Codable, Equatable {
    public let type: String
    public var filename: String
    public var url: String
    public var mimeType: String?
    public var size: Int?
}

public struct CollapsibleBlock: Codable, Equatable {
    public let type: String
    public var title: String
    public var body: String
    public var defaultOpen: Bool?
}

public struct StatusBlock: Codable, Equatable {
    public let type: String
    public var state: String?        // "loading" | "success" | "error" | "warning" | "info"
    public var title: String
    public var body: String?
    public var progress: Double?
}

public struct LocationBlock: Codable, Equatable {
    public let type: String
    public var latitude: Double
    public var longitude: Double
    public var label: String
    public var zoom: Int?
}

public struct VideoBlock: Codable, Equatable {
    public let type: String
    public var url: String
    public var title: String?
    public var caption: String?
    public var thumbnailUrl: String?
    public var autoplay: Bool?
    public var mimeType: String?
}

// MARK: - Parsing Helper

extension ContentBlock {
    /// Parse an array of raw JSON dictionaries into typed ContentBlock values.
    public static func parse(from array: [[String: Any]]) -> [ContentBlock] {
        guard let data = try? JSONSerialization.data(withJSONObject: array) else { return [] }
        return (try? JSONDecoder().decode([ContentBlock].self, from: data)) ?? []
    }
}

