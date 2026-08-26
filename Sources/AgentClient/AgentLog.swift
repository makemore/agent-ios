import Foundation

/// Tracing categories. Every one is off unless explicitly switched on —
/// see ``AgentLog``.
public enum LogCategory: String, CaseIterable, Sendable {
    /// Run creation, cancellation, conversation and model loading.
    case network
    /// Per-event SSE traffic: connect, each event, stream completion.
    case sse
    /// Message assembly — content blocks, memory updates, terminal events.
    case chat
    /// TTS playback and the voice pipeline.
    case voice
    /// Microphone, speech recognition and composer input state.
    case input
    /// View lifecycle and startup ordering.
    case lifecycle
}

/// Console logging for the agent client.
///
/// The console is silent by default. Anything that appears is a genuine
/// problem worth acting on — if a line is neither a problem nor something
/// you switched on deliberately, it should be deleted rather than lived
/// with.
///
/// Tracing is opt-in per category and meant to be turned on for a single
/// investigation and off again afterwards. Set `AGENT_LOG` in the
/// scheme's environment variables (Product → Scheme → Edit Scheme → Run →
/// Arguments), which is a tickbox rather than a recompile:
///
///     AGENT_LOG=sse             one category
///     AGENT_LOG=sse,network     several
///     AGENT_LOG=all             everything
///
/// Read once at first use, so toggling it takes a relaunch.
public enum AgentLog {

    /// Categories switched on for this launch.
    public static let enabled: Set<LogCategory> = {
        guard let raw = ProcessInfo.processInfo.environment["AGENT_LOG"],
              !raw.isEmpty else { return [] }
        if raw.lowercased() == "all" { return Set(LogCategory.allCases) }
        return Set(
            raw.split(separator: ",")
               .compactMap {
                   LogCategory(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased())
               }
        )
    }()

    public static func isEnabled(_ category: LogCategory) -> Bool {
        enabled.contains(category)
    }

    /// Category-gated tracing. Silent unless ``category`` is switched on.
    ///
    /// The message is an autoclosure so interpolation cost is not paid
    /// when the category is off — which is almost always.
    @inline(__always)
    public static func debug(_ category: LogCategory,
                             _ message: @autoclosure () -> String) {
        guard enabled.contains(category) else { return }
        print(message())
    }

    /// A genuine problem: something failed, or is about to behave in a way
    /// the caller would not expect. Always printed.
    @inline(__always)
    public static func error(_ message: @autoclosure () -> String) {
        print("⚠️ \(message())")
    }
}
