import SwiftUI
import AgentClient
import os
#if canImport(UIKit)
import UIKit
#endif

/// Message list view: a right-side-up transcript in a **plain, eagerly
/// measured `VStack`** — deliberately not a `LazyVStack`.
///
/// Every scroll defect in this file's history — overshooting
/// scroll-to-bottom, jumping to blank space, streaming bounce, unstable
/// jump-button visibility — traced back to one cause: lazy containers
/// *estimate* the height of off-screen rows, and scroll targets computed
/// from estimated geometry land wherever the estimate happens to be
/// wrong. With every row measured for real, a `scrollTo` is exact, on
/// every OS version. (Same architecture as fullmoon and Enchanted, the
/// prevailing open-source iOS LLM chat apps.)
///
/// Eager rendering is affordable because the product bounds conversation
/// length (a cap with progressive "save to memories & start fresh"
/// notices, motivated by token budgets as much as UI cost). Rendering a
/// few hundred text rows up front is well within budget; profile with
/// the debug seeder before raising the cap materially.
///
/// Scroll behaviour:
///   * **Opening a conversation** lands on the newest message
///     (`.initialOffset` anchor on iOS 18+, an exact `scrollTo` before).
///   * **Sending a message** pins the list to the bottom, settling the
///     just-sent message above the composer.
///   * **Streaming** follows ChatGPT-style *derived* follow: on iOS 18+
///     the `.sizeChanges` anchor keeps the bottom pinned while the user
///     is at the bottom, and leaves them untouched once they scroll up;
///     scrolling back down (or tapping the jump button) re-engages —
///     the scroll position itself is the state, no one-way latch.
///     Pre-18 has no size-change anchoring, so streaming follows
///     unconditionally there (the Enchanted approach) — a documented
///     compromise for the shrinking iOS 16/17 share.
///   * A jump-to-bottom button appears (iOS 18+) once the user is more
///     than `nearBottomThresholdPt` from the newest message.
///
/// Pagination ("Load earlier") prepends older messages and restores the
/// previously-first-visible message to the top of the viewport. It is
/// vestigial: once the data layer fetches whole conversations (safe
/// under the message cap), `hasMoreMessages` is permanently false and
/// the button never renders.
public struct MessageListView: View {
    let messages: [Message]
    let isLoading: Bool
    let hasMoreMessages: Bool
    let loadingMoreMessages: Bool
    let config: ChatWidgetConfig
    let onLoadMore: () -> Void
    let onRetry: (Int) -> Void
    /// Begin editing a sent user message: `(index, currentContent)`.
    /// The list no longer hosts the edit UI — the host presents its edit
    /// card (see ``EditMessageCard``) in place of the composer and owns
    /// the commit. `nil` hides the Edit affordance entirely.
    let onBeginEdit: ((Int, String) -> Void)?
    /// Speak a message aloud, or stop it if it is already playing.
    /// Receives the whole message so the host can track *which* row is
    /// speaking; the list only decides which rows get the affordance
    /// (assistant text, never user or tool rows). `nil` when the host
    /// has TTS disabled, which hides it entirely.
    let onSpeak: ((Message) -> Void)?
    /// Id of the message currently being read aloud, or `nil`. Drives the
    /// per-row speaker/stop toggle.
    let speakingMessageId: String?
    /// Fired after a message's text is copied to the pasteboard, from
    /// either the actions row or the context menu. The list doesn't act
    /// on it — it exists so the host can show a confirmation.
    let onCopy: (() -> Void)?
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
        onBeginEdit: ((Int, String) -> Void)? = nil,
        onSpeak: ((Message) -> Void)? = nil,
        speakingMessageId: String? = nil,
        onCopy: (() -> Void)? = nil,
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
        self.onBeginEdit = onBeginEdit
        self.onSpeak = onSpeak
        self.speakingMessageId = speakingMessageId
        self.onCopy = onCopy
        self.activity = activity
        self.agentIsSpeaking = agentIsSpeaking
        self.onBlockAction = onBlockAction
    }


    /// Anchor message id used by the "Load earlier" pagination path.
    /// Set by the tap handler on the load-more button; consumed by
    /// ``handleCountChange`` after the next render to scroll the
    /// previously-first-visible message back to the top of the viewport.
    @State private var paginationAnchorId: String?
    /// Message count snapshot used to detect that a pagination commit
    /// actually grew the list. A failed pagination doesn't change the
    /// count and we leave the anchor in place for the next attempt.
    @State private var previousMessageCount: Int = 0
    /// Identity of the most recently seen tail message. The user-
    /// submit scroll path watches this instead of `messages.count`
    /// because watching the id + role lets us detect "a new user
    /// message was just appended" even when the agent's first
    /// response lands in the same UI tick (a cached/fast agent
    /// appends the assistant message before SwiftUI re-evaluates
    /// the view body, so the count-change handler would only ever
    /// see a delta of 2 and `messages.last` would be the assistant,
    /// not the user). The id is `nil` for an empty conversation.
    @State private var lastSeenTailId: String?
    /// Whether the user has scrolled far enough from the newest message
    /// to warrant the jump-to-bottom affordance. Driven by
    /// ``ScrollAwayDetector`` (iOS 18+); pre-18 nothing sets it and the
    /// button never appears there.
    @State private var showScrollToBottom = false
    /// Streaming-follow engagement. The contract mirrors the jump
    /// button: button gone (near bottom) → following; a finger-drag
    /// (``StreamFollowGovernor``) → not following, until the user next
    /// enters the near-bottom zone and the button hides again. Starts
    /// `true` (a fresh conversation opens at the bottom). Rejected
    /// alternatives, verified broken on device: the native
    /// `.sizeChanges` anchor never re-engages after a manual scroll;
    /// deriving disengagement from distance let transient growth bursts
    /// self-cancel the follow; phase-based re-engagement missed
    /// arrivals at the bottom. Pre-18 neither detector runs, so this
    /// stays `true` and streaming follows unconditionally there — the
    /// documented compromise.
    @State private var followBottom = true

    // ── TEMP DEBUG HUD ──────────────────────────────────────────────
    // On-screen follow-state tracer: shows whether the stream-follow is
    // engaged and the last few events that changed it (with the raw
    // scroll phase that caused each). Flip to `false` (or delete the
    // marked block) once the stickiness investigation is done. Runtime
    // flag rather than #if DEBUG — custom build configurations strip
    // DEBUG unreliably in this package (see HangDiagnostics).
    private static let followDebugHUDEnabled = false
    private struct FollowDebugEvent: Identifiable {
        let id: Int
        let text: String
    }
    @State private var followDebugEvents: [FollowDebugEvent] = []
    @State private var followDebugCounter = 0
    private static let debugTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.S"
        return f
    }()
    private static let followLogger = Logger(subsystem: "agent-ios",
                                             category: "ScrollFollow")
    /// Console/unified-log only — for per-tick tracing that would flood
    /// the six-line HUD and push out the interesting state flips.
    private func logFollowConsole(_ text: String) {
        guard Self.followDebugHUDEnabled else { return }
        Self.followLogger.notice("[Follow] \(text, privacy: .public)")
    }
    private func logFollow(_ text: String) {
        guard Self.followDebugHUDEnabled else { return }
        // Mirror every HUD event to the unified log: shows live in the
        // Xcode console when running attached, and in Console.app
        // (filter subsystem "agent-ios") for un-attached device runs.
        Self.followLogger.notice("[Follow] \(text, privacy: .public)")
        followDebugCounter += 1
        let ts = Self.debugTimeFormatter.string(from: Date())
        followDebugEvents.insert(
            FollowDebugEvent(id: followDebugCounter, text: "\(ts)  \(text)"),
            at: 0
        )
        if followDebugEvents.count > 6 {
            followDebugEvents.removeLast(followDebugEvents.count - 6)
        }
    }
    // ── END TEMP DEBUG HUD ──────────────────────────────────────────

    /// Id of the invisible 1pt sentinel rendered after the last row.
    /// All bottom scrolls target this. With every row eagerly measured
    /// its position is exact — no estimation, no overshoot.
    private static let bottomAnchorId = "message-list-bottom-anchor"
    /// How far the content bottom must sit below the viewport before the
    /// jump-to-bottom button appears. Roughly half a short message, so
    /// the button doesn't flicker in and out during normal reading.
    private static let nearBottomThresholdPt: CGFloat = 80

    /// `true` where the scroll view can own bottom anchoring
    /// (`defaultScrollAnchor`, iOS 18 / macOS 15). Older OSes fall back
    /// to explicit scrolls.
    private var useNativeBottomAnchor: Bool {
        if #available(iOS 18.0, macOS 15.0, *) { return true }
        return false
    }

    public var body: some View {
        let _ = HangDiagnostics.mark("MessageListView body (\(messages.count) messages)")
        return ScrollViewReader { proxy in
            scrollContent
                .onAppear {
                    HangDiagnostics.start()
                    previousMessageCount = messages.count
                    lastSeenTailId = messages.last?.id
                    // Pre-18: land on the newest message ourselves — the
                    // `.initialOffset` anchor does this on iOS 18+.
                    if !useNativeBottomAnchor, !messages.isEmpty {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .background(config.appearance.background)
                .onChange(of: messages.count) { newCount in
                    handleCountChange(newCount: newCount, proxy: proxy)
                }
                .onChange(of: tailKey) { newTailKey in
                    handleTailChange(newTailKey: newTailKey, proxy: proxy)
                }
                .onChange(of: streamTick) { newTick in
                    // Streaming follow, driven by our own derived state
                    // (see `followBottom`). Runs on every OS version:
                    // on iOS 18+ it overlaps the `.sizeChanges` anchor
                    // in the never-scrolled case (idempotent — both
                    // target the same place) and is the only thing that
                    // re-engages after the user scrolls away and back.
                    //
                    // Everything the guard needs is decoded from the
                    // observed value itself: inside this closure
                    // `messages` and the other properties are from the
                    // PRE-change render (see `tailKey`), and reading
                    // them silently skips ticks.
                    handleStreamTick(newTick, proxy: proxy)
                }
                // The animation belongs on the overlay, NOT on
                // `scrollContent`. Applied to the list it animates every
                // layout change in the subtree whenever the flag flips —
                // i.e. all rows at once — which is both expensive and
                // visibly wrong during a send.
                .overlay(alignment: .bottom) {
                    scrollToBottomButton(proxy: proxy)
                        .animation(.easeInOut(duration: 0.2),
                                   value: showScrollToBottom)
                }
                // TEMP DEBUG HUD — see the marked block near the top.
                .overlay(alignment: .topTrailing) {
                    if Self.followDebugHUDEnabled {
                        followDebugHUD
                    }
                }
        }
    }

    // TEMP DEBUG HUD — see the marked block near the top.
    private var followDebugHUD: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(followBottom ? Color.green : Color.red)
                    .frame(width: 9, height: 9)
                Text(followBottom ? "STICKY" : "NOT STICKY")
                    .font(.caption2.weight(.bold))
            }
            ForEach(followDebugEvents) { event in
                Text(event.text)
                    .font(.system(size: 9, design: .monospaced))
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.75))
        .foregroundColor(.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.trailing, 8)
        .padding(.top, 4)
        .allowsHitTesting(false)
    }

    /// Composite "role|content-length" key for the tail message —
    /// changes on every streaming delta. The role rides inside the
    /// observed value for the same staleness reason as ``tailKey``.
    private var streamTick: String? {
        messages.last.map { "\($0.role.rawValue)|\($0.content.count)" }
    }

    /// Pin-per-tick handler for the streaming follow. Deliberately has
    /// NO `isLoading` guard: an assistant tail whose content length
    /// changed *is* streaming, and `isLoading` read here would be the
    /// stale pre-change value anyway.
    private func handleStreamTick(_ tick: String?, proxy: ScrollViewProxy) {
        guard let tick, let sep = tick.firstIndex(of: "|") else { return }
        let role = String(tick[..<sep])
        guard role == MessageRole.assistant.rawValue else {
            logFollowConsole("tick skipped — tail role \(role)")
            return
        }
        guard followBottom else {
            logFollowConsole("tick skipped — follow off")
            return
        }
        logFollowConsole("tick → pin (\(tick))")
        scrollToBottom(proxy: proxy)
    }

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

    /// Tail watcher callback. Fires whenever the tail message changes
    /// (i.e. a new message was appended). If the new tail is a user
    /// message, pins the list to the bottom so the just-sent bubble
    /// settles above the composer.
    private func handleTailChange(newTailKey: String?, proxy: ScrollViewProxy) {
        let previousTailId = lastSeenTailId
        // Decode "role|id" (split on the first separator to be safe).
        var newTailId: String?
        var newTailRole: String?
        if let newTailKey, let sep = newTailKey.firstIndex(of: "|") {
            newTailRole = String(newTailKey[..<sep])
            newTailId = String(newTailKey[newTailKey.index(after: sep)...])
        }
        lastSeenTailId = newTailId
        guard newTailId != nil, newTailId != previousTailId else { return }
        // Only user-message appends scroll. Assistant/system appends
        // (streaming placeholders, errors) also change the tail; on
        // iOS 18+ following them is the size-change anchor's job, and
        // scrolling here would also yank readers who scrolled away.
        guard newTailRole == MessageRole.user.rawValue else { return }
        // Skip the transition out of an empty list — the initial-offset
        // anchor (or the onAppear scroll) already lands there.
        guard previousTailId != nil else { return }
        scrollToBottom(proxy: proxy)
    }

    /// Pin the sentinel to the bottom of the viewport, exactly.
    ///
    /// Issued twice: immediately, and once on the next runloop turn.
    /// The re-issue covers the one remaining race — a scroll issued in
    /// the same transaction that grows the content (send, conversation
    /// load) clamps to the not-yet-committed old content size. With
    /// eager rows both calls compute *exact* offsets, so the second is
    /// a no-op whenever the first already landed. This replaces the
    /// four-shot 600ms retry ladder the lazy layout needed while its
    /// estimates settled.
    private func scrollToBottom(proxy: ScrollViewProxy) {
        HangDiagnostics.mark("scrollTo bottom anchor")
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            proxy.scrollTo(Self.bottomAnchorId, anchor: .bottom)
        }
        DispatchQueue.main.async {
            withTransaction(tx) {
                proxy.scrollTo(Self.bottomAnchorId, anchor: .bottom)
            }
        }
    }

    /// Count-change handler: initial conversation load (pre-18) and
    /// pagination anchor restoration.
    private func handleCountChange(newCount: Int, proxy: ScrollViewProxy) {
        let countBeforeThisChange = previousMessageCount
        previousMessageCount = newCount
        guard newCount > countBeforeThisChange else { return }

        // Initial load of an existing conversation (empty → populated):
        // land on the newest message. iOS 18+ gets this from the
        // `.initialOffset` anchor; pre-18 needs the explicit scroll.
        if countBeforeThisChange == 0 {
            if !useNativeBottomAnchor, newCount > 1 {
                scrollToBottom(proxy: proxy)
            }
            return
        }

        // Pagination commit: restore the previously-first-visible
        // message to the top of the viewport so the reading position
        // doesn't jump. The anchor was set on the load-more button tap
        // (one user gesture ago), so the prepended rows have already
        // been fetched and measured by the time this runs.
        if let anchorToRestore = paginationAnchorId {
            paginationAnchorId = nil
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                proxy.scrollTo(anchorToRestore, anchor: .top)
            }
        }
    }

    @ViewBuilder
    private var scrollContent: some View {
        ScrollView {
            // Plain VStack: every row measured, every scroll target
            // exact. See the type-level comment for why this is the
            // load-bearing decision of the whole file.
            VStack(spacing: 12) {
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

                if messages.isEmpty && !isLoading {
                    EmptyStateView(config: config)
                }

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

                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    messageRow(index: index, message: message,
                               latestAssistantId: latestAssistantId)
                }

                statusIndicator

                // Static scroll target after the last row — the exact
                // "bottom of the conversation".
                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomAnchorId)
            }
            .padding()
            .chatReadableColumn()
        }
        // iOS 18+: the ScrollView owns bottom anchoring. Opens at the
        // newest message (`.initialOffset`) and keeps the bottom pinned
        // while content grows *if the user is at the bottom*
        // (`.sizeChanges`) — scrolling up disengages, scrolling back
        // re-engages, with no state of ours involved. Deliberately not
        // the plain `defaultScrollAnchor(.bottom)`: that adds the
        // `.alignment` role, which bottom-aligns an under-full
        // conversation — short chats should start at the top.
        .modifier(NativeBottomAnchorModifier())
        // Jump-button visibility from the scroll view's own geometry
        // callback (iOS 18+). The transformed value is a Bool, so the
        // action only fires when "away from bottom" actually flips —
        // no per-frame state writes.
        .modifier(ScrollAwayDetector(threshold: Self.nearBottomThresholdPt) { away in
            showScrollToBottom = away
            // The stickiness contract is the one the user can SEE:
            // jump button visible → not following; jump button gone →
            // following. Re-engagement is therefore coupled directly to
            // the button hiding — reach the near-bottom zone by any
            // means (drag, fling, jump button, content settling) and
            // the follow is back on. Engage-only in this direction:
            // switching the follow OFF stays exclusively with the drag
            // phases below, so a transient growth burst that briefly
            // shows the button cannot also kill an active follow.
            logFollow(away ? "button SHOWN (away > 80pt)"
                           : "button hidden (near bottom)")
            if !away {
                if !followBottom { logFollow("STICKY ON — button hid") }
                followBottom = true
            }
        })
        // Follow disengagement is deliberately NOT derived from distance:
        // during streaming a growth burst can put the bottom beyond the
        // threshold for a frame before the follow scroll lands, and a
        // distance-based rule reads that transient as "the user scrolled
        // away" and kills the follow. Intent needs a finger.
        .modifier(StreamFollowGovernor { phaseName, isDragPhase in
            logFollow("phase → \(phaseName)")
            if isDragPhase {
                if followBottom { logFollow("STICKY OFF — drag (\(phaseName))") }
                followBottom = false
            }
        })
        #if os(iOS)
        // Interactive drag-to-dismiss only. Do NOT add a tap gesture here
        // to dismiss the keyboard: `simultaneousGesture` fires alongside
        // the child gestures it runs beside, so the tap that begins a
        // text selection on a bubble also resigns first responder. The
        // keyboard drops, the list re-lays-out mid-gesture, and the
        // selection drag is lost — which breaks long-press-and-drag
        // selection on every message.
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    /// Circular jump-to-bottom button. Only rendered when the user has
    /// scrolled away from the newest message (iOS 18+, where the
    /// detector runs). A single animated `scrollTo` suffices: with
    /// eager rows the target offset is exact, so there is nothing to
    /// overshoot and nothing to correct.
    @ViewBuilder
    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        if showScrollToBottom && !messages.isEmpty {
            Button {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.bottomAnchorId, anchor: .bottom)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(config.appearance.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(config.appearance.surface)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
            .transition(.opacity.combined(with: .scale))
            .accessibilityLabel("Scroll to latest message")
        }
    }

    /// Single message row.
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
        } else {
            MessageView(
                message: message,
                config: config,
                showDebug: config.enableDebugMode,
                onRetry: message.role == .user || message.role == .assistant ? {
                    onRetry(index)
                } : nil,
                onEdit: message.role == .user && onBeginEdit != nil ? {
                    onBeginEdit?(index, message.content)
                } : nil,
                onSpeak: speakAction(for: message),
                isSpeaking: message.id == speakingMessageId,
                onCopy: onCopy,
                showAgentAvatar: config.showPresenceOrb,
                agentAvatarSpeaking: agentIsSpeaking
                    && message.id == latestAssistantId,
                onBlockAction: onBlockAction
            )
            .id(message.id)
        }
    }

    /// Per-row Play action, or `nil` to hide the affordance.
    ///
    /// Gated twice: the host must have supplied ``onSpeak`` at all (TTS
    /// enabled), and the row must be an assistant *text* reply. Tool
    /// calls, tool results and content-block rows carry no prose worth
    /// reading aloud.
    private func speakAction(for message: Message) -> (() -> Void)? {
        guard let onSpeak = onSpeak else { return nil }
        guard message.role == .assistant,
              message.type != .toolCall,
              message.type != .toolResult,
              message.type != .contentBlocks else { return nil }
        return { onSpeak(message) }
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
        } else if isLoading && !isStreamingReplyVisible {
            HStack {
                ProgressView().progressViewStyle(CircularProgressViewStyle())
                Text("Thinking...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }

    /// `true` once the assistant's reply is visibly streaming — the tail
    /// is an assistant text bubble with content. `isLoading` stays true
    /// for the whole turn, but the "Thinking..." spinner should only
    /// cover the gap before the first token: alongside a growing reply
    /// it's redundant noise.
    private var isStreamingReplyVisible: Bool {
        guard let last = messages.last else { return false }
        return last.role == .assistant
            && last.type != .toolCall
            && last.type != .toolResult
            && last.type != .subAgentStart
            && last.type != .subAgentEnd
            && last.type != .agentContext
            && !last.content.isEmpty
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
                // Center vertically inside the scroll content — the list
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
/// Bottom anchoring with iMessage semantics; no-op before iOS 18.
///
/// Deliberately NOT the plain `defaultScrollAnchor(.bottom)`: that also
/// sets the `.alignment` role, which bottom-aligns content that doesn't
/// fill the viewport — an empty chat's thinking spinner ends up alone at
/// the foot of a blank page. Setting only the offset roles gives:
///
///   * short conversations start at the TOP and grow downward,
///   * opening a long conversation lands at the newest message
///     (`.initialOffset`),
///   * streaming keeps the bottom pinned while the user is at the
///     bottom, and leaves them alone once they've scrolled up
///     (`.sizeChanges`) — the derived follow behaviour.
private struct NativeBottomAnchorModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            content
        }
    }
}

/// Reports the start of a finger-drag on the scroll view (iOS 18 /
/// macOS 15); no-op earlier. Phases distinguish what geometry cannot:
/// a drag reports `.tracking`/`.interacting`, while content growth and
/// programmatic scrolls do not — so only a deliberate user gesture
/// switches the streaming follow off. Re-engagement is the
/// ``ScrollAwayDetector``'s job (the follow returns when the jump
/// button hides).
private struct StreamFollowGovernor: ViewModifier {
    /// Fired on every scroll-phase transition with the phase's name and
    /// whether it is a finger-drag phase (the follow's only off-switch).
    /// Reporting all phases (not just drags) feeds the debug HUD, so a
    /// spurious drag report — e.g. a phase change our own programmatic
    /// scrolls provoke — is visible rather than inferred.
    let onPhase: (String, Bool) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollPhaseChange { _, newPhase, _ in
                switch newPhase {
                case .tracking, .interacting:
                    onPhase(String(describing: newPhase), true)
                default:
                    onPhase(String(describing: newPhase), false)
                }
            }
        } else {
            content
        }
    }
}

/// Reports when the user scrolls away from (or back to) the bottom,
/// using the scroll view's own geometry callback (iOS 18 / macOS 15).
/// The transform reduces geometry to a Bool, and SwiftUI only invokes
/// the action when that Bool changes — so this cannot write state per
/// frame. With eager rows the geometry it reads is exact, not
/// estimated. No-op on older OSes (the pre-18 path has no jump button).
private struct ScrollAwayDetector: ViewModifier {
    let threshold: CGFloat
    let onChange: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { g in
                    let distanceFromBottom = g.contentSize.height
                        + g.contentInsets.bottom
                        - g.containerSize.height
                        - g.contentOffset.y
                    return distanceFromBottom > threshold
                } action: { _, away in
                    onChange(away)
                }
        } else {
            content
        }
    }
}

#if DEBUG
/// Scripted harness: verifies the "Load earlier" anchor restore and
/// that a simulated send pins to the bottom — no network or running
/// ChatViewModel required.
struct MessageListScrollHarness: View {
    @State private var messages: [Message] = MessageListScrollHarness.seed()
    @State private var isLoading: Bool = false
    @State private var hasMoreMessages: Bool = true
    @State private var loadingMoreMessages: Bool = false
    @State private var olderBatches: Int = 0

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
                onRetry: { _ in }
            )
            HStack {
                Button("Send") {
                    messages.append(Message(
                        id: "sent-\(messages.count)",
                        role: .user,
                        content: "Simulated send \(messages.count)."
                    ))
                }
                Button("Reset") {
                    messages = Self.seed()
                    isLoading = false
                    hasMoreMessages = true
                    olderBatches = 0
                }
            }
            .padding()
        }
    }

    private func simulateLoadMore() {
        loadingMoreMessages = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            let batch = olderBatches
            let older = (1...5).map { i in
                Message(
                    id: "older-\(batch)-\(i)",
                    role: .user,
                    content: "Older message (batch \(batch), \(i)) — prepended by pagination."
                )
            }
            messages.insert(contentsOf: older, at: 0)
            olderBatches += 1
            hasMoreMessages = olderBatches < 4
            loadingMoreMessages = false
        }
    }
}

struct MessageListView_Previews: PreviewProvider {
    static var previews: some View {
        MessageListScrollHarness()
            .previewDisplayName("Eager VStack — pagination + send")
    }
}
#endif
