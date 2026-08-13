import SwiftUI
import AgentClient

/// Slide-in conversation sidebar shown by the bundled `ChatWidgetView`
/// when `ChatWidgetConfig.sidebar.enabled` is `true`. Layout: serif
/// wordmark, static nav rows, scrollable "Recents" list, footer with
/// user avatar and a "New chat" pill.
///
/// All inputs come from the config and the supplied `ChatViewModel`
/// so host apps can embed the panel standalone (e.g. in a custom
/// shell) without `ChatWidgetView`.
public struct ChatSidebarView: View {
    @ObservedObject var viewModel: ChatViewModel
    let config: ChatWidgetConfig
    let apiClient: APIClient?
    /// Invoked when the user taps outside the panel or the close
    /// affordance. The parent is expected to drop the binding that
    /// presents the sidebar.
    let onDismiss: () -> Void
    /// Invoked when the user picks the "New chat" pill. Parent
    /// usually calls `viewModel.clearMessages()` and dismisses.
    let onNewChat: () -> Void
    /// Invoked when the user picks a row from "Recents". Parent
    /// loads the conversation via `viewModel.loadConversation(id:)`.
    let onSelectConversation: (Conversation) -> Void

    public init(
        viewModel: ChatViewModel,
        config: ChatWidgetConfig,
        apiClient: APIClient? = nil,
        onDismiss: @escaping () -> Void,
        onNewChat: @escaping () -> Void,
        onSelectConversation: @escaping (Conversation) -> Void
    ) {
        self.viewModel = viewModel
        self.config = config
        self.apiClient = apiClient
        self.onDismiss = onDismiss
        self.onNewChat = onNewChat
        self.onSelectConversation = onSelectConversation
    }

    @State private var conversations: [Conversation] = []
    @State private var isLoading: Bool = false

    public var body: some View {
        // Panel takes ~80% of the screen width so the open sidebar
        // feels like the primary surface (matches the reference
        // design); the remaining ~20% is the dim backdrop that the
        // user can tap to dismiss. `GeometryReader` is used so we
        // adapt to phones and iPad split views without hard-coding a
        // fixed width.
        GeometryReader { geo in
            let panelWidth = max(280, geo.size.width * 0.8)
            HStack(spacing: 0) {
                panel
                    .frame(width: panelWidth)
                Color.black.opacity(0.35)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }
            }
        }
        .ignoresSafeArea(.container, edges: .vertical)
        .task { await reloadConversations() }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(config.appearance.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    navItems
                    if config.sidebar.showRecents {
                        recentsSection
                    }
                }
                .padding(.vertical, 8)
            }
            Divider().background(config.appearance.divider)
            footer
        }
        .frame(maxHeight: .infinity)
        .background(config.appearance.background.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            if !config.sidebar.wordmark.isEmpty {
                Text(config.sidebar.wordmark)
                    .font(.system(size: 28, weight: .regular, design: .serif))
                    .foregroundColor(config.appearance.textPrimary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var navItems: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(config.sidebar.items) { item in
                Button {
                    item.perform()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: item.systemImage)
                            .font(.title3)
                            .frame(width: 22, alignment: .center)
                            .foregroundColor(config.appearance.textPrimary)
                        Text(item.title)
                            .font(.body)
                            .foregroundColor(config.appearance.textPrimary)
                        Spacer()
                        if let badge = item.badge {
                            Text(badge)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(config.appearance.surface)
                                .foregroundColor(config.appearance.textSecondary)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var recentsSection: some View {
        if !config.sidebar.recentsTitle.isEmpty {
            Text(config.sidebar.recentsTitle)
                .font(.caption)
                .foregroundColor(config.appearance.textSecondary)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 6)
        }
        if isLoading && conversations.isEmpty {
            HStack {
                ProgressView()
                    .tint(config.appearance.textSecondary)
                Text("Loading…")
                    .font(.caption)
                    .foregroundColor(config.appearance.textSecondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        } else if conversations.isEmpty {
            Text("No conversations yet")
                .font(.caption)
                .foregroundColor(config.appearance.textSecondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        } else {
            ForEach(conversations) { conv in
                Button {
                    onSelectConversation(conv)
                } label: {
                    HStack {
                        Text(conv.title ?? "Untitled conversation")
                            .font(.body)
                            .foregroundColor(config.appearance.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(config.appearance.surface)
                .frame(width: 36, height: 36)
                .overlay(
                    Text(config.sidebar.footerInitials ?? "")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(config.appearance.textPrimary)
                )
            if let caption = config.sidebar.footerCaption {
                Text(caption)
                    .font(.subheadline)
                    .foregroundColor(config.appearance.textPrimary)
                    .lineLimit(1)
            }
            Spacer()
            if !config.sidebar.newChatLabel.isEmpty {
                Button(action: onNewChat) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.pencil")
                            .font(.footnote)
                        Text(config.sidebar.newChatLabel)
                            .font(.footnote.weight(.medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(config.appearance.surface)
                    .foregroundColor(config.appearance.textPrimary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @MainActor
    private func reloadConversations() async {
        guard config.sidebar.showRecents, let api = apiClient else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await api.loadConversations()
            conversations = Array(fetched.prefix(config.sidebar.recentsLimit))
        } catch {
            // Network errors are silently swallowed — the panel
            // shows "No conversations yet" so the user can still
            // start a new chat. The host's error banner handles
            // the broader failure surface.
            #if DEBUG
            AgentLog.error("[ChatSidebarView] loadConversations failed: \(error)")
            #endif
            conversations = []
        }
    }
}
