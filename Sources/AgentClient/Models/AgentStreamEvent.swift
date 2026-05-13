import Foundation

public enum AgentStreamConnectionStatus: String, Codable, Equatable {
    case idle, connecting, open, reconnecting, closed, errored
}

public struct AgentStreamEvent {
    public static let knownTypes: Set<String> = [
        "assistant.message", "assistant.delta", "tool.call", "tool.result",
        "tool.progress", "content.blocks", "sub_agent.start", "sub_agent.end",
        "custom", "error", "run.started", "run.succeeded", "run.failed",
        "run.cancelled", "run.timed_out", "run.suspended", "run.resumed",
        "client.action.required", "run.heartbeat", "state.checkpoint",
        "step.started", "step.completed", "step.failed", "step.skipped",
        "step.retrying", "progress.update", "memory.update"
    ]

    public let type: String
    public let payload: [String: Any]
    public let runId: String?
    public let seq: Int?
    public let timestamp: String?
    public let known: Bool
    public let parseError: String?

    public static func parse(_ data: String, eventTypeHint: String? = nil) -> AgentStreamEvent {
        guard let bytes = data.data(using: .utf8) else {
            return malformed(raw: data, error: "Invalid UTF-8")
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            guard let obj else { return malformed(raw: data, error: "Event JSON must be an object") }
            return parse(obj, eventTypeHint: eventTypeHint)
        } catch {
            return malformed(raw: data, error: error.localizedDescription)
        }
    }

    public static func parse(_ obj: [String: Any], eventTypeHint: String? = nil) -> AgentStreamEvent {
        let type = obj["type"] as? String ?? eventTypeHint ?? "message"
        let payload = obj["payload"] as? [String: Any] ?? obj
        return AgentStreamEvent(
            type: type,
            payload: payload,
            runId: obj["run_id"] as? String ?? obj["runId"] as? String,
            seq: obj["seq"] as? Int,
            timestamp: obj["ts"] as? String,
            known: knownTypes.contains(type),
            parseError: nil
        )
    }

    private static func malformed(raw: String, error: String) -> AgentStreamEvent {
        AgentStreamEvent(
            type: "unknown",
            payload: [:],
            runId: nil,
            seq: nil,
            timestamp: nil,
            known: false,
            parseError: error
        )
    }

    public var dedupeKey: String? {
        if let runId, let seq { return "\(runId):\(seq)" }
        if type == "assistant.delta" { return nil }
        let stable = payload["id"] ?? payload["message_id"] ?? payload["tool_call_id"] ?? payload["action_id"]
        return (stable as? String).map { "\(type):\($0)" }
    }
}

public enum AgentRunLifecycleStatus: String, Codable, Equatable {
    case idle, running, waiting, succeeded, failed, cancelled, timedOut, errored
}

public struct AgentToolCallState {
    public var id: String
    public var name: String?
    public var status: String
    public var result: Any?
    public var error: Any?
}

public struct AgentRequiredActionState {
    public var id: String
    public var actionType: String?
    public var status: String
    public var title: String?
    public var message: String?
}

public struct AgentRunReducerState {
    public var runId: String?
    public var status: AgentRunLifecycleStatus = .idle
    public var assistantText: String = ""
    public var toolCalls: [String: AgentToolCallState] = [:]
    public var requiredActions: [String: AgentRequiredActionState] = [:]
    public var unknownEvents: [AgentStreamEvent] = []
    public var seenEventKeys: Set<String> = []

    public init() {}

    public mutating func apply(_ event: AgentStreamEvent) {
        if let key = event.dedupeKey {
            if seenEventKeys.contains(key) { return }
            seenEventKeys.insert(key)
        }
        if let runId = event.runId { self.runId = runId }
        if !event.known { applyUnknown(event); return }

        switch event.type {
        case "run.started": status = .running
        case "assistant.delta":
            status = status == .idle ? .running : status
            assistantText += event.payload["delta"] as? String ?? ""
        case "assistant.message":
            assistantText = event.payload["content"] as? String ?? assistantText
        case "tool.call": applyToolCall(event.payload)
        case "tool.progress": applyToolProgress(event.payload)
        case "tool.result": applyToolResult(event.payload)
        case "client.action.required": applyRequiredAction(event.payload)
        case "run.suspended": status = .waiting
        case "run.succeeded": status = .succeeded
        case "run.failed": status = .failed
        case "run.cancelled": status = .cancelled
        case "run.timed_out": status = .timedOut
        case "error": status = .errored
        default: break
        }
    }

    private mutating func applyToolCall(_ payload: [String: Any]) {
        status = .running
        let id = payload["id"] as? String ?? payload["tool_call_id"] as? String ?? "tool-\(toolCalls.count)"
        toolCalls[id] = AgentToolCallState(id: id, name: payload["name"] as? String ?? payload["tool_name"] as? String, status: "running")
    }

    private mutating func applyToolProgress(_ payload: [String: Any]) {
        guard let id = payload["tool_call_id"] as? String ?? payload["id"] as? String else { return }
        var call = toolCalls[id] ?? AgentToolCallState(id: id, name: nil, status: "running")
        call.status = "running"
        toolCalls[id] = call
    }

    private mutating func applyToolResult(_ payload: [String: Any]) {
        let id = payload["tool_call_id"] as? String ?? payload["id"] as? String ?? "tool-\(toolCalls.count)"
        let result = payload["result"]
        let error = (result as? [String: Any])?["error"]
        toolCalls[id] = AgentToolCallState(id: id, name: payload["name"] as? String ?? payload["tool_name"] as? String, status: error == nil ? "completed" : "failed", result: result, error: error)
    }

    private mutating func applyRequiredAction(_ payload: [String: Any]) {
        status = .waiting
        let action = payload["required_action"] as? [String: Any] ?? payload
        let id = action["action_id"] as? String ?? "action-\(requiredActions.count)"
        requiredActions[id] = AgentRequiredActionState(id: id, actionType: action["action_type"] as? String, status: "requested", title: action["title"] as? String, message: action["message"] as? String)
    }

    private mutating func applyUnknown(_ event: AgentStreamEvent) {
        if (event.type == "client.action.submitted" || event.type == "client.action.resolved"),
           let id = event.payload["action_id"] as? String,
           var action = requiredActions[id] {
            action.status = event.type.hasSuffix("submitted") ? "submitted" : "resolved"
            requiredActions[id] = action
        }
        unknownEvents.append(event)
    }
}
