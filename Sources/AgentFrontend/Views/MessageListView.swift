import SwiftUI

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
/// Key behaviors (matching the web frontend):
/// - Auto-scrolls to bottom only when user is already near the bottom
/// - Loading older messages preserves scroll position (anchors to first visible message)
/// - Scroll-to-top triggers load-more automatically
/// - Always scrolls to bottom on initial load or first messages
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
    /// Incremented to request a non-animated scroll-to-bottom on next body evaluation
    @State private var scrollToBottomRequest: Int = 0
    /// Tracks whether we've already handled the initial scroll for this view instance
    @State private var hasPerformedInitialScroll: Bool = false

    public var body: some View {
        let _ = print("[📜 MessageListView] body evaluated — messages.count=\(messages.count), isLoading=\(isLoading), previousMessageCount=\(previousMessageCount), scrollRequest=\(scrollToBottomRequest)")
        ScrollViewReader { proxy in
            scrollContent(proxy: proxy)
                .coordinateSpace(name: "messageScroll")
                // Track the scroll view's visible height
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(
                                key: ScrollViewHeightPreferenceKey.self,
                                value: geo.size.height
                            )
                    }
                )
                .onPreferenceChange(BottomAnchorPreferenceKey.self) { bottomY in
                    let scrollViewHeight = scrollViewVisibleHeight
                    if scrollViewHeight > 0 {
                        let newValue = bottomY - scrollViewHeight < 100
                        if newValue != shouldAutoScroll {
                            print("[📜 MessageListView] shouldAutoScroll changed: \(shouldAutoScroll) → \(newValue) (bottomY=\(bottomY), visibleH=\(scrollViewHeight))")
                        }
                        shouldAutoScroll = newValue
                    }
                }
                .onPreferenceChange(ScrollViewHeightPreferenceKey.self) { height in
                    if height != scrollViewVisibleHeight {
                        print("[📜 MessageListView] scrollViewVisibleHeight changed: \(scrollViewVisibleHeight) → \(height)")
                    }
                    scrollViewVisibleHeight = height
                }
                // Reactive scroll-to-bottom: when scrollToBottomRequest changes,
                // read the CURRENT isLoading/messages state (no stale captures)
                .onChange(of: scrollToBottomRequest) { _ in
                    let target = isLoading ? "loading" : "bottom-anchor"
                    print("[📜 MessageListView] onChange(scrollToBottomRequest) → scrolling to '\(target)', isLoading=\(isLoading), messages.count=\(messages.count)")
                    proxy.scrollTo(target, anchor: .bottom)
                }
                // When messages count changes
                .onChange(of: messages.count) { newCount in
                    let oldCount = previousMessageCount
                    previousMessageCount = newCount
                    print("[📜 MessageListView] onChange(messages.count): oldCount=\(oldCount) → newCount=\(newCount), shouldAutoScroll=\(shouldAutoScroll), anchorMessageId=\(anchorMessageId ?? "nil")")

                    // Older messages were prepended — anchor to the first previously-visible message
                    if newCount > oldCount && oldCount > 0, let anchor = anchorMessageId {
                        print("[📜 MessageListView] → PREPEND path: anchoring to \(anchor)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo(anchor, anchor: .top)
                            anchorMessageId = nil
                        }
                        return
                    }

                    // Initial load (conversation restored or first messages)
                    if oldCount == 0 && newCount > 0 {
                        print("[📜 MessageListView] → INITIAL LOAD path: requesting scroll to bottom")
                        hasPerformedInitialScroll = true
                        // Request scroll — will fire onChange(scrollToBottomRequest)
                        // which reads current state, avoiding stale captures
                        scrollToBottomRequest += 1
                        return
                    }

                    // New messages appended (user sent or assistant replied)
                    if shouldAutoScroll {
                        print("[📜 MessageListView] → APPEND path: auto-scrolling to bottom")
                        scrollToBottom(proxy: proxy)
                    } else {
                        print("[📜 MessageListView] → APPEND path: NOT scrolling (shouldAutoScroll=false)")
                    }
                }
                // When isLoading transitions to false after initial load,
                // the "bottom-anchor" is now in the view tree — scroll to it
                .onChange(of: isLoading) { loading in
                    print("[📜 MessageListView] onChange(isLoading): \(loading), shouldAutoScroll=\(shouldAutoScroll), hasPerformedInitialScroll=\(hasPerformedInitialScroll)")
                    if !loading && hasPerformedInitialScroll && !messages.isEmpty {
                        print("[📜 MessageListView] → isLoading became false after initial load, scrolling to bottom")
                        scrollToBottomRequest += 1
                    }
                    if loading && shouldAutoScroll {
                        scrollToBottom(proxy: proxy)
                    }
                }
                // Auto-scroll when streaming content updates (assistant typing)
                .onChange(of: messages.last?.content) { _ in
                    if shouldAutoScroll {
                        scrollToBottom(proxy: proxy)
                    }
                }
                // Fallback: when the view first appears with messages already loaded
                // (e.g. tab switch back to chat), scroll to bottom immediately
                .onAppear {
                    print("[📜 MessageListView] onAppear — messages.count=\(messages.count), previousMessageCount=\(previousMessageCount)")
                    if !messages.isEmpty {
                        previousMessageCount = messages.count
                        print("[📜 MessageListView] → onAppear: messages already loaded, requesting scroll to bottom")
                        scrollToBottomRequest += 1
                    }
                }
        }
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
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up")
                                    .font(.caption2)
                                Text("Load earlier messages")
                                    .font(.caption)
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
                    // Hide tool messages when showToolMessages is disabled
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
                            onCancel: {
                                editingIndex = nil
                            }
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

                // Loading indicator
                if isLoading {
                    HStack {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                        Text("Thinking...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .id("loading")
                }

                // Bottom anchor — reports its position for scroll tracking
                GeometryReader { geo in
                    Color.clear
                        .preference(
                            key: BottomAnchorPreferenceKey.self,
                            value: geo.frame(in: .named("messageScroll")).minY
                        )
                }
                .frame(height: 1)
                .id("bottom-anchor")
            }
            .padding()
        }
    }

    /// Tracks the scroll view's visible height (set via preference)
    @State private var scrollViewVisibleHeight: CGFloat = 0

    /// Scroll to the bottom-most content (used for append/streaming — reads current state inline)
    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        let target = isLoading ? "loading" : "bottom-anchor"
        print("[📜 MessageListView] scrollToBottom → target='\(target)', animated=\(animated), isLoading=\(isLoading)")
        let action = {
            proxy.scrollTo(target, anchor: .bottom)
        }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { action() }
        } else {
            action()
        }
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

