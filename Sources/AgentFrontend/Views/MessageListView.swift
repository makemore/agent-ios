import SwiftUI
import AgentClient
#if canImport(UIKit)
import UIKit
#endif

/// Preference key reporting the bottom-anchor's y-position within the scroll
/// view's named coordinate space. `minY` here is relative to the viewport
/// origin, so the value is approximately `viewportHeight` when the anchor is
/// at the bottom of the visible area, and `viewportHeight + scrolledUpBy` when
/// the user has scrolled away from the bottom.
private struct BottomAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Preference key reporting the scroll container's visible height.
private struct ScrollViewHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Pure decision layer for scroll behaviour. Kept free of SwiftUI types so it
/// can be exercised by unit tests without a running view hierarchy. The view
/// body translates the returned action into a `proxy.scrollTo` call.
enum ScrollAction: Equatable {
    case none
    /// Pin the bottom anchor to the viewport bottom. `delayMs` is the wait
    /// before committing; used to let the UIKit keyboard-hide animation
    /// (~250ms) and post-insertion layout settle before scrolling. A
    /// too-early scroll lands on an intermediate geometry and drifts as the
    /// animations complete.
    case pinBottom(delayMs: UInt64)
    case preserveTopAnchor(id: String)
}

enum ScrollDecision {
    /// Delay applied to a user-submit pin, in milliseconds. Covers the iOS
    /// keyboard dismissal (~250ms) plus a buffer for LazyVStack measurement
    /// of the just-inserted row. The keyboard animation is a UIKit
    /// safe-area inset transition that lives outside SwiftUI's Transaction
    /// system, so we cannot suppress it; we wait past it instead.
    static let userSubmitDelayMs: UInt64 = 400

    /// Decide what (if anything) to do in response to a messages-count change.
    /// All inputs are tick-local view state — no ambient globals — so the same
    /// inputs always yield the same action.
    static func onCountChange(
        oldCount: Int,
        newCount: Int,
        lastMessageIsUser: Bool,
        isNearBottom: Bool,
        pendingAnchorId: String?
    ) -> ScrollAction {
        // Pagination prepend: a load-earlier commit.
        if newCount > oldCount, oldCount > 0, let anchor = pendingAnchorId {
            return .preserveTopAnchor(id: anchor)
        }
        // First messages arriving in an empty view (conversation restore).
        if oldCount == 0, newCount > 0 {
            return .pinBottom(delayMs: 0)
        }
        // Append at the tail.
        if newCount > oldCount {
            // A user-submit always pins and waits past the keyboard-hide
            // animation. Assistant appends while near-bottom pin immediately.
            if lastMessageIsUser {
                return .pinBottom(delayMs: userSubmitDelayMs)
            }
            if isNearBottom {
                return .pinBottom(delayMs: 0)
            }
        }
        return .none
    }
}

/// Message list view with smart scroll behaviour.
///
/// Scroll architecture (see PR description for the audit that motivated it):
/// - Scroll intent is explicit at each decision point, not derived from a live
///   preference heuristic that can flicker during layout transitions.
/// - A single target — `bottom-anchor` — is used for every pin-to-bottom. The
///   Thinking indicator is never a scroll target and carries no `.id`.
/// - Pin commits always run inside a `disablesAnimations` transaction so they
///   cannot inherit an ambient SwiftUI animation from a row transition.
/// - Implicit structural animations on row insertion are suppressed via
///   `.animation(nil, value: messages.count)` and `.animation(nil, value:
///   isLoading)` on the `LazyVStack`. This prevents the ~150ms insert
///   animation from coinciding with the 250ms UIKit keyboard-hide
///   safe-area transition on submit.
/// - A user-submit force-pins and waits `ScrollDecision.userSubmitDelayMs`
///   (400ms) before committing, so the scroll lands on the post-keyboard,
///   post-insertion final layout rather than an intermediate geometry.
/// - A second commit fires 80ms after any pin to catch residual layout drift.
/// - Streaming scrolls are unanimated and throttled to 30Hz; animated
///   streaming produced interpolation restarts that manifested as stutter.
/// - "Is user near bottom" is sampled at the moment of decision from the two
///   preference values; it is not a live gate that can flicker mid-keyboard.
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
    /// pill mode the list renders a quiet activity pill in place of the
    /// generic "Thinking..." spinner. Defaults to an empty state so the
    /// existing `MessageListView(...)` call sites and harness keep
    /// working unchanged.
    let activity: SubAgentActivityState
    /// `true` when the agent's TTS playback is in flight. Propagated
    /// down to the latest assistant `MessageView` so its avatar can
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

    // MARK: Scroll tracking state

    /// Raw bottom-anchor y in the "messageScroll" named coordinate space.
    @State private var bottomAnchorY: CGFloat = 0
    /// Raw viewport height of the scroll container.
    @State private var viewportHeight: CGFloat = 0
    /// Message count snapshot at the previous count-change tick.
    @State private var previousMessageCount: Int = 0
    /// Anchor id set by the "Load earlier" button; consumed on the next
    /// count-change. Reset on every count-change (not just the prepend branch)
    /// so a failed pagination cannot leak the anchor into a later append.
    @State private var anchorMessageId: String?
    /// Identity of the last-rendered message; used to separate streaming
    /// (same id, content grew) from insertion (new id).
    @State private var lastRenderedMessageId: String?
    /// 30 Hz throttle window for streaming follow-scrolls — cheap SSE-burst
    /// guard, not a correctness knob (scrolls are unanimated, so no tail).
    @State private var lastStreamScrollAt: Date = .distantPast
    /// Coalesces multiple pin requests within a runloop window into one
    /// scrollTo call, so redundant triggers cannot stack.
    @State private var pinInFlight: Bool = false

    public var body: some View {
        ScrollViewReader { proxy in
            scrollContent(proxy: proxy)
                .coordinateSpace(name: "messageScroll")
                // Background uses the appearance token so the scroll
                // viewport blends into the surrounding shell instead of
                // flashing the system background through gaps. The
                // GeometryReader sits *on top* via a separate background
                // modifier so it doesn't get covered.
                .background(config.appearance.background)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ScrollViewHeightPreferenceKey.self,
                            value: geo.size.height
                        )
                    }
                )
                .onPreferenceChange(BottomAnchorPreferenceKey.self) { bottomAnchorY = $0 }
                .onPreferenceChange(ScrollViewHeightPreferenceKey.self) { viewportHeight = $0 }
                .onChange(of: messages.count) { newCount in
                    handleCountChange(newCount: newCount, proxy: proxy)
                }
                .onChange(of: messages.last?.content) { _ in
                    handleContentChange(proxy: proxy)
                }
                .onAppear {
                    previousMessageCount = messages.count
                    lastRenderedMessageId = messages.last?.id
                    guard !messages.isEmpty else { return }
                    requestPinBottom(proxy: proxy, delayMs: 0)
                }
        }
    }

    // MARK: Scroll decision handlers

    private var isNearBottom: Bool {
        // Treat unmeasured viewport as at-bottom: the first frame after mount
        // has no preference values yet and we always want to land at bottom.
        guard viewportHeight > 0 else { return true }
        return bottomAnchorY - viewportHeight < config.nearBottomThresholdPt
    }

    private func handleCountChange(newCount: Int, proxy: ScrollViewProxy) {
        let oldCount = previousMessageCount
        previousMessageCount = newCount
        // Always consume any pending pagination anchor, even if this isn't a
        // prepend: if pagination failed or the user submitted instead, we want
        // a clean slate for the next load-more.
        let pendingAnchor = anchorMessageId
        anchorMessageId = nil

        let action = ScrollDecision.onCountChange(
            oldCount: oldCount,
            newCount: newCount,
            lastMessageIsUser: messages.last?.role == .user,
            isNearBottom: isNearBottom,
            pendingAnchorId: pendingAnchor
        )
        // Keep the identity tracker in sync so the streaming handler, which
        // fires immediately after this one on content changes, can distinguish
        // "same message grew" from "new message inserted".
        lastRenderedMessageId = messages.last?.id

        switch action {
        case .none:
            return
        case .pinBottom(let delayMs):
            requestPinBottom(proxy: proxy, delayMs: delayMs)
        case .preserveTopAnchor(let id):
            commitPreserveTopAnchor(proxy: proxy, id: id)
        }
    }

    private func handleContentChange(proxy: ScrollViewProxy) {
        let currentId = messages.last?.id
        let idChanged = currentId != lastRenderedMessageId
        lastRenderedMessageId = currentId
        // Identity change: a new message was inserted — the count handler has
        // already committed the appropriate scroll. Do not layer a second.
        guard !idChanged else { return }
        // Host-app opt-out: when streaming follow is disabled the list stays
        // put and the user controls scrolling while the reply generates.
        guard config.followStreamingEnabled else { return }
        // Follow the streaming reply only if the user hasn't scrolled away.
        guard isNearBottom else { return }
        // 30 Hz throttle — cheap guard against SSE bursts, not a correctness
        // knob. Instant (unanimated) scrolls produce no visual jank at this
        // rate; the previous `linear(0.1)` animation is what produced the
        // "sticking/glitching" because overlapping token arrivals restarted
        // the interpolation mid-flight.
        let now = Date()
        guard now.timeIntervalSince(lastStreamScrollAt) >= 0.033 else { return }
        lastStreamScrollAt = now
        commitPinNow(proxy: proxy)
    }

    // MARK: Scroll commit primitives

    /// Coalesced pin-to-bottom with optional delay.
    ///
    /// `delayMs = 0` is the hot path (initial load, pagination, streaming):
    /// two `Task.yield()`s let the LazyVStack's post-insertion layout pass
    /// settle, then we commit.
    ///
    /// `delayMs > 0` is the user-submit path. When the user taps send, three
    /// animations fire concurrently:
    ///   1. UIKit keyboard dismissal (~250ms, safe-area inset transition,
    ///      lives *outside* SwiftUI's Transaction system — `disablesAnimations`
    ///      cannot touch it).
    ///   2. SwiftUI structural insert animation for the user row.
    ///   3. SwiftUI structural insert animation for the "Thinking…" row.
    /// A scrollTo fired while any of these is in flight computes against an
    /// intermediate geometry; once the keyboard settles, the scroll position
    /// is stale and the just-inserted row appears to fly off-screen. Waiting
    /// past the longest animation (the keyboard) and then committing lands
    /// on the final geometry. We also re-commit 80ms later as belt-and-
    /// suspenders against any residual row-measurement drift.
    private func requestPinBottom(proxy: ScrollViewProxy, delayMs: UInt64) {
        guard !pinInFlight else { return }
        pinInFlight = true
        Task { @MainActor in
            if delayMs > 0 {
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            } else {
                await Task.yield()
                await Task.yield()
            }
            commitPinNow(proxy: proxy)
            // Second commit catches any residual layout drift (e.g. a tall
            // row that finished measuring just after the first commit).
            // No-op if already at bottom.
            try? await Task.sleep(nanoseconds: 80_000_000)
            commitPinNow(proxy: proxy)
            pinInFlight = false
        }
    }

    /// Low-level pin commit. Always runs inside a `disablesAnimations`
    /// transaction so it cannot inherit an ambient SwiftUI animation from a
    /// view transition or implicit insert.
    private func commitPinNow(proxy: ScrollViewProxy) {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    }

    /// Scroll the previously-first-visible message back to the top after a
    /// pagination prepend, so the user's reading position is preserved.
    private func commitPreserveTopAnchor(proxy: ScrollViewProxy, id: String) {
        Task { @MainActor in
            await Task.yield()
            await Task.yield()
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                proxy.scrollTo(id, anchor: .top)
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
    private func scrollContent(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                // Load more button at top
                if hasMoreMessages {
                    Button {
                        if let firstMsg = messages.first {
                            anchorMessageId = firstMsg.id
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
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
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

                // Loading indicator. No `.transition(...)` and no `.id` here:
                // the row is never a scroll target, and an implicit insert
                // animation would coincide with the keyboard-dismissal safe-
                // area transition and produce a visible layout bleed. The
                // parent's `.animation(nil, value: isLoading)` (below) further
                // suppresses any implicit insert animation.
                //
                // Pill mode + active sub-agent → render the activity pill in
                // place of the generic spinner so the user sees which
                // specialist is running and a tail of its narration. Falls
                // back to the spinner whenever the bracket isn't open (e.g.
                // the parent itself is composing the final reply).
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

                // Bottom anchor — reports its position for scroll tracking
                GeometryReader { geo in
                    Color.clear.preference(
                        key: BottomAnchorPreferenceKey.self,
                        value: geo.frame(in: .named("messageScroll")).minY
                    )
                }
                .frame(height: 1)
                .id("bottom-anchor")
            }
            .padding()
            // Suppress SwiftUI's implicit structural-change animation on the
            // two value-changes that drive scroll targeting: a new message
            // and the Thinking-row toggle. Without this, inserting a row
            // fades/slides it in over ~150ms, which coincides with the
            // 250ms UIKit keyboard-dismiss safe-area animation on submit
            // and produces the "fly-off" drift. Structural changes now
            // apply instantly; the scroll commit (delayed past the keyboard
            // animation) lands on the final, stable layout.
            .animation(nil, value: messages.count)
            .animation(nil, value: isLoading)
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
/// Scripted harness that reproduces the submit / streaming / terminate cycle
/// without the network or a running ChatViewModel. Lives beside the view so
/// regressions in the scroll state machine surface in Xcode previews.
///
/// Steps:
///  - t=0.0s: mount with 15 prior messages, scrolled to bottom.
///  - t=0.5s: "user submit" — append a user message and flip `isLoading` true
///            in the same tick (the combination that triggers the fly-off).
///  - t=2.0s: insert a streaming assistant message and grow its content over
///            5 seconds to exercise streaming follow-scroll.
///  - t=7.5s: flip `isLoading` false (terminal event).
///  - Tap "reset" to re-run the sequence.
///
/// Manual verification: at every point, the latest visible message should be
/// just above the bottom safe-area inset. No row should ever fly off-screen.
struct MessageListScrollHarness: View {
    @State private var messages: [Message] = MessageListScrollHarness.seed()
    @State private var isLoading: Bool = false
    @State private var running: Bool = false

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
                hasMoreMessages: false,
                loadingMoreMessages: false,
                config: ChatWidgetConfig(),
                onLoadMore: {},
                onRetry: { _ in },
                onEdit: { _, _ in }
            )
            HStack {
                Button("Run submit+stream") { runScript() }
                    .disabled(running)
                Button("Reset") {
                    messages = Self.seed()
                    isLoading = false
                    running = false
                }
            }
            .padding()
        }
    }

    private func runScript() {
        running = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            // Submit: user message + isLoading true in the same tick.
            isLoading = true
            messages.append(Message(
                id: "user-\(Date().timeIntervalSince1970)",
                role: .user,
                content: "What does the scroll harness do?"
            ))

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let streamId = "assistant-stream-\(Date().timeIntervalSince1970)"
            messages.append(Message(id: streamId, role: .assistant, content: ""))

            let tokens = "The scroll harness scripts a deterministic submit, streaming reply, and terminal event so regressions in the MessageListView scroll state machine surface without a backend. It exists precisely because prior scroll fixes kept hiding races that only manifested under real network timing."
            for ch in tokens {
                try? await Task.sleep(nanoseconds: 30_000_000)
                if let idx = messages.firstIndex(where: { $0.id == streamId }) {
                    messages[idx].content.append(ch)
                }
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
            isLoading = false
            running = false
        }
    }
}

struct MessageListView_Previews: PreviewProvider {
    static var previews: some View {
        MessageListScrollHarness()
            .previewDisplayName("Scroll harness — submit / stream / terminate")
    }
}
#endif
