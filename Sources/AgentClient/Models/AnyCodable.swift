import Foundation

/// Type-erased JSON value. Used by `Conversation.metadata` so the
/// client can decode the server's per-conversation metadata dict
/// (which carries `last_context_usage` and any other runtime-stamped
/// keys) without having to mirror every possible server-side field.
///
/// Only the subset of JSON shapes the client actually inspects is
/// supported (object, string, int, double, bool, null). Anything else
/// decodes as `.null` and round-trips lossily — fine for a read-only
/// metadata field.
public enum AnyCodable: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case object([String: AnyCodable])
    case array([AnyCodable])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
            return
        }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let o = try? c.decode([String: AnyCodable].self) { self = .object(o); return }
        if let a = try? c.decode([AnyCodable].self) { self = .array(a); return }
        self = .null
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        }
    }

    /// Lookup a key in an object-shaped value. Returns nil for
    /// non-object values (defensive — the runtime always stores the
    /// metadata as an object, but a hand-rolled test fixture may not).
    public func field(_ key: String) -> AnyCodable? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    /// Decode a known int key. Returns nil when the key is absent,
    /// the wrong shape, or stored as a `Double` that doesn't round
    /// cleanly (the runtime always stores counts as int).
    public func intValue() -> Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }

    public func stringValue() -> String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
