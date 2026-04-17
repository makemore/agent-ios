import SwiftUI
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
    case pinBottom
    case preserveTopAnchor(id: String)
}

enum ScrollDecision {
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
            return .pinBottom
        }
        // Append at the tail.
        if newCount > oldCount {
            // A user-submit always pins — by definition the user wants to see
            // what they just sent, regardless of where they were scrolled.
            if lastMessageIsUser || isNearBottom {
                return .pinBottom
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
///   `loading` indicator is never a scroll target (it is lazy and transient).
/// - Pin commits wait two runloop turns and run inside a transaction with
///   `disablesAnimations = true`, so in-flight keyboard / view-transition
///   animations cannot bleed into the scroll position.
/// - "Is user near bottom" is sampled at the moment of decision from the two
///   preference values; it is not a live gate that can flicker mid-keyboard.
/// - A user-submit force-pins regardless of the near-bottom sample.
public struct MessageListView: View {
    let messages: [Message]
    let isLoading: Bool
    let hasMoreMessages: Bool
    let loadingMoreMessages: Bool
    let config: ChatWidgetConfig
    let onLoadMore: () -> Void
    let onRetry: (Int) -> Void
    let onEdit: (Int, String) -> Void

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
    /// 10 Hz throttle window for animated streaming follow-scrolls.
    @State private var lastStreamScrollAt: Date = .distantPast
    /// Coalesces multiple pin requests within a runloop window into one
    /// scrollTo call, so redundant triggers cannot stack.
    @State private var pinInFlight: Bool = false

    public var body: some View {
        ScrollViewReader { proxy in
            scrollContent(proxy: proxy)
                .coordinateSpace(name: "messageScroll")
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
                    requestPinBottom(proxy: proxy, animated: false)
                }
        }
    }

    // MARK: Scroll decision handlers

    private var isNearBottom: Bool {
        // Treat unmeasured viewport as at-bottom: the first frame after mount
        // has no preference values yet and we always want to land at bottom.
        guard viewportHeight > 0 else { return true }
        return bottomAnchorY - viewportHeight < 100
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
        case .pinBottom:
            requestPinBottom(proxy: proxy, animated: false)
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
        // Follow the streaming reply only if the user hasn't scrolled away.
        guard isNearBottom else { return }
        let now = Date()
        guard now.timeIntervalSince(lastStreamScrollAt) >= 0.1 else { return }
        lastStreamScrollAt = now
        requestPinBottom(proxy: proxy, animated: true)
    }

    // MARK: Scroll commit primitives

    /// Single pin-to-bottom commit point. Coalesces multiple requests that
    /// arrive within the same runloop window into one scrollTo call.
    ///
    /// Why two `Task.yield()` turns: SwiftUI's layout pass for the inserted
    /// row, and any safe-area adjustment for a dismissing keyboard, settle
    /// over one-to-two runloop turns. A scrollTo that fires too early lands on
    /// the pre-insertion bottom position.
    ///
    /// Why the explicit `disablesAnimations` transaction: a dispatched scroll
    /// would otherwise inherit any ambient animation transaction that happens
    /// to be active (a keyboard-dismissal inset animation, a row transition).
    /// Disabling animations on this specific transaction makes the pin
    /// position deterministic regardless of what else is animating.
    private func requestPinBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard !pinInFlight else { return }
        pinInFlight = true
        Task { @MainActor in
            await Task.yield()
            await Task.yield()
            pinInFlight = false
            if animated {
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            } else {
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            }
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
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    let isToolMsg = message.type == .toolCall || message.type == .toolResult
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
                            } : nil
                        )
                        .id(message.id)
                    }
                }

                // Loading indicator. No `.transition(...)` here: an ambient
                // animation transaction (keyboard dismissal, for instance) can
                // attach to a transition and produce a visible layout bleed
                // when `isLoading` flips during submit.
                if isLoading {
                    HStack {
                        ProgressView().progressViewStyle(CircularProgressViewStyle())
                        Text("Thinking...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .id("loading")
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

/// Empty state view
struct EmptyStateView: View {
    let config: ChatWidgetConfig

    var body: some View {
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
