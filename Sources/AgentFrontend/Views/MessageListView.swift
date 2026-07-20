import SwiftUI
import AgentClient
#if canImport(UIKit)
import UIKit
#endif

/// Message list view. The only automated scroll action is on user
/// submit: when a new user message is appended, the list scrolls so
/// the just-sent message lands at the top of the viewport (top
/// right, since user messages are right-aligned). The agent's reply
/// then streams in below; the user is free to scroll down to follow
/// it (or not) — no further auto-scroll happens during the stream.
/// Pagination ("Load earlier") is also handled: older messages are
/// prepended, and the previously-first-visible message is restored
/// to the top so the user's reading position doesn't jump.
///
/// This matches the prevailing pattern in modern chat UIs (Claude,
/// ChatGPT, iMessage, etc.): no surprise scroll-jacking on
/// streaming, the user is always in control except for the one
/// "scroll the just-sent message into view" action on submit. Hosts
/// that want different behaviour can layer their own
/// `ScrollViewReader` + `proxy.scrollTo` on top of this view.
public struct MessageListView: View {
    let messages: [Message]
    let isLoading: Bool
    let hasMoreMessages: Bool
    let loadingMoreMessages: Bool
    let config: ChatWidgetConfig
    let onLoadMore: () -> Void
    let onRetry: (Int) -> Void
    let onEdit: (Int, String) -> Void
    /// Live sub-agent activity from the view model. When non-empty in
    /// pill mode the list renders a quiet activity pill in place of
    /// the generic "Thinking..." spinner. Defaults to an empty state
    /// so the existing ``MessageListView(...)`` call sites and
    /// harness keep working unchanged.
    let activity: SubAgentActivityState
    /// `true` when the agent's TTS playback is in flight. Propagated
    /// down to the latest assistant ``MessageView`` so its avatar can
    /// glow without recomputing per-row.
    let agentIsSpeaking: Bool
    /// Fired when the user taps a ``BlockAction`` inside any rendered
    /// ``ContentBlock`` (e.g. an action-button row). The list itself
    /// has no opinion on what an action should do; ``ChatWidgetView``
    /// supplies a default that auto-sends `type == "message"` actions
    /// as a user turn, opens `type == "link"` URLs, and forwards
    /// everything else to the host. Optional so the existing
    /// preview/harness call site keeps compiling.
    let onBlockAction: ((BlockAction) -> Void)?

    public init(
        messages: [Message],
        isLoading: Bool,
        hasMoreMessages: Bool,
        loadingMoreMessages: Bool,
        config: ChatWidgetConfig,
        onLoadMore: @escaping () -> Void,
        onRetry: @escaping (Int) -> Void,
        onEdit: @escaping (Int, String) -> Void,
        activity: SubAgentActivityState = SubAgentActivityState(),
        agentIsSpeaking: Bool = false,
        onBlockAction: ((BlockAction) -> Void)? = nil
    ) {
        self.messages = messages
        self.isLoading = isLoading
        self.hasMoreMessages = hasMoreMessages
        self.loadingMoreMessages = loadingMoreMessages
        self.config = config
        self.onLoadMore = onLoadMore
        self.onRetry = onRetry
        self.onEdit = onEdit
        self.activity = activity
        self.agentIsSpeaking = agentIsSpeaking
        self.onBlockAction = onBlockAction
    }

    @State private var editingIndex: Int?
    @State private var editText: String = ""

    /// Anchor message id used by the "Load earlier" pagination
    /// path. Set by the tap handler on the load-more button; consumed
    /// by ``handleCountChange`` after the next render to scroll
    /// the previously-first-visible message back to the top of the
    /// viewport. No scroll tracking is performed outside this one
    /// use case.
    @State private var paginationAnchorId: String?
    /// Message count snapshot used to detect that a pagination
    /// commit actually grew the list (so we know the anchor should
    /// be restored). A failed pagination doesn't change the count
    /// and we leave the anchor in place for the next attempt.
    @State private var previousMessageCount: Int = 0
    /// Identity of the most recently seen tail message. The user-
    /// submit scroll path watches this instead of `messages.count`
    /// because watching the id + role lets us detect "a new user
    /// message was just appended" even when the agent's first
    /// response lands in the same UI tick (a cached/fast agent
    /// appends the assistant message before SwiftUI re-evaluates
    /// the view body, so the count-change handler would only ever
    /// see a delta of 2 and `messages.last` would be the assistant,
    /// not the user). Watching the id handles both "user-only
    /// append" and "user + first agent response in the same
    /// frame". The id is `nil` for an empty conversation.
    @State private var lastSeenTailId: String?

    /// Id of the invisible 1pt sentinel rendered after the last row.
    /// The user-submit scroll targets this (anchor: .bottom) instead
    /// of the message row itself — see ``handleTailChange``.
    private static let bottomAnchorId = "message-list-bottom-anchor"

    /// Composite "role|id" key for the tail message. The role is
    /// baked into the *observed value* because `onChange` closures
    /// capture the view value from the render that installed them:
    /// inside the closure, `messages` is the *pre-append* array, so
    /// re-reading `messages.last?.role` there always sees the old
    /// tail and never `.user`. The closure's own parameter is the
    /// only reliable carrier of post-change state.
    private var tailKey: String? {
        messages.last.map { "\($0.role.rawValue)|\($0.id)" }
    }

    public var body: some View {
        ScrollViewReader { proxy in
            scrollContent
                .background(config.appearance.background)
                .onChange(of: messages.count) { newCount in
                    handleCountChange(newCount: newCount, proxy: proxy)
                }
                .onChange(of: tailKey) { newTailKey in
                    handleTailChange(newTailKey: newTailKey, proxy: proxy)
                }
                .onAppear {
                    previousMessageCount = messages.count
                    lastSeenTailId = messages.last?.id
                }
        }
    }

    /// Tail watcher callback. Fires whenever the tail message
    /// changes (i.e. a new message was appended). If the new tail
    /// is a user message, scrolls the list so the user message
    /// lands at the top of the viewport.
    ///
    /// The observed value is a composite `"role|id"` key — role and
    /// id are decoded from the closure parameter rather than read
    /// from `messages`, which is stale inside the closure (see
    /// ``tailKey``).
    ///
    /// Two mechanics make the scroll actually stick:
    ///   1. **Geometry** — a ScrollView clamps to its max content
    ///      offset, so the *last* row can only reach the *top* of
    ///      the viewport if at least a viewport's worth of content
    ///      exists below it. ``scrollContent`` guarantees that by
    ///      wrapping the current turn (last user message + whatever
    ///      streams in after it) in a group with
    ///      `minHeight == viewport height`.
    ///   2. **Timing** — the `scrollTo` is re-issued a few times
    ///      over ~600ms (see below). Plain `asyncAfter` hops are
    ///      used instead of a `Task { await ... }` because they
    ///      don't suspend: an earlier `Task`-based version could
    ///      resume after the `ScrollViewReader`'s underlying reader
    ///      was re-evaluated and crashed with `EXC_BAD_ACCESS`.
    private func handleTailChange(newTailKey: String?, proxy: ScrollViewProxy) {
        let previousTailId = lastSeenTailId
        // Decode "role|id" (id may itself contain "|"-free UUIDs,
        // but split on the first separator to be safe).
        var newTailId: String?
        var newTailRole: String?
        if let newTailKey, let sep = newTailKey.firstIndex(of: "|") {
            newTailRole = String(newTailKey[..<sep])
            newTailId = String(newTailKey[newTailKey.index(after: sep)...])
        }
        lastSeenTailId = newTailId
        guard newTailId != nil, newTailId != previousTailId else { return }
        // Only user-message appends scroll. Assistant/system appends
        // (streaming placeholders, errors) also change the tail, but
        // they must not move the list — the reply streams into the
        // reserved space below the pinned user message.
        guard newTailRole == MessageRole.user.rawValue else { return }
        // Skip the transition out of an empty list (first message of
        // a brand-new conversation, or a wholesale conversation
        // load) — the content fits or was just restored, and there's
        // nothing meaningful to scroll away from.
        guard previousTailId != nil else { return }
        // The scroll target is the *static bottom anchor*, not the
        // message row: `scrollTo(messageId, anchor: .top)` proved
        // unreliable for rows nested inside the turn group (it
        // executed but never moved the content), whereas scrolling
        // a trailing sentinel to `.bottom` is the standard SwiftUI
        // chat mechanism. Because the turn group's `minHeight` is
        // the viewport height, bottom-of-content == the just-sent
        // user message sitting at the top of the viewport — the
        // same visual result.
        //
        // Retries: appending the turn group grows the content by a
        // full viewport, and until the ScrollView commits the new
        // content size, a scroll clamps to the old max offset.
        // Re-issuing the same instant scroll over ~600ms is
        // idempotent once it lands and survives that race (and the
        // keyboard-dismiss viewport resize that overlaps a send).
        for delay in [0.0, 0.1, 0.3, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    proxy.scrollTo(Self.bottomAnchorId, anchor: .bottom)
                }
            }
        }
    }

    /// Pagination anchor restoration only. The user-submit scroll
    /// has been moved to ``handleTailChange`` (watching
    /// `messages.last?.id`). The `scrollTo` call is synchronous
    /// (no `Task` wrapper) — see the rationale in
    /// ``handleTailChange``.
    private func handleCountChange(newCount: Int, proxy: ScrollViewProxy) {
        let countBeforeThisChange = previousMessageCount
        previousMessageCount = newCount
        guard newCount > countBeforeThisChange else { return }
        // Pagination commit: restore the anchor to the top of the
        // viewport. A two-tick wait isn't used here because the
        // pagination anchor is set on the load-more button tap
        // (one user gesture ago), so the prepended rows have
        // already been fetched and will be measured by the time
        // the count-change handler runs.
        if countBeforeThisChange > 0, let anchorToRestore = paginationAnchorId {
            paginationAnchorId = nil
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                proxy.scrollTo(anchorToRestore, anchor: .top)
            }
        }
    }

    /// Dismiss the keyboard by resigning first responder.
    private func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        #endif
    }

    @ViewBuilder
    private var scrollContent: some View {
        // GeometryReader supplies the viewport height used as the
        // current turn's `minHeight` — see `currentTurnGroup`.
        GeometryReader { geo in
            ScrollView {
                LazyVStack(spacing: 12) {
                    // Load more button at top
                    if hasMoreMessages {
                        Button {
                            if let firstMsg = messages.first {
                                paginationAnchorId = firstMsg.id
                            }
                            onLoadMore()
                        } label: {
                            if loadingMoreMessages {
                                ProgressView().progressViewStyle(CircularProgressViewStyle())
                            } else {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up").font(.caption2)
                                    Text("Load earlier messages").font(.caption)
                                }
                                .foregroundColor(config.primaryColor)
                            }
                        }
                        .padding(.vertical, 8)
                        .disabled(loadingMoreMessages)
                        .id("load-more")
                    }

                    // Empty state
                    if messages.isEmpty && !isLoading {
                        EmptyStateView(config: config)
                    }

                    // Messages
                    // Resolve once per render: the id of the most recent
                    // assistant text message so only its avatar gets the
                    // speaking-halo treatment. Skips tool/system/contentBlock
                    // rows so the glow always lands on a real reply.
                    let latestAssistantId: String? = messages.last(where: {
                        $0.role == .assistant
                            && $0.type != .toolCall
                            && $0.type != .toolResult
                            && $0.type != .subAgentStart
                            && $0.type != .subAgentEnd
                            && $0.type != .agentContext
                            && $0.type != .contentBlocks
                    })?.id
                    let rows = Array(messages.enumerated())
                    // The "current turn" starts at the last user message.
                    // It is rendered as one group whose minHeight is the
                    // viewport height, so scrolling the bottom anchor
                    // into view (see ``handleTailChange``) lands the
                    // user message at the top of the viewport. The
                    // agent's reply then streams into the reserved
                    // space below it, ChatGPT-style, without any
                    // further auto-scroll.
                    if let turnStart = messages.lastIndex(where: { $0.role == .user }) {
                        ForEach(rows[..<turnStart], id: \.element.id) { index, message in
                            messageRow(index: index, message: message,
                                       latestAssistantId: latestAssistantId)
                        }
                        VStack(spacing: 12) {
                            ForEach(rows[turnStart...], id: \.element.id) { index, message in
                                messageRow(index: index, message: message,
                                           latestAssistantId: latestAssistantId)
                            }
                            statusIndicator
                        }
                        .frame(minHeight: max(0, geo.size.height - 32),
                               alignment: .top)
                    } else {
                        ForEach(rows, id: \.element.id) { index, message in
                            messageRow(index: index, message: message,
                                       latestAssistantId: latestAssistantId)
                        }
                        statusIndicator
                    }

                    // Static scroll target for the user-submit scroll.
                    // Sits after the turn group, so scrolling it to
                    // `.bottom` pins the whole current turn (whose
                    // minHeight fills the viewport) on screen — i.e.
                    // the just-sent user message lands at the top.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorId)
                }
                .padding()
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            // Tap on message list area dismisses keyboard without swallowing child taps
            .simultaneousGesture(
                TapGesture().onEnded { _ in dismissKeyboard() }
            )
        }
    }

    /// Single message row. Extracted so the head of the list and the
    /// current-turn group render identically.
    @ViewBuilder
    private func messageRow(index: Int, message: Message,
                            latestAssistantId: String?) -> some View {
        let isToolMsg = message.type == .toolCall
            || message.type == .toolResult
            || message.type == .subAgentStart
            || message.type == .subAgentEnd
            || message.type == .agentContext
        if isToolMsg && !config.showToolMessages {
            EmptyView()
        } else if editingIndex == index {
            EditMessageView(
                text: $editText,
                onSave: {
                    onEdit(index, editText)
                    editingIndex = nil
                },
                onCancel: { editingIndex = nil }
            )
        } else {
            MessageView(
                message: message,
                config: config,
                showDebug: config.enableDebugMode,
                onRetry: message.role == .user || message.role == .assistant ? {
                    onRetry(index)
                } : nil,
                onEdit: message.role == .user ? {
                    editText = message.content
                    editingIndex = index
                } : nil,
                showAgentAvatar: config.showPresenceOrb,
                agentAvatarSpeaking: agentIsSpeaking
                    && message.id == latestAssistantId,
                onBlockAction: onBlockAction
            )
            .id(message.id)
        }
    }

    /// Loading indicator. Pill mode + active sub-agent → render the
    /// activity pill in place of the generic spinner so the user sees
    /// which specialist is running and a tail of its narration. Falls
    /// back to the spinner whenever the bracket isn't open (e.g. the
    /// parent itself is composing the final reply).
    @ViewBuilder
    private var statusIndicator: some View {
        if activity.isActive
            && config.appearance.subAgentActivityStyle == .pill {
            SubAgentActivityPillView(
                activity: activity,
                appearance: config.appearance
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        } else if isLoading {
            HStack {
                ProgressView().progressViewStyle(CircularProgressViewStyle())
                Text("Thinking...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }
}

/// Empty state view. Two modes:
/// - `config.greeting.enabled == true` → centered optional brand mark
///   + serif greeting (`GreetingView`). This is the new library
///   default.
/// - otherwise → the legacy speech-bubble icon + heading/message
///   pair, preserved for hosts that opt out of the warm-dark look.
struct EmptyStateView: View {
    let config: ChatWidgetConfig

    var body: some View {
        if config.greeting.enabled {
            GreetingView(config: config)
                // Center vertically inside the LazyVStack — the list
                // pads its content with 16pt and the parent ScrollView
                // is full-height, so a generous min-height lifts the
                // greeting roughly to the middle of the viewport.
                .frame(minHeight: 360)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 48))
                    .foregroundColor(config.primaryColor.opacity(0.5))

                Text(config.emptyStateTitle)
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(config.emptyStateMessage)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(40)
        }
    }
}

/// Edit message view
struct EditMessageView: View {
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            TextEditor(text: $text)
                .frame(minHeight: 60)
                .padding(8)
                .background(PlatformColors.systemGray6)
                .cornerRadius(8)

            HStack {
                Button("Cancel", action: onCancel)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Save & Resend", action: onSave)
                    .fontWeight(.semibold)
            }
            .font(.caption)
        }
        .padding()
        .background(PlatformColors.systemBackground)
        .cornerRadius(12)
        .shadow(radius: 2)
    }
}

#if DEBUG
/// Scripted harness that exercises the pagination anchor-restore
/// path without a network or running ChatViewModel. The list no
/// longer auto-scrolls, so this harness now only verifies the
/// "Load earlier" gesture preserves the user's reading position.
struct MessageListScrollHarness: View {
    @State private var messages: [Message] = MessageListScrollHarness.seed()
    @State private var isLoading: Bool = false
    @State private var hasMoreMessages: Bool = true
    @State private var loadingMoreMessages: Bool = false

    static func seed() -> [Message] {
        (1...15).map { i in
            Message(
                id: "seed-\(i)",
                role: i.isMultiple(of: 2) ? .assistant : .user,
                content: "Seed message \(i) — lorem ipsum dolor sit amet."
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            MessageListView(
                messages: messages,
                isLoading: isLoading,
                hasMoreMessages: hasMoreMessages,
                loadingMoreMessages: loadingMoreMessages,
                config: ChatWidgetConfig(),
                onLoadMore: { simulateLoadMore() },
                onRetry: { _ in },
                onEdit: { _, _ in }
            )
            HStack {
                Button("Simulate 'Load earlier'") { simulateLoadMore() }
                    .disabled(loadingMoreMessages)
                Button("Reset") {
                    messages = Self.seed()
                    isLoading = false
                    hasMoreMessages = true
                }
            }
            .padding()
        }
    }

    private func simulateLoadMore() {
        loadingMoreMessages = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            // Prepend three older messages. The view should
            // restore the previously-first-visible message to the
            // top so the user's reading position doesn't jump.
            let older = (1...3).map { i in
                Message(
                    id: "older-\(i)-\(Date().timeIntervalSince1970)",
                    role: .user,
                    content: "Older message \(i) — prepended by pagination."
                )
            }
            messages.insert(contentsOf: older, at: 0)
            hasMoreMessages = false
            loadingMoreMessages = false
        }
    }
}

struct MessageListView_Previews: PreviewProvider {
    static var previews: some View {
        MessageListScrollHarness()
            .previewDisplayName("Scroll harness — pagination anchor")
    }
}
#endif
