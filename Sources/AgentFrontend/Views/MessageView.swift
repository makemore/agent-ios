import SwiftUI
import AgentClient
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Individual message view
public struct MessageView: View {
    let message: Message
    let config: ChatWidgetConfig
    let showDebug: Bool
    let onRetry: (() -> Void)?
    let onEdit: (() -> Void)?
    /// Speak this message aloud. Supplied by the parent list only when
    /// the host enabled TTS (`ChatWidgetConfig.enableTTS`); `nil` hides
    /// the Play affordances entirely. Defaulted so preview/harness call
    /// sites keep compiling.
    var onSpeak: (() -> Void)? = nil
    /// Whether THIS message is the one currently being read aloud. Flips
    /// the speaker affordance into a stop button; ``onSpeak`` then stops
    /// rather than replays. Defaulted so preview/harness call sites keep
    /// compiling.
    var isSpeaking: Bool = false
    /// Fired *after* this message's text has been put on the pasteboard,
    /// by either the actions-row button or the context menu. Purely a
    /// notification so the host can confirm the copy — the copy itself
    /// happens here.
    var onCopy: (() -> Void)? = nil
    /// When `true` and this is an assistant text/tool/system message,
    /// render the S'Ai presence orb as a small avatar at the leading
    /// edge of the row. The parent list decides per-message whether
    /// to paint an avatar (typically gated by `config.showPresenceOrb`).
    let showAgentAvatar: Bool
    /// Drives the avatar's halo glow. Only the latest assistant
    /// message should receive `true` so the scrollback doesn't bloom
    /// every row when the agent speaks.
    let agentAvatarSpeaking: Bool

    var onBlockAction: ((BlockAction) -> Void)?

    private var isUser: Bool { message.role == .user }
    private var isSystem: Bool { message.role == .system }
    private var isToolMessage: Bool { message.type == .toolCall || message.type == .toolResult }
    private var isContentBlocks: Bool { message.type == .contentBlocks }
    /// Visual tokens for the transcript. Sourced from the host's
    /// `ChatWidgetConfig.appearance` so bubble colours, text colours,
    /// link tint, and corner radius all track the configured theme.
    private var appearance: ChatAppearance { config.appearance }
    /// Avatar gating mirrors the bubble visibility — we only paint the
    /// orb next to an actual assistant text bubble, not next to tool /
    /// system / content-block / thought rows (each of which has its
    /// own visual treatment that already conveys "this isn't a chat
    /// reply from the agent").
    private var shouldShowAvatar: Bool {
        showAgentAvatar
            && !isUser
            && !isSystem
            && !isToolMessage
            && !isContentBlocks
            && !isThoughtRow
    }
    /// Fixed avatar size. 32pt strikes the balance between brand
    /// presence (the orb's swirl is legible) and bubble width
    /// (still leaves enough room on phones). The halo glow on the
    /// latest message is what carries the speaking signal.
    private var avatarSize: CGFloat { 32 }
    /// `true` when this message is the collapsed pill-mode summary row.
    /// In `.bubbles` mode the same `.subAgentEnd` type still flows
    /// through the standard system-bubble path so legacy hosts see the
    /// "✓ Agent completed" row they had before.
    private var isThoughtRow: Bool {
        message.type == .subAgentEnd
            && config.appearance.subAgentActivityStyle == .pill
    }

    @ViewBuilder
    private var thoughtRow: some View {
        let appearance = config.appearance
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundColor(appearance.textSecondary)
            Text(message.content)
                .font(.system(size: 12))
                .foregroundColor(appearance.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.content)
    }

    public var body: some View {
        // Content blocks: render as standalone rich content
        if isContentBlocks, let blocks = message.metadata?.contentBlocks, !blocks.isEmpty {
            let _: Void = {
                #if DEBUG
                AgentLog.debug(.chat, "[MessageView] rendering ContentBlockRenderer with \(blocks.count) block(s)")
                #endif
            }()
            ContentBlockRenderer(blocks: blocks, config: config, onAction: onBlockAction)
                .onAppear { HangDiagnostics.mark("ContentBlockRenderer appear") }
                .padding(.horizontal, 12)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(isUser ? "chat.message.user" : "chat.message.assistant")
        } else if isThoughtRow {
            // Collapsed "Consulted <agent> · 4s" row left behind by
            // pill-mode after a sub-agent bracket closes. Centered and
            // muted so it reads as historical metadata, not a message.
            thoughtRow
        } else {
        HStack(alignment: .top, spacing: 3) {
            if isUser {
                Spacer(minLength: 40)
            } else if shouldShowAvatar {
                // Per-message S'Ai avatar. Sits at the bubble's leading
                // edge so the assistant identity is anchored in the
                // scrollback. Compact mode keeps the silhouette stable;
                // only the latest message receives `agentAvatarSpeaking`
                // so just that one glows when audio is in flight.
                PresenceOrbView(
                    isSpeaking: agentAvatarSpeaking,
                    baseSize: avatarSize,
                    compact: true
                )
                .accessibilityHidden(true)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                // Message bubble with long-press copy
                messageBubble
                    .contextMenu {
                        Button {
                            copyMessage()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }

                        if let onRetry = onRetry {
                            Button {
                                onRetry()
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                        }

                        if let onEdit = onEdit {
                            Button {
                                onEdit()
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                        }

                        if let onSpeak = onSpeak {
                            Button {
                                onSpeak()
                            } label: {
                                Label(isSpeaking ? "Stop" : "Play",
                                      systemImage: isSpeaking ? "stop.fill" : "speaker.wave.2")
                            }
                        }
                    }

                // Actions row
                if !isSystem && !isToolMessage {
                    actionsRow
                }
            }

            if !isUser { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isUser ? "chat.message.user" : "chat.message.assistant")
        } // end else (non-content-blocks)
    }

    @ViewBuilder
    private var messageBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tool/system message header
            if isToolMessage || isSystem {
                HStack(spacing: 4) {
                    messageIcon
                    if let toolName = message.metadata?.toolName {
                        Text(toolName)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                }
            }
            
            // Content — markdown for assistant messages, plain text for user/system.
            // `.textSelection(.enabled)` is applied per-bubble so users can
            // long-press and drag the selection handles to pick a *range*
            // (not the whole message) and copy just that substring. We do
            // NOT apply selection at the widget level (the host previously
            // did) because that turns the whole chat into one big selectable
            // region — pressing near the composer would select through the
            // message list and the input bar.
            if !isUser && !isSystem && !isToolMessage && config.enableMarkdown {
                MarkdownTextView(content: message.content,
                                 foregroundColor: messageTextColor,
                                 linkColor: linkColor,
                                 cacheKey: message.id)
                    .textSelection(.enabled)
            } else {
                Text(message.content)
                    .font(.body)
                    .foregroundColor(messageTextColor)
                    .textSelection(.enabled)
            }

            if message.type == .requiredAction, let label = message.metadata?.actionLabel {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(linkColor)
                    .padding(.top, 2)
            }
            
            // Debug info
            if showDebug, let metadata = message.metadata {
                debugInfo(metadata)
            }
            
            // File attachments
            if let files = message.files, !files.isEmpty {
                fileAttachments(files)
            }
        }
        .padding(12)
        .background(bubbleBackground)
        .cornerRadius(appearance.bubbleCornerRadius)
    }
    
    @ViewBuilder
    private var messageIcon: some View {
        switch message.type {
        case .toolCall:
            Image(systemName: "wrench.fill")
                .foregroundColor(.orange)
        case .toolResult:
            Image(systemName: message.content.contains("❌") ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundColor(message.content.contains("❌") ? .red : .green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .foregroundColor(.orange)
        case .requiredAction:
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundColor(.blue)
        case .subAgentStart, .subAgentEnd, .agentContext:
            Image(systemName: "link")
                .foregroundColor(.blue)
        default:
            EmptyView()
        }
    }
    
    private var messageTextColor: Color {
        if isUser {
            return appearance.textOnAccent
        }
        return appearance.textPrimary
    }

    /// Link / `requiredAction` tint. Falls back to the host's
    /// `primaryColor` when the appearance leaves `link` unset, matching
    /// the pre-token behaviour.
    private var linkColor: Color {
        appearance.link ?? config.primaryColor
    }

    private var bubbleBackground: Color {
        if isUser {
            return appearance.userBubble ?? config.primaryColor
        }
        if isToolMessage || isSystem {
            return appearance.systemBubble ?? PlatformColors.systemGray6
        }
        return appearance.assistantBubble ?? PlatformColors.systemGray5
    }
    
    /// Put this message's text on the pasteboard and notify the host so
    /// it can confirm the copy. Shared by the actions-row button and the
    /// bubble's context menu so both paths behave identically.
    private func copyMessage() {
        #if os(iOS)
        UIPasteboard.general.string = message.content
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        #endif
        onCopy?()
    }

    @ViewBuilder
    private var actionsRow: some View {
        // Spacing is 0 because `actionIconHitTarget()` carries its own
        // horizontal padding — the frames supply the 12pt between glyphs
        // that this row used to get from stack spacing. Adding spacing on
        // top of the frames double-counts it and the row sprawls.
        HStack(spacing: 0) {
            if !isUser {
                Button {
                    copyMessage()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.subheadline)
                        .actionIconHitTarget()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .accessibilityLabel("Copy message")
            }

            if let onSpeak = onSpeak {
                Button(action: onSpeak) {
                    Image(systemName: isSpeaking ? "stop.fill" : "speaker.wave.2")
                        .font(.subheadline)
                        .actionIconHitTarget()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .accessibilityLabel(isSpeaking ? "Stop playback" : "Play message")
            }

            if let onRetry = onRetry {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline)
                        .actionIconHitTarget()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .accessibilityLabel("Retry")
            }

            if let onEdit = onEdit {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.subheadline)
                        .actionIconHitTarget()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .accessibilityLabel("Edit")
            }

            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundColor(.secondary)
                // The icons' hit frames end ~8pt past the last glyph, so
                // this tops the timestamp gap up to match the icon spread.
                .padding(.leading, 9)
        }
    }
    
    @ViewBuilder
    private func debugInfo(_ metadata: MessageMetadata) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let args = metadata.arguments {
                Text("Args: \(args)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.top, 4)
    }
    
    @ViewBuilder
    private func fileAttachments(_ files: [FileAttachment]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(files) { file in
                HStack(spacing: 4) {
                    Image(systemName: "paperclip")
                        .font(.caption)
                    Text(file.name)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundColor(.secondary)
            }
        }
    }
}


private extension View {
    /// Expand a caption-sized glyph into a real tap target.
    ///
    /// The action-row icons render at `.font(.caption)`, so without this
    /// the hit area is the glyph itself — roughly 10pt, well under the
    /// 44pt Apple asks for. Taps landed next to the icon and silently did
    /// nothing, which read as the button being broken. `contentShape`
    /// makes the padded frame hit-testable rather than just the drawn
    /// pixels.
    ///
    /// 30pt around a ~13pt subheadline glyph leaves ~8pt each side, so
    /// two adjacent icons sit ~17pt apart — wider than the original 12pt
    /// row but tighter than the 22pt it briefly had — while height stays
    /// generous because nothing crowds the row vertically.
    func actionIconHitTarget() -> some View {
        self.frame(minWidth: 25, minHeight: 36)
            .contentShape(Rectangle())
    }
}

#if DEBUG
/// Canvas playground for the assistant action row. Live-interactive:
/// tapping the speaker toggles the play/stop icon in place, so spacing
/// and sizing tweaks in `actionIconHitTarget()` show immediately.
private struct MessageActionRowHarness: View {
    @State private var speaking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            MessageView(
                message: Message(
                    id: "preview-1",
                    role: .assistant,
                    content: "Here's a reply long enough to wrap a couple of lines, so the bubble and the action row underneath both look like the real thing."
                ),
                config: ChatWidgetConfig(),
                showDebug: false,
                onRetry: {},
                onEdit: nil,
                onSpeak: { speaking.toggle() },
                isSpeaking: speaking,
                onCopy: {},
                showAgentAvatar: true,
                agentAvatarSpeaking: speaking
            )
            MessageView(
                message: Message(
                    id: "preview-2",
                    role: .user,
                    content: "A user message for contrast."
                ),
                config: ChatWidgetConfig(),
                showDebug: false,
                onRetry: {},
                onEdit: {},
                showAgentAvatar: false,
                agentAvatarSpeaking: false
            )
        }
        .padding()
    }
}

struct MessageView_Previews: PreviewProvider {
    static var previews: some View {
        MessageActionRowHarness()
            .previewDisplayName("Action row — tap speaker to toggle")
    }
}
#endif
