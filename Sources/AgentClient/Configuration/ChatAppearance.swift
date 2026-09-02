import Foundation
import SwiftUI

/// Visual tokens for the chat widget. Defaults reproduce the warm-dark
/// baseline (warm near-black surfaces, off-white text, coral accent).
/// Host apps override individual tokens to re-skin the widget without
/// having to fork the views — any value left at its default tracks
/// future library updates.
///
/// Pure data; no SwiftUI views live here. View code reads these via
/// `ChatWidgetConfig.appearance`.
public struct ChatAppearance {
    /// Composer layout. `.anthropic` is the rounded card with a model
    /// pill and a circular voice button; `.classic` is the original
    /// single-row pill input. Library default is `.anthropic`.
    public enum ComposerStyle {
        case classic
        case anthropic
    }

    /// Empty-state brand mark. `.none` hides the mark and shows the
    /// greeting text alone; `.systemIcon(name:)` renders an SF Symbol
    /// above the greeting so hosts can drop in their own glyph without
    /// shipping a custom view.
    public enum BrandMark: Equatable {
        case none
        case systemIcon(name: String)
    }

    /// How to render a sub-agent's activity while it is streaming.
    ///
    /// - `.pill`: hide the per-event "🔗 Delegating…" / "✓ completed" /
    ///   sub-agent streaming bubbles. Instead show a single quiet pill
    ///   below the message list with the current sub-agent's name and a
    ///   head-truncated tail of its latest output, then collapse to a
    ///   "Consulted <agent> · Xs" row in the history once the bracket
    ///   ends. The parent orchestrator's own final reply renders below
    ///   it as the actual answer. This is the warm-dark default and
    ///   keeps complex multi-specialist chains feeling calm and on-task.
    ///
    /// - `.bubbles`: original behaviour — every `sub_agent.start` /
    ///   `assistant.delta` / `assistant.message` / `sub_agent.end`
    ///   appears as a separate bubble or system row, and the parent's
    ///   re-stream of the sub-agent's answer is suppressed as an echo.
    ///   Kept for hosts on the classic appearance.
    public enum SubAgentActivityStyle {
        case pill
        case bubbles
    }

    /// How an assistant reply is drawn in the transcript.
    ///
    /// - `.bubble`: the reply sits in its own filled, rounded bubble,
    ///   mirroring the user's side of the conversation.
    /// - `.plain`: no fill, no bubble padding — the reply is just text
    ///   on the chat background, so the agent reads as the page itself
    ///   rather than as another participant posting messages. The
    ///   per-message avatar is suppressed in this style too; the
    ///   presence orb above the list already carries agent identity.
    public enum AssistantMessageStyle {
        case bubble
        case plain
    }

    // MARK: - Surfaces

    /// Root background colour behind the whole widget.
    public var background: Color
    /// Card / composer surface colour (slightly lighter than background).
    public var surface: Color
    /// Elevated surface colour used for the assistant message bubble.
    public var surfaceElevated: Color
    /// Divider hairline colour.
    public var divider: Color

    // MARK: - Text

    /// Primary text colour — body copy, assistant messages, greeting.
    public var textPrimary: Color
    /// Muted text colour — placeholders, captions, secondary metadata.
    public var textSecondary: Color
    /// Text colour rendered on top of `accent` (user message bubble).
    public var textOnAccent: Color

    // MARK: - Accent

    /// Brand accent — coral by default. Also used as the primary
    /// "send" button colour when `ChatWidgetConfig.primaryColor` is
    /// not customised by the host.
    public var accent: Color

    /// Background colour for the user's own message bubbles. When `nil`
    /// the transcript falls back to `ChatWidgetConfig.primaryColor`,
    /// preserving the prior (host-customisable) behaviour; set a value
    /// to theme the user side of the transcript independently.
    public var userBubble: Color?

    /// Text colour inside the user's own message bubbles. When `nil`
    /// the transcript falls back to `textOnAccent`, which is correct
    /// while the user bubble *is* the accent fill. Set this when
    /// `userBubble` is themed independently of the accent, so bubble
    /// text and on-accent chrome (send button) can differ.
    public var userBubbleText: Color?

    /// Background colour for assistant message bubbles. When `nil` the
    /// transcript falls back to the adaptive system grey it used before
    /// the warm-dark redesign, so `.classic` is unchanged. The default
    /// initializer supplies the warm tone for the anthropic baseline.
    public var assistantBubble: Color?

    /// Background colour for tool / system message bubbles. When `nil`
    /// the transcript falls back to the adaptive system grey, keeping
    /// `.classic` unchanged. The default initializer supplies the warm
    /// tone for the anthropic baseline.
    public var systemBubble: Color?

    /// Colour for markdown links and `requiredAction` labels in the
    /// transcript. When `nil` the transcript falls back to
    /// `ChatWidgetConfig.primaryColor`, matching the prior behaviour;
    /// set a value to re-tint links independently.
    public var link: Color?

    // MARK: - Typography

    /// Font design used for the empty-state greeting headline.
    /// `.serif` gives the warm editorial look the baseline ships with;
    /// `.default` falls back to the system font.
    public var greetingFontDesign: Font.Design
    /// Greeting headline point size.
    public var greetingFontSize: CGFloat

    /// Text style for the user's own messages. Separate from
    /// `messageTextStyle` because the two sides are set in different
    /// faces — a sans bubble and serif prose at the same nominal size
    /// do not read as the same size — and because tool/system rows
    /// deliberately stay at `.body` regardless.
    public var userTextStyle: Font.TextStyle
    /// Base text style for assistant prose. Everything else in a reply
    /// is sized relative to it — headings step up from here, so raising
    /// this raises the whole reply coherently. Kept as a `TextStyle`
    /// rather than a point size so Dynamic Type still scales it.
    public var messageTextStyle: Font.TextStyle
    /// Font design for assistant prose in the transcript — body copy,
    /// headings and list items alike. `.serif` gives the editorial look
    /// where the agent reads as the page rather than as a chat partner;
    /// `.default` keeps the system sans. Deliberately does *not* touch
    /// user bubbles or UI chrome: those stay sans so the two voices in
    /// the transcript are typographically distinct.
    public var messageFontDesign: Font.Design
    /// Extra leading between lines of assistant prose. Long-form serif
    /// text needs more air than the system default gives it.
    public var messageLineSpacing: CGFloat
    /// Vertical gap between markdown blocks in an assistant reply —
    /// paragraph to paragraph, paragraph to heading, heading to list.
    public var messageBlockSpacing: CGFloat

    // MARK: - Layout knobs

    /// Composer layout variant.
    public var composerStyle: ComposerStyle
    /// Brand mark shown above the greeting text.
    public var brandMark: BrandMark
    /// Corner radius applied to the composer card.
    public var composerCornerRadius: CGFloat
    /// Corner radius applied to message bubbles.
    public var bubbleCornerRadius: CGFloat

    /// Whether assistant replies are drawn as bubbles or as plain text
    /// on the background. Library default is `.bubble`.
    public var assistantMessageStyle: AssistantMessageStyle
    /// Label rendered in the model pill on the anthropic composer.
    /// When `nil` the pill is hidden. Host apps drive this from their
    /// currently selected model so the composer surfaces what's active.
    public var modelPillLabel: String?
    /// How sub-agent activity surfaces in the UI. Library default is
    /// `.pill` so multi-specialist chains stay calm; the classic
    /// appearance opts back into `.bubbles` for the old behaviour.
    public var subAgentActivityStyle: SubAgentActivityStyle

    // MARK: - Init

    public init(
        background: Color = Color(hex: "#262624"),
        surface: Color = Color(hex: "#2F2F2D"),
        surfaceElevated: Color = Color(hex: "#3A3A37"),
        divider: Color = Color.white.opacity(0.08),
        textPrimary: Color = Color(hex: "#F5F1E8"),
        textSecondary: Color = Color(hex: "#A8A29A"),
        textOnAccent: Color = Color.white,
        accent: Color = Color(hex: "#D97757"),
        userBubble: Color? = nil,
        userBubbleText: Color? = nil,
        assistantBubble: Color? = Color(hex: "#3A3A37"),
        systemBubble: Color? = Color(hex: "#2F2F2D"),
        link: Color? = nil,
        greetingFontDesign: Font.Design = .serif,
        greetingFontSize: CGFloat = 32,
        userTextStyle: Font.TextStyle = .body,
        messageTextStyle: Font.TextStyle = .body,
        messageFontDesign: Font.Design = .default,
        messageLineSpacing: CGFloat = 0,
        messageBlockSpacing: CGFloat = 6,
        composerStyle: ComposerStyle = .anthropic,
        brandMark: BrandMark = .none,
        composerCornerRadius: CGFloat = 28,
        bubbleCornerRadius: CGFloat = 18,
        assistantMessageStyle: AssistantMessageStyle = .bubble,
        modelPillLabel: String? = nil,
        subAgentActivityStyle: SubAgentActivityStyle = .pill
    ) {
        self.background = background
        self.surface = surface
        self.surfaceElevated = surfaceElevated
        self.divider = divider
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textOnAccent = textOnAccent
        self.accent = accent
        self.userBubble = userBubble
        self.userBubbleText = userBubbleText
        self.assistantBubble = assistantBubble
        self.systemBubble = systemBubble
        self.link = link
        self.greetingFontDesign = greetingFontDesign
        self.greetingFontSize = greetingFontSize
        self.userTextStyle = userTextStyle
        self.messageTextStyle = messageTextStyle
        self.messageFontDesign = messageFontDesign
        self.messageLineSpacing = messageLineSpacing
        self.messageBlockSpacing = messageBlockSpacing
        self.composerStyle = composerStyle
        self.brandMark = brandMark
        self.composerCornerRadius = composerCornerRadius
        self.bubbleCornerRadius = bubbleCornerRadius
        self.assistantMessageStyle = assistantMessageStyle
        self.modelPillLabel = modelPillLabel
        self.subAgentActivityStyle = subAgentActivityStyle
    }

    /// The original library look prior to the warm-dark redesign —
    /// classic composer, no brand mark, system text colours. Host apps
    /// that want the pre-0.8 appearance can opt out with one line:
    /// `config.appearance = .classic`.
    public static let classic: ChatAppearance = {
        var a = ChatAppearance(
            background: Color.clear,
            surface: Color.clear,
            surfaceElevated: Color.clear,
            divider: Color.gray.opacity(0.2),
            textPrimary: Color.primary,
            textSecondary: Color.secondary,
            textOnAccent: Color.white,
            accent: Color(hex: "#4a6b8e"),
            assistantBubble: nil,
            systemBubble: nil,
            greetingFontDesign: .default,
            greetingFontSize: 17,
            composerStyle: .classic,
            brandMark: .systemIcon(name: "bubble.left.and.bubble.right"),
            composerCornerRadius: 20,
            bubbleCornerRadius: 16,
            subAgentActivityStyle: .bubbles
        )
        // No-op — keeps `var` for symmetry if we add post-init tweaks.
        return a
    }()

    /// Warm-dark look — the new library default. Equivalent to calling
    /// `ChatAppearance()` with no arguments; exposed as a named
    /// constant for clarity when assigning at the call site.
    public static let anthropic: ChatAppearance = ChatAppearance()

    /// Resilient Minds house style — a pinned snapshot derived from the
    /// warm-dark anthropic look. Intentional departures from that base:
    ///
    /// • Brand gold (`#D8A762`) replaces the coral accent, so the send
    ///   button and accent chrome read as RM rather than Claude coral.
    /// • `textOnAccent` is the charcoal background rather than white.
    ///   Gold is a light accent: white on it measures ~2.2:1, which
    ///   fails WCAG for both body text and UI components, so on-gold
    ///   chrome takes charcoal (~7.7:1).
    /// • The transcript is asymmetric on purpose: user turns are grey
    ///   bubbles with white text, and assistant replies are plain text
    ///   on the background rather than bubbles from a second
    ///   participant. Gold is reserved for chrome — it no longer fills
    ///   the user bubble — so `userBubbleText` carries white
    ///   independently of `textOnAccent`.
    /// • Assistant prose is set in the system serif with editorial
    ///   leading, which is what makes a bubble-less transcript read as
    ///   a page rather than unstyled chat text. Sizes stay on
    ///   `Font.TextStyle` so Dynamic Type still scales everything.
    ///
    /// Every token — including those matching today's defaults — is
    /// passed explicitly, so future changes to the initializer defaults
    /// can never alter this preset.
    public static let resilientGold: ChatAppearance = ChatAppearance(
        background: Color(hex: "#262624"),
        surface: Color(hex: "#2F2F2D"),
        surfaceElevated: Color(hex: "#3A3A37"),
        divider: Color.white.opacity(0.08),
        textPrimary: Color(red: 0.961, green: 0.961, blue: 0.965),     // #F5F5F7
        textSecondary: Color(red: 0.631, green: 0.631, blue: 0.651),   // #A1A1A6
        textOnAccent: Color(hex: "#262624"),
        accent: Color(hex: "#D8A762"),
        userBubble: Color(hex: "#3A3A37"),
        userBubbleText: Color.white,
        assistantBubble: Color(hex: "#3A3A37"),
        systemBubble: Color(hex: "#2F2F2D"),
        link: nil,
        greetingFontDesign: .serif,
        greetingFontSize: 32,
        userTextStyle: .body,
        messageTextStyle: .body,
        messageFontDesign: .serif,
        messageLineSpacing: 6,
        messageBlockSpacing: 16,
        composerStyle: .anthropic,
        brandMark: .none,
        composerCornerRadius: 28,
        bubbleCornerRadius: 18,
        assistantMessageStyle: .plain,
        modelPillLabel: nil,
        subAgentActivityStyle: .pill
    )

    /// Generic, unbranded starting point for new host apps — the
    /// recommended base to derive a house style from. Keeps the
    /// anthropic layout (rounded composer card, current radii and
    /// spacing) over system-adaptive colours: text follows
    /// `Color.primary` / `Color.secondary`, the accent tracks the
    /// host's `Color.accentColor`, bubbles fall back to the adaptive
    /// system greys, and no brand colour ships anywhere.
    ///
    /// Every token — including those matching today's defaults — is
    /// passed explicitly, so future changes to the initializer defaults
    /// can never alter this preset.
    public static let neutral: ChatAppearance = ChatAppearance(
        background: Color.clear,
        surface: Color.gray.opacity(0.1),
        surfaceElevated: Color.gray.opacity(0.15),
        divider: Color.gray.opacity(0.2),
        textPrimary: Color.primary,
        textSecondary: Color.secondary,
        textOnAccent: Color.white,
        accent: Color.accentColor,
        userBubble: nil,
        userBubbleText: nil,
        assistantBubble: nil,
        systemBubble: nil,
        link: nil,
        greetingFontDesign: .default,
        greetingFontSize: 32,
        userTextStyle: .body,
        messageTextStyle: .body,
        messageFontDesign: .default,
        messageLineSpacing: 0,
        messageBlockSpacing: 6,
        composerStyle: .anthropic,
        brandMark: .none,
        composerCornerRadius: 28,
        bubbleCornerRadius: 18,
        assistantMessageStyle: .bubble,
        modelPillLabel: nil,
        subAgentActivityStyle: .pill
    )

    /// Entry point for new integrations. Currently `.neutral`. May be
    /// re-pointed to a newer preset in future releases — hosts that
    /// need a stable look should pin a named preset (`.neutral`,
    /// `.anthropic`, `.classic`, ...) instead.
    public static var recommended: ChatAppearance { neutral }
}
