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

    // MARK: - Typography

    /// Font design used for the empty-state greeting headline.
    /// `.serif` gives the warm editorial look the baseline ships with;
    /// `.default` falls back to the system font.
    public var greetingFontDesign: Font.Design
    /// Greeting headline point size.
    public var greetingFontSize: CGFloat

    // MARK: - Layout knobs

    /// Composer layout variant.
    public var composerStyle: ComposerStyle
    /// Brand mark shown above the greeting text.
    public var brandMark: BrandMark
    /// Corner radius applied to the composer card.
    public var composerCornerRadius: CGFloat
    /// Corner radius applied to message bubbles.
    public var bubbleCornerRadius: CGFloat
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
        greetingFontDesign: Font.Design = .serif,
        greetingFontSize: CGFloat = 32,
        composerStyle: ComposerStyle = .anthropic,
        brandMark: BrandMark = .none,
        composerCornerRadius: CGFloat = 28,
        bubbleCornerRadius: CGFloat = 18,
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
        self.greetingFontDesign = greetingFontDesign
        self.greetingFontSize = greetingFontSize
        self.composerStyle = composerStyle
        self.brandMark = brandMark
        self.composerCornerRadius = composerCornerRadius
        self.bubbleCornerRadius = bubbleCornerRadius
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
}
