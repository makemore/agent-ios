import SwiftUI
import AgentClient

/// Quiet activity indicator shown in the message list while a sub-agent
/// bracket is in flight. Replaces the generic "Thinking..." spinner in
/// pill mode (`ChatAppearance.subAgentActivityStyle == .pill`) so the
/// user sees *who* is thinking and a hint of *what* they're saying,
/// without each delta producing its own speech bubble.
///
/// Layout (compact card, up to 3 lines of live ticker text):
///     ✨ <agent name> · <tool?>                       <Xs>
///        <live text tail line 1>
///        <live text tail line 2>
///        <live text tail line 3>
/// where the live-text tail truncates from the head as more content
/// streams in, giving a ticker-style "scrolling past" feel — older
/// lines disappear off the top while newer text appears at the bottom.
struct SubAgentActivityPillView: View {
    let activity: SubAgentActivityState
    let appearance: ChatAppearance

    /// Drives the elapsed-seconds counter on the right of the pill.
    /// SwiftUI re-runs the body every tick while the view is on screen.
    @State private var now: Date = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        guard let frame = activity.topFrame else {
            return AnyView(EmptyView())
        }
        let elapsed = max(0, Int(now.timeIntervalSince(
            activity.bracketStartedAt ?? frame.startedAt
        )))

        return AnyView(
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(appearance.accent)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(frame.agentName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(appearance.textPrimary)
                        if let tool = frame.currentToolName {
                            Text("· \(tool)")
                                .font(.system(size: 12))
                                .foregroundColor(appearance.textSecondary)
                        }
                    }
                    Text(tickerText(from: frame.liveText))
                        .font(.system(size: 12))
                        .foregroundColor(appearance.textSecondary)
                        .lineLimit(Self.tickerLineLimit, reservesSpace: true)
                        .truncationMode(.head)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .animation(.linear(duration: 0.1), value: frame.liveText)
                }

                Spacer(minLength: 8)

                Text("\(elapsed)s")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(appearance.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(appearance.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(appearance.divider, lineWidth: 0.5)
            )
            .onReceive(timer) { now = $0 }
            .accessibilityLabel("\(frame.agentName) thinking, \(elapsed) seconds")
        )
    }

    /// Number of live-ticker lines the pill reserves space for. Three
    /// gives the affordance enough breathing room to feel "alive" while
    /// streaming without dominating the chat history.
    private static let tickerLineLimit = 3

    /// Take only the trailing slice of the live text so the visual feel
    /// is "tail of a scrolling ticker" rather than "growing paragraph".
    /// `truncationMode(.head)` combined with `lineLimit(3)` ellipsises
    /// whatever doesn't fit — combined effect is a steady stream of
    /// words appearing at the bottom while older lines fall off the
    /// top. `maxChars` is sized so there's always enough trailing text
    /// to fill the three reserved lines once the sub-agent gets going.
    private func tickerText(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "…" }
        let maxChars = 600
        if trimmed.count <= maxChars { return trimmed }
        let start = trimmed.index(trimmed.endIndex, offsetBy: -maxChars)
        return String(trimmed[start...])
    }
}

#if DEBUG
struct SubAgentActivityPillView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            SubAgentActivityPillView(
                activity: SubAgentActivityState(
                    frames: [
                        SubAgentActivityState.Frame(
                            agentName: "State Assessor",
                            startedAt: Date().addingTimeInterval(-12),
                            liveText: "…considering the framing of the question and looking at recent context, the user seems to be exploring",
                            currentToolName: nil
                        )
                    ],
                    bracketStartedAt: Date().addingTimeInterval(-12)
                ),
                appearance: ChatAppearance()
            )
            SubAgentActivityPillView(
                activity: SubAgentActivityState(
                    frames: [
                        SubAgentActivityState.Frame(
                            agentName: "Boundary Guardian",
                            startedAt: Date().addingTimeInterval(-3),
                            liveText: "",
                            currentToolName: "search_safety_policy"
                        )
                    ],
                    bracketStartedAt: Date().addingTimeInterval(-3)
                ),
                appearance: ChatAppearance()
            )
        }
        .padding()
        .background(ChatAppearance().background)
        .previewDisplayName("Pill — streaming + tool")
    }
}
#endif
