import SwiftUI

/// Message list view with scroll and load more
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
    
    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    // Load more button
                    if hasMoreMessages {
                        Button(action: onLoadMore) {
                            if loadingMoreMessages {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                            } else {
                                Text("Load earlier messages")
                                    .font(.caption)
                                    .foregroundColor(config.primaryColor)
                            }
                        }
                        .padding(.vertical, 8)
                        .disabled(loadingMoreMessages)
                    }
                    
                    // Empty state
                    if messages.isEmpty && !isLoading {
                        EmptyStateView(config: config)
                    }
                    
                    // Messages
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if editingIndex == index {
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
                }
                .padding()
            }
            .onChange(of: messages.count) { _ in
                // Scroll to bottom when new messages arrive
                if let lastMessage = messages.last {
                    withAnimation {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
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

