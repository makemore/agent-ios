import SwiftUI
import AgentClient

/// Thin banner that reports the current conversation's token usage and
/// (when the active model has a known `context_window`) its progress
/// against the model's limit.
///
/// Fully server-driven. The banner reads from
/// `ChatViewModel.contextTokens` + `contextWindow` + `contextModelId`,
/// all three of which the runtime populates via `context.usage` SSE
/// events (one per LLM call). No client-side estimation — if the
/// runtime hasn't shipped usage yet the banner stays hidden.
struct ContextUsageBanner: View {
    let totalTokens: Int
    let contextWindow: Int?
    let modelId: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(usageColor)
            Text(countText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(usageColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.05))
                    if let progress = progress, progress > 0 {
                        Rectangle()
                            .fill(usageColor.opacity(0.35))
                            .frame(width: max(2, proxy.size.width * progress))
                            .animation(.easeInOut(duration: 0.18), value: progress)
                    }
                }
            }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var progress: Double? {
        guard let window = contextWindow, window > 0 else { return nil }
        return min(1.0, Double(totalTokens) / Double(window))
    }

    private var countText: String {
        if let window = contextWindow, let pct = progress {
            return "\(formatted(totalTokens)) / \(formatted(window)) (\(Int((pct * 100).rounded()))%)"
        }
        // No window known (runtime didn't ship a `context_window` for
        // the active model) — just show the count. The progress bar
        // background is still rendered but stays empty.
        return "\(formatted(totalTokens)) tokens"
    }

    private var usageColor: Color {
        guard let progress else { return .secondary }
        switch progress {
        case ..<0.6: return .secondary
        case ..<0.85: return .orange
        default: return .red
        }
    }

    private var accessibilityLabel: String {
        if let window = contextWindow, let pct = progress {
            return "Context usage \(totalTokens) of \(window) tokens, \(Int((pct * 100).rounded())) percent"
        }
        return "Context usage \(totalTokens) tokens"
    }

    /// Compact token count for the banner. Preserves tenths of a k
    /// across the whole range so `123_456` renders as `123.4k`, not
    /// `123k` — that precision matters for the "(%)" the user sees
    /// next to it, which is sensitive to the underlying number.
    private func formatted(_ n: Int) -> String {
        if n >= 1_000 {
            let k = Double(n) / 1000.0
            let rounded = (k * 10).rounded() / 10
            if rounded.truncatingRemainder(dividingBy: 1) == 0 {
                return "\(Int(rounded))k"
            }
            return String(format: "%.1fk", rounded)
        }
        return "\(n)"
    }
}
