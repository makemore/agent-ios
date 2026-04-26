import Foundation

/// Loads the shared SSE fixtures in `clients/test-fixtures/sse/` and
/// renders them to either:
///   - a single `Data` blob in the same wire format the real backend
///     produces (one `event:`/`data:` frame per event), or
///   - an array of one-frame `Data` chunks suitable for feeding through
///     `MockURLProtocol` to mimic packets arriving piecewise.
///
/// Fixtures are located by walking up from the test source file to the
/// repo root, so this works under `swift test` and Xcode without any
/// resource bundling.
struct SSEFixture {

    struct Event: Decodable {
        let delay_ms: Int?
        let event: String
        let payload: [String: AnyCodable]?
    }

    let name: String
    let runId: String
    let conversationId: String
    let events: [Event]

    static func load(_ name: String, file: StaticString = #filePath) throws -> SSEFixture {
        let url = try fixturesDirectory(from: file).appendingPathComponent("\(name).json")
        let data = try Data(contentsOf: url)
        struct Raw: Decodable {
            let name: String?
            let run_id: String
            let conversation_id: String
            let events: [Event]
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return SSEFixture(
            name: raw.name ?? name,
            runId: raw.run_id,
            conversationId: raw.conversation_id,
            events: raw.events
        )
    }

    /// One byte blob per event, formatted exactly like the backend.
    func sseChunks() -> [Data] {
        var seq = 0
        var out: [Data] = []
        let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 0))
        for ev in events {
            let payload = ev.payload?.mapValues { $0.value } ?? [:]
            let envelope: [String: Any] = [
                "run_id": runId,
                "seq": seq,
                "type": ev.event,
                "payload": payload,
                "ts": iso,
                "visibility_level": "user",
                "ui_visible": true,
            ]
            seq += 1
            let body = try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            let bodyStr = String(data: body, encoding: .utf8)!
            let frame = "event: \(ev.event)\ndata: \(bodyStr)\n\n"
            out.append(frame.data(using: .utf8)!)
        }
        return out
    }

    private static func fixturesDirectory(from file: StaticString) throws -> URL {
        var url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        // Walk up until we find the `clients/` directory, then descend.
        for _ in 0..<10 {
            let candidate = url.appendingPathComponent("test-fixtures/sse")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let siblings = url.appendingPathComponent("clients/test-fixtures/sse")
            if FileManager.default.fileExists(atPath: siblings.path) {
                return siblings
            }
            url.deleteLastPathComponent()
        }
        throw NSError(
            domain: "SSEFixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate clients/test-fixtures/sse from \(file)"]
        )
    }
}

/// Tiny `Decodable` wrapper for arbitrary JSON payload values so we can
/// round-trip the fixture's `payload` dict through `JSONSerialization`.
struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            value = NSNull()
        } else if let b = try? c.decode(Bool.self) {
            value = b
        } else if let i = try? c.decode(Int.self) {
            value = i
        } else if let d = try? c.decode(Double.self) {
            value = d
        } else if let s = try? c.decode(String.self) {
            value = s
        } else if let arr = try? c.decode([AnyCodable].self) {
            value = arr.map { $0.value }
        } else if let dict = try? c.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }
}
