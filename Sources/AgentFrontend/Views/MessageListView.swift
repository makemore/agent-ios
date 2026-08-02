import SwiftUI
import AgentClient
#if canImport(UIKit)
import UIKit
#endif

/// Message list view. Automated scrolling is limited to two moments:
///
///   1. **Opening a conversation** — the list lands at the end, so the
///      newest message is on screen rather than the top of the scrollback.
///   2. **Sending a message** — the list scrolls to its end, settling the
///      just-sent message directly above the composer.
///
/// Nothing scrolls during streaming. The agent's reply grows below the
/// fold and the user stays where they are; a jump-to-bottom button appears
/// once the content bottom sits more than `nearBottomThresholdPt` below
/// the viewport, and tapping it returns to the newest message.
///
/// Pagination ("Load earlier") prepends older messages and restores the
/// previously-first-visible message to the top, so reading position
/// doesn't jump.
///
/// This matches the prevailing pattern in modern chat UIs (Claude,
/// ChatGPT, iMessage, etc.): no surprise scroll-jacking on streaming, the
/// user is always in control apart from the two moments above. Hosts that
/// want different behaviour can layer their own `ScrollViewReader` +
/// `proxy.scrollTo` on top of this view.
public struct MessageListView: View {
    let messages: [Message]
    let isLoading: Bool
    let hasMoreMessages: Bool
    let loadingMoreMessages: Bool
    let config: ChatWidgetConfig
    let onLoadMore: () -> Void
    let onRetry: (Int) -> Void
    let onEdit: (Int, String) -> Void
    /// Speak a message aloud. Receives the message's text so the host
    /// owns the TTS plumbing; the list only decides *which* rows get a
    /// Play affordance (assistant text, never user or tool rows).
    /// `nil` when the host has TTS disabled, which hides Play entirely.
    let onSpeak: ((String) -> Void)?
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
        onEdit: @escaping (Int, String) -> Void,
        onSpeak: ((String) -> Void)? = nil,
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
        self.onEdit = onEdit
        self.onSpeak = onSpeak
        self.onCopy = onCopy
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
    /// Named coordinate space the content stack reports its frame in.
    private static let scrollSpace = "message-list-scroll"
    /// How far the content bottom must sit below the viewport before the
    /// jump-to-bottom button appears. Roughly half a short message, so the
    /// button doesn't flicker in and out during normal reading.
    private static let nearBottomThresholdPt: CGFloat = 80
    /// Lower edge of the hysteresis band — once visible, the button stays
    /// until the content bottom is within this distance of the viewport.
    private static let hideBottomThresholdPt: CGFloat = 40
    /// How long the scroll geometry must hold still before the button's
    /// visibility is recomputed. Long enough to swallow the bogus
    /// measurements published mid-rebuild during streaming.
    private static let visibilityDebounce: TimeInterval = 0.15

    /// Whether the user has scrolled far enough from the newest message
    /// to warrant the jump-to-bottom affordance.
    ///
    /// This is the *only* piece of state driven by scroll geometry. An
    /// earlier version also stored the raw offset and height, which
    /// deadlocked the app: `onPreferenceChange` wrote `@State` on every
    /// layout pass, each write invalidated the view, the re-layout
    /// republished the preference, and the cycle never settled.
    @State private var showScrollToBottom = false

    /// Master switch for the jump-to-bottom affordance. Flip to `false` to
    /// remove the button and all of its geometry tracking without touching
    /// the scroll-on-open / scroll-on-send behaviour, which are independent.
    ///
    /// OFF for the current experiment: the send-path freeze wedges inside
    /// SwiftUI layout with no diagnostic marker firing, and this geometry
    /// preference is the only code of ours that runs on every layout pass.
    /// If the freeze survives with this off, the plumbing is exonerated and
    /// the suspect becomes the bottom-anchor scroll ladder.
    private static let scrollToBottomButtonEnabled = false

    /// Non-observed coordination state.
    ///
    /// Deliberately a *class* held in `@State`: mutating its properties does
    /// not invalidate the view, so bookkeeping here can't itself cause the
    /// re-render storm we're trying to observe. `@State var someInt` would
    /// be self-defeating.
    final class ScrollCoordinator {
        /// Most recent geometry, held here rather than in `@State` so
        /// recording it can't trigger a render.
        var latestMetrics = ScrollMetrics()
        var latestViewport: CGFloat = 0
        /// Debounce timer for the visibility evaluation.
        var pendingEval: DispatchWorkItem?
        // Diagnostics counters — ungated alongside the [ScrollDiag] prints
        // that read them (see HangDiagnostics for why #if DEBUG is
        // unreliable in this package).
        var callbacks = 0
        var stateWrites = 0
        var bodyEvals = 0
        var windowStart = CFAbsoluteTimeGetCurrent()
        var lastMetricLog = 0.0
        var watchdogInstalled = false
    }
    @State private var coord = ScrollCoordinator()

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
        // Ungated with the rest of HangDiagnostics — see that file's note on
        // custom build configurations silently stripping #if DEBUG in the
        // package.
        let _ = { coord.bodyEvals += 1 }()
        let _ = HangDiagnostics.mark("MessageListView body (\(messages.count) messages)")
        return ScrollViewReader { proxy in
            scrollContent
                .onAppear { installMainThreadWatchdog() }
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
        }
    }

    /// Tail watcher callback. Fires whenever the tail message
    /// changes (i.e. a new message was appended). If the new tail
    /// is a user message, scrolls to the end of the list so the
    /// just-sent message settles just above the composer.
    ///
    /// The observed value is a composite `"role|id"` key — role and
    /// id are decoded from the closure parameter rather than read
    /// from `messages`, which is stale inside the closure (see
    /// ``tailKey``).
    ///
    /// On timing: the `scrollTo` is re-issued a few times over ~600ms
    /// (see ``scrollToBottom(proxy:)``). Plain `asyncAfter` hops are used
    /// instead of a `Task { await ... }` because they don't suspend: an
    /// earlier `Task`-based version could resume after the
    /// `ScrollViewReader`'s underlying reader was re-evaluated and crashed
    /// with `EXC_BAD_ACCESS`.
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
        // (streaming placeholders, errors) also change the tail, but they
        // must not move the list — the reply grows below the fold and the
        // user decides whether to follow it, via the jump-to-bottom button.
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
        scrollToBottom(proxy: proxy)
    }

    /// Pin the trailing sentinel to the bottom of the viewport.
    ///
    /// Re-issued over ~600ms because both appending a turn group and
    /// loading a conversation wholesale grow the content by more than a
    /// viewport, and a scroll issued before the `ScrollView` commits the
    /// new content size clamps to the old maximum offset. The call is
    /// idempotent once it lands, so repeating it costs nothing and
    /// survives the race (including the keyboard-dismiss viewport resize
    /// that overlaps a send).
    /// Recompute whether the jump-to-bottom button should be visible.
    ///
    /// `metrics.offsetY + metrics.height` is the content's bottom edge in
    /// viewport coordinates. When that exceeds the viewport height by more
    /// than the threshold, there's material content below the fold.
    /// Record the latest geometry and schedule a debounced evaluation.
    ///
    /// Evaluating per frame is what wedged the app. A re-render — a
    /// streaming delta, or `agentIsSpeaking` toggling — republishes this
    /// preference *mid-rebuild*, when the `LazyVStack` reports a height
    /// that is briefly wrong by more than a viewport. Acting on that
    /// transient flipped the button, which forced another render, which
    /// produced another transient. Waiting for the geometry to settle
    /// discards those entirely; the delay is imperceptible for a button
    /// that only says "you're not at the bottom".
    private func recordMetrics(_ metrics: ScrollMetrics, viewportHeight: CGFloat) {
        coord.latestMetrics = metrics
        coord.latestViewport = viewportHeight

        coord.pendingEval?.cancel()
        let work = DispatchWorkItem {
            updateScrollToBottomVisibility(metrics: coord.latestMetrics,
                                           viewportHeight: coord.latestViewport)
        }
        coord.pendingEval = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibilityDebounce,
                                      execute: work)
    }

    private func updateScrollToBottomVisibility(metrics: ScrollMetrics,
                                                viewportHeight: CGFloat) {
        coord.callbacks += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - coord.windowStart >= 1.0 {
            let elapsed = now - coord.windowStart
            print(String(format: "[ScrollDiag] %.0f cb/s, %.0f bodyEvals/s, %d writes | offsetY=%.1f height=%.1f viewport=%.1f",
                         Double(coord.callbacks) / elapsed,
                         Double(coord.bodyEvals) / elapsed,
                         coord.stateWrites,
                         metrics.offsetY, metrics.height, viewportHeight))
            coord.callbacks = 0
            coord.bodyEvals = 0
            coord.stateWrites = 0
            coord.windowStart = now
        }

        guard viewportHeight > 0, metrics.height > 0 else {
            if CFAbsoluteTimeGetCurrent() - coord.lastMetricLog > 1.0 {
                coord.lastMetricLog = CFAbsoluteTimeGetCurrent()
                print("[ScrollDiag] skipped — viewport=\(viewportHeight) height=\(metrics.height)")
            }
            return
        }

        let distanceFromBottom = (metrics.offsetY + metrics.height) - viewportHeight

        // Hysteresis: appear at 80pt, disappear at 40pt. With a single
        // threshold, resting near the boundary flips the flag on every
        // frame the geometry reports — and each flip re-renders the list.
        let shouldShow: Bool
        if showScrollToBottom {
            shouldShow = distanceFromBottom > Self.hideBottomThresholdPt
        } else {
            shouldShow = distanceFromBottom > Self.nearBottomThresholdPt
        }

        guard shouldShow != showScrollToBottom else { return }

        coord.stateWrites += 1
        print(String(format: "[ScrollDiag] flip → %@ (distance=%.1f)",
                     shouldShow ? "SHOW" : "HIDE", distanceFromBottom))

        // Safe to write directly: this runs from the debounce timer, a
        // clean runloop turn, not inside the layout pass that produced
        // the measurement.
        showScrollToBottom = shouldShow
    }

    /// Circular jump-to-bottom button. Only rendered when the user has
    /// drifted away from the newest message.
    @ViewBuilder
    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        if Self.scrollToBottomButtonEnabled && showScrollToBottom && !messages.isEmpty {
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

    /// Start hang detection. See ``HangDiagnostics`` — it reports the
    /// stall *and* the last thing the main thread began, which the bare
    /// watchdog this replaced could not.
    private func installMainThreadWatchdog() {
        HangDiagnostics.start()
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        print("[ScrollDiag] scrollToBottom requested (messages=\(messages.count))")
        for delay in [0.0, 0.1, 0.3, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                HangDiagnostics.mark("scrollTo bottom anchor")
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

        // Initial load of an existing conversation: land on the newest
        // message instead of the top of the scrollback. This is the
        // empty → populated transition, which ``handleTailChange``
        // deliberately ignores (it only reacts to a *user* tail, and skips
        // the first message of a list). Requiring more than one message
        // keeps a brand-new conversation's opening line alone — that
        // content fits, and there's nothing to scroll away from.
        if countBeforeThisChange == 0 && newCount > 1 {
            scrollToBottom(proxy: proxy)
            return
        }

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

    @ViewBuilder
    private var scrollContent: some View {
        // GeometryReader supplies the viewport height, which is the
        // denominator for "how far from the bottom are we" — see
        // ``updateScrollToBottomVisibility``.
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
                    // RESTORED after a hard lesson: the current turn
                    // renders as one group whose `minHeight` is the viewport
                    // height. This reservation is load-bearing for layout
                    // stability, not just scroll positioning — with uniform
                    // rows, text streaming into the LazyVStack changes row
                    // heights every typewriter tick and the lazy layout's
                    // size negotiation never converges. The main thread
                    // spins inside LazyVStackLayout / AG::Graph::update
                    // indefinitely (2-minute hangs, stacks captured in the
                    // debugger, zero app frames). The reserved space keeps
                    // every proposal stable while the reply grows into it.
                    //
                    // Cost: a just-sent message parks at the TOP of the
                    // viewport with blank space below, rather than settling
                    // above the composer. That's the old UX, deliberately —
                    // a bottom-anchored send needs a design that doesn't
                    // fight the lazy layout, which is future work, done
                    // with Chris rather than around him.
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

                    // Static scroll target. Scrolling it to `.bottom` pins
                    // the whole current turn (whose minHeight fills the
                    // viewport) on screen — the just-sent user message
                    // lands at the top.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorId)
                }
                .padding()
                // Publish the content stack's position and height on every
                // frame of a scroll. `minY` is negative once scrolled, so
                // `minY + height` is the content's bottom edge expressed in
                // viewport coordinates — that's what tells us whether the
                // user has drifted up away from the newest message.
                .background(
                    // Publisher gated with the kill switch, not just the
                    // handler — a GeometryReader in the background still
                    // participates in every layout pass even when its
                    // preference is ignored, which would contaminate the
                    // "is the geometry tracking the problem" experiment.
                    Group {
                        if Self.scrollToBottomButtonEnabled {
                            GeometryReader { contentGeo in
                                let frame = contentGeo.frame(in: .named(Self.scrollSpace))
                                Color.clear.preference(
                                    key: ScrollMetricsPreferenceKey.self,
                                    value: ScrollMetrics(offsetY: frame.minY,
                                                         height: frame.height)
                                )
                            }
                        }
                    }
                )
            }
            .coordinateSpace(name: Self.scrollSpace)
            // One Equatable preference, not two. SwiftUI only delivers this
            // when the value actually changes, and the handler writes state
            // only on a threshold crossing — so a scroll can't drive an
            // endless invalidate/re-layout cycle.
            .onPreferenceChange(ScrollMetricsPreferenceKey.self) { metrics in
                guard Self.scrollToBottomButtonEnabled else { return }
                recordMetrics(metrics, viewportHeight: geo.size.height)
            }
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
                onSpeak: speakAction(for: message),
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
        return { onSpeak(message.content) }
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

/// Scroll geometry for the message list's content stack, published as a
/// single `Equatable` value.
///
/// Deliberately one preference rather than two: `onPreferenceChange` only
/// fires when the value genuinely changes, so bundling offset and height
/// together avoids two independent callbacks each re-triggering layout.
struct ScrollMetrics: Equatable {
    /// Content stack's top edge in scroll coordinates — negative once scrolled.
    var offsetY: CGFloat = 0
    /// Content stack's total height.
    var height: CGFloat = 0
}

private struct ScrollMetricsPreferenceKey: PreferenceKey {
    static let defaultValue = ScrollMetrics()

    /// Ignore empty contributions rather than letting the last one win.
    ///
    /// Every view in the subtree contributes `defaultValue` unless it sets
    /// the key, so an unconditional `value = nextValue()` can end up
    /// delivering a zeroed measurement — which the visibility check then
    /// discards via its `height > 0` guard, leaving the button permanently
    /// hidden. Only a real measurement (non-zero height) should win.
    static func reduce(value: inout ScrollMetrics, nextValue: () -> ScrollMetrics) {
        let next = nextValue()
        guard next.height > 0 else { return }
        value = next
    }
}
