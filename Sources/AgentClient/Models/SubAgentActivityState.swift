import Foundation

/// Transient view-model state describing "what the sub-agents are doing
/// right now". Populated only when `ChatAppearance.subAgentActivityStyle`
/// is `.pill` — the warm-dark default. In `.bubbles` mode it stays empty
/// and the UI falls back to the legacy bubble per event.
///
/// The model is a small stack of `Frame`s because sub-agents can recurse
/// (a triage agent invokes a specialist that itself invokes a tool-using
/// helper). The outermost frame's `bracketStartedAt` drives the
/// "Consulted X · 4s" caption that ends up on the collapsed history row.
public struct SubAgentActivityState: Equatable {
    /// One in-flight sub-agent invocation. Pushed on `sub_agent.start`,
    /// updated by intermediate `assistant.delta` / `assistant.message`
    /// / `tool.call` events that arrive while it's on top of the stack,
    /// and popped on the matching `sub_agent.end`.
    public struct Frame: Equatable, Identifiable {
        public let id: String
        public let agentName: String
        public let subAgentKey: String?
        public let startedAt: Date
        /// Latest snippet of streamed text from the sub-agent. The pill
        /// view head-truncates this so it reads as a live ticker tail
        /// rather than a wall of accumulating prose.
        public var liveText: String
        /// Most recent tool the sub-agent invoked, surfaced in the pill
        /// as a subtle "· running <tool>" caption. Cleared when a new
        /// delta arrives so the pill prioritises the live narration.
        public var currentToolName: String?

        public init(
            id: String = UUID().uuidString,
            agentName: String,
            subAgentKey: String? = nil,
            startedAt: Date = Date(),
            liveText: String = "",
            currentToolName: String? = nil
        ) {
            self.id = id
            self.agentName = agentName
            self.subAgentKey = subAgentKey
            self.startedAt = startedAt
            self.liveText = liveText
            self.currentToolName = currentToolName
        }
    }

    /// Stack of in-flight sub-agent invocations, outermost first.
    public var frames: [Frame]
    /// When the *outermost* frame was pushed. Captured separately from
    /// `frames.first?.startedAt` so the counter keeps ticking accurately
    /// across nested push/pop activity within a single bracket.
    public var bracketStartedAt: Date?

    public init(frames: [Frame] = [], bracketStartedAt: Date? = nil) {
        self.frames = frames
        self.bracketStartedAt = bracketStartedAt
    }

    /// True while at least one sub-agent is in flight. The UI uses this
    /// to decide whether to render the activity pill in place of the
    /// generic "Thinking..." spinner.
    public var isActive: Bool { !frames.isEmpty }

    /// The frame currently receiving deltas / tool events (top of stack).
    public var topFrame: Frame? { frames.last }

    /// Push a new frame onto the stack, starting a bracket if the stack
    /// was previously empty so the counter measures the whole bracket
    /// rather than just the innermost call.
    public mutating func push(_ frame: Frame) {
        if frames.isEmpty {
            bracketStartedAt = frame.startedAt
        }
        frames.append(frame)
    }

    /// Pop the top frame. Returns it for callers that need the agent
    /// name / duration to emit a collapsed history row. When the stack
    /// drains to empty the `bracketStartedAt` marker is cleared so the
    /// next bracket starts a fresh counter.
    @discardableResult
    public mutating func pop() -> Frame? {
        guard !frames.isEmpty else { return nil }
        let popped = frames.removeLast()
        if frames.isEmpty {
            bracketStartedAt = nil
        }
        return popped
    }

    /// Append streamed text to the top frame's live ticker. No-op if the
    /// stack is empty — callers gate on `isActive` before diverting.
    public mutating func appendDelta(_ text: String) {
        guard !frames.isEmpty else { return }
        frames[frames.count - 1].liveText.append(text)
        frames[frames.count - 1].currentToolName = nil
    }

    /// Replace the top frame's live ticker text with the authoritative
    /// final message content. Used when `assistant.message` lands while
    /// a sub-agent frame is on top of the stack.
    public mutating func setFinal(_ text: String) {
        guard !frames.isEmpty else { return }
        frames[frames.count - 1].liveText = text
        frames[frames.count - 1].currentToolName = nil
    }

    /// Record the most recent tool the sub-agent invoked so the pill
    /// can show "· running <tool>" until the next delta arrives.
    public mutating func noteToolCall(_ toolName: String) {
        guard !frames.isEmpty else { return }
        frames[frames.count - 1].currentToolName = toolName
    }
}
