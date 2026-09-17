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
@MainActor
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

    @StateObject private var history = SidebarHistoryModel()
    @State private var retryID = UUID()

    private struct HistoryRequestID: Equatable {
        let client: ObjectIdentifier?
        let showRecents: Bool
        let limit: Int
        let retry: UUID
    }

    private var historyRequestID: HistoryRequestID {
        HistoryRequestID(
            client: apiClient.map { ObjectIdentifier($0) },
            showRecents: config.sidebar.showRecents,
            limit: SidebarHistoryModel.clampedLimit(config.sidebar.recentsLimit),
            retry: retryID
        )
    }

    static func panelWidth(availableWidth: CGFloat) -> CGFloat {
        // Keep a usable dismiss target, even in a narrow split view.
        let width = max(0, availableWidth)
        return min(360, min(max(280, width * 0.8), max(0, width - 44)))
    }

    public var body: some View {
        // The host can place this directly in its root ZStack. Only
        // backgrounds extend under system chrome, never panel controls.
        GeometryReader { geo in
            HStack(spacing: 0) {
                panel
                    .frame(width: Self.panelWidth(availableWidth: geo.size.width))
                    .zIndex(1)
                Button(action: onDismiss) {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.black.opacity(0.35).ignoresSafeArea(.container))
                .zIndex(0)
                .accessibilityLabel("Dismiss sidebar")
                .accessibilityHint("Closes the conversation sidebar")
            }
        }
        // Keep the panel, its shadow and scrim together during host transitions.
        .compositingGroup()
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { onDismiss() }
        .task(id: historyRequestID) { await reloadConversations() }
        .onDisappear { history.reset() }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(config.appearance.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    navItems
                    if config.sidebar.showRecents && config.sidebar.recentsLimit > 0 {
                        recentsSection
                    }
                }
                .padding(.vertical, 8)
            }
            Divider().background(config.appearance.divider)
            footer
        }
        .frame(maxHeight: .infinity)
        .background {
            panelBackground
                .shadow(color: .black.opacity(0.18), radius: 12, x: 4, y: 0)
        }
    }

    private var panelBackground: some View {
        ZStack {
            // Neutral/classic intentionally leave the transcript background
            // clear. A modal sidebar cannot: its text would overlap the chat.
            // Keep custom colours/tints, but composite them over an opaque base.
            #if os(iOS)
            Color(uiColor: .systemBackground)
            #elseif os(macOS)
            Color(nsColor: .windowBackgroundColor)
            #endif
            config.appearance.background
        }
        .ignoresSafeArea(.container)
    }

    private var header: some View {
        HStack {
            if !config.sidebar.wordmark.isEmpty {
                Text(config.sidebar.wordmark)
                    .font(.system(size: 28, weight: .regular, design: .serif))
                    .foregroundColor(config.appearance.textPrimary)
            }
            Spacer()
            Button(action: onDismiss) {
                Label("Close", systemImage: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(config.appearance.textPrimary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close sidebar")
            .keyboardShortcut(.cancelAction)
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
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat-sidebar-item-\(item.id)")
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
        switch history.phase {
        case .loading:
            HStack {
                ProgressView()
                    .tint(config.appearance.textSecondary)
                    .accessibilityHidden(true)
                Text("Loading…")
                    .font(.caption)
                    .foregroundColor(config.appearance.textSecondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        case .idle:
            historyMessage("Conversation history not loaded")
            retryButton
        case .failed:
            historyMessage("Couldn't load conversations")
            retryButton
        case .unavailable:
            historyMessage("Conversation history is unavailable")
        case .loaded:
            if history.conversations.isEmpty {
                historyMessage("No conversations yet")
            }
            ForEach(history.conversations) { conv in
                let isSelected = conv.id == viewModel.conversationId
                Button {
                    onSelectConversation(conv)
                } label: {
                    HStack {
                        Text(SidebarHistoryModel.displayTitle(for: conv))
                            .font(.body.weight(isSelected ? .semibold : .regular))
                            .foregroundColor(config.appearance.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark")
                                .foregroundColor(config.appearance.textPrimary)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .background(isSelected ? config.appearance.surfaceElevated : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private func historyMessage(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundColor(config.appearance.textSecondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
    }

    private var retryButton: some View {
        Button { retryID = UUID() } label: {
            Label("Retry", systemImage: "arrow.clockwise")
                .font(.body)
                .foregroundColor(config.appearance.textPrimary)
                .padding(.horizontal, 20)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Retry loading conversations")
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
                    .frame(minWidth: 44, minHeight: 44)
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
        guard !Task.isCancelled else { return }
        guard config.sidebar.showRecents else {
            history.reset()
            return
        }
        let loader: SidebarHistoryModel.Loader? = apiClient.map { api in
            { try await api.loadConversations() }
        }
        await history.load(recentsLimit: config.sidebar.recentsLimit, using: loader)
    }
}
