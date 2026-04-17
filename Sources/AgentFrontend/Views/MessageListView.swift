import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Preference key to report the bottom anchor's position within the scroll view
private struct BottomAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Preference key to report the scroll view's visible height
private struct ScrollViewHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Message list view with smart scroll behavior matching agent-frontend
///
/// Key behaviours (matching the web frontend):
/// - Auto-scrolls to bottom only when the user is already near the bottom.
/// - Loading older messages preserves scroll position (anchors to first visible).
/// - New messages animate in with a slide+fade transition from the bottom;
///   the scroll is not animated so the previous content stays put visually.
/// - Streaming content keeps the assistant reply anchored to the bottom.
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
    /// Whether auto-scroll to bottom is active (true when user is near bottom)
    @State private var shouldAutoScroll: Bool = true
    /// The message ID to anchor to after loading older messages
    @State private var anchorMessageId: String?
    /// Previous message count — used to detect when older messages are prepended
    @State private var previousMessageCount: Int = 0
    /// Tracks whether we've already handled the initial scroll for this view instance
    @State private var hasPerformedInitialScroll: Bool = false
    /// Tracks the scroll view's visible height (set via preference)
    @State private var scrollViewVisibleHeight: CGFloat = 0

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
                .onPreferenceChange(BottomAnchorPreferenceKey.self) { bottomY in
                    guard scrollViewVisibleHeight > 0 else { return }
                    shouldAutoScroll = bottomY - scrollViewVisibleHeight < 100
                }
                .onPreferenceChange(ScrollViewHeightPreferenceKey.self) { height in
                    scrollViewVisibleHeight = height
                }
                // New messages appended OR old messages prepended
                .onChange(of: messages.count) { newCount in
                    let oldCount = previousMessageCount
                    previousMessageCount = newCount

                    // Prepend path: older messages loaded — anchor to first previously-visible
                    if newCount > oldCount && oldCount > 0, let anchor = anchorMessageId {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo(anchor, anchor: .top)
                            anchorMessageId = nil
                        }
                        return
                    }

                    // Initial load (conversation restored)
                    if oldCount == 0 && newCount > 0 {
                        hasPerformedInitialScroll = true
                        scrollToBottomImmediate(proxy: proxy)
                        return
                    }

                    // Append path — user sent or assistant replied.
                    // Snap to bottom instantly; the message's own transition animates the entry.
                    if shouldAutoScroll {
                        scrollToBottomImmediate(proxy: proxy)
                    }
                }
                // Initial load finished (isLoading → false)
                .onChange(of: isLoading) { loading in
                    if !loading && hasPerformedInitialScroll && !messages.isEmpty {
                        scrollToBottomImmediate(proxy: proxy)
                    } else if loading && shouldAutoScroll {
                        // Assistant is about to respond — keep the bottom pinned
                        scrollToBottomImmediate(proxy: proxy)
                    }
                }
                // Streaming: assistant is typing — keep its reply in view with a subtle animation
                .onChange(of: messages.last?.content) { _ in
                    guard shouldAutoScroll else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom-anchor", anchor: .bottom)
                    }
                }
                // Fallback: first appearance with messages already loaded (e.g. tab return)
                .onAppear {
                    if !messages.isEmpty {
                        previousMessageCount = messages.count
                        scrollToBottomImmediate(proxy: proxy)
                    }
                }
        }
    }

    /// Jump to the bottom without any animation — used when appending new messages
    /// so the previous content doesn't visually fly off-screen. The new message's
    /// insertion transition (slide + fade) provides the motion.
    private func scrollToBottomImmediate(proxy: ScrollViewProxy) {
        let target = isLoading ? "loading" : "bottom-anchor"
        proxy.scrollTo(target, anchor: .bottom)
    }

    /// Dismiss the keyboard by resigning first responder
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
                        // Slide up + fade in from the input area when a new message
                        // appears. No removal animation — messages don't disappear normally.
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                    }
                }
                // Animate inserts/removes within the message list
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: messages.count)

                // Loading indicator
                if isLoading {
                    HStack {
                        ProgressView().progressViewStyle(CircularProgressViewStyle())
                        Text("Thinking...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .id("loading")
                    .transition(.opacity)
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
