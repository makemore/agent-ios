import Foundation

/// Loads the shared SSE fixtures in `test-harness/fixtures/sse/` and
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
        let seq_override: Int?
    }

    let name: String
    let runId: String
    let conversationId: String
    let events: [Event]

    static func load(_ name: String, file: StaticString = #filePath) throws -> SSEFixture {
        let url = try SharedFixture.locate(
            "sse/\(name).json",
            from: URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        )
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
            let eventSeq = ev.seq_override ?? seq
            let payload = ev.payload?.mapValues { $0.value } ?? [:]
            let envelope: [String: Any] = [
                "run_id": runId,
                "seq": eventSeq,
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
}

/// Shared by SSE and ephemeral parity tests. Canonical fixtures take precedence
/// over standalone/legacy copies, even if those copies are nearer the source.
enum SharedFixture {
    static func locate(_ relativePath: String, from directory: URL) throws -> URL {
        let start = directory.standardizedFileURL
        var ancestors: [URL] = []
        var current = start
        while true {
            ancestors.append(current)
            // Directory URLs can append /.. when deleting the root component.
            // Normalize each step so traversal always terminates at /.
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break }
            current = parent
        }

        var searched: [String] = []
        for layout in ["test-harness/fixtures", "test-fixtures", "clients/test-fixtures"] {
            for ancestor in ancestors {
                let candidate = ancestor.appendingPathComponent(layout).appendingPathComponent(relativePath)
                searched.append(candidate.path)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                   !isDirectory.boolValue {
                    return candidate
                }
            }
        }
        throw NSError(
            domain: "SharedFixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "Could not locate fixture \(relativePath) from \(start.path). " +
                "Check out test-harness/fixtures in a common ancestor of the client, " +
                "or provide test-fixtures (legacy clients/test-fixtures is also supported). " +
                "Searched:\n\(searched.joined(separator: "\n"))"
            ]
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
