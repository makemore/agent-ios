import SwiftUI
import AgentClient

/// Centered empty-state for the chat widget. Renders the optional
/// brand mark chosen by `ChatAppearance.brandMark` (none by default)
/// above a serif greeting line driven by
/// `ChatGreetingConfig.currentLine()`.
///
/// Reads everything from the supplied config — no environment
/// dependencies — so host apps embedding `MessageListView` directly
/// get the same look without extra plumbing.
public struct GreetingView: View {
    let config: ChatWidgetConfig
    /// Hour-of-day override for tests / previews. `nil` reads the
    /// current device time.
    var hourOverride: Int?

    public init(config: ChatWidgetConfig, hourOverride: Int? = nil) {
        self.config = config
        self.hourOverride = hourOverride
    }

    public var body: some View {
        VStack(spacing: 24) {
            brandMark
            Text(greetingLine)
                .font(.system(
                    size: config.appearance.greetingFontSize,
                    weight: .regular,
                    design: config.appearance.greetingFontDesign
                ))
                .foregroundColor(config.appearance.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.empty.greeting")
    }

    private var greetingLine: String {
        if let hour = hourOverride {
            return config.greeting.line(forHour: hour)
        }
        return config.greeting.currentLine()
    }

    @ViewBuilder
    private var brandMark: some View {
        switch config.appearance.brandMark {
        case .systemIcon(let name):
            Image(systemName: name)
                .font(.system(size: 44, weight: .regular))
                .foregroundColor(config.appearance.accent)
        case .none:
            EmptyView()
        }
    }
}

#if DEBUG
struct GreetingView_Previews: PreviewProvider {
    static var previews: some View {
        let cfg: ChatWidgetConfig = {
            var c = ChatWidgetConfig()
            c.greeting.enabled = true
            c.greeting.userName = "Chris"
            return c
        }()
        return GreetingView(config: cfg, hourOverride: 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(cfg.appearance.background)
            .previewLayout(.sizeThatFits)
    }
}
#endif
