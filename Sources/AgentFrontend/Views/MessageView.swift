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
                print("[AgentFrontend][MessageView] rendering ContentBlockRenderer with \(blocks.count) block(s)")
                #endif
            }()
            ContentBlockRenderer(blocks: blocks, config: config, onAction: onBlockAction)
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
                            #if os(iOS)
                            UIPasteboard.general.string = message.content
                            #else
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                            #endif
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
                MarkdownTextView(content: message.content, foregroundColor: messageTextColor, linkColor: linkColor)
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
    
    @ViewBuilder
    private var actionsRow: some View {
        HStack(spacing: 12) {
            if let onRetry = onRetry {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
            
            if let onEdit = onEdit {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }
            
            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundColor(.secondary)
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

