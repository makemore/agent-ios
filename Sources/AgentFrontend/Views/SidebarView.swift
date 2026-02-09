import SwiftUI

/// Conversation sidebar view
public struct SidebarView: View {
    let config: ChatWidgetConfig
    @Binding var isPresented: Bool
    let onSelectConversation: (String) -> Void
    
    @State private var conversations: [Conversation] = []
    @State private var isLoading: Bool = false
    @State private var error: String?
    
    public var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // Sidebar content
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack {
                        Text("Conversations")
                            .font(.headline)
                        Spacer()
                        Button(action: { isPresented = false }) {
                            Image(systemName: "xmark")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .background(PlatformColors.systemGray6)
                    
                    Divider()
                    
                    // New conversation button
                    Button(action: {
                        onSelectConversation("")
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("New Conversation")
                        }
                        .foregroundColor(config.primaryColor)
                        .padding()
                    }
                    
                    Divider()
                    
                    // Conversations list
                    if isLoading {
                        Spacer()
                        ProgressView()
                            .frame(maxWidth: .infinity)
                        Spacer()
                    } else if let error = error {
                        VStack {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                            Button("Retry") {
                                Task { await loadConversations() }
                            }
                            .font(.caption)
                        }
                        .padding()
                    } else if conversations.isEmpty {
                        VStack {
                            Text("No conversations yet")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(conversations) { conversation in
                                    ConversationRow(
                                        conversation: conversation,
                                        onSelect: {
                                            onSelectConversation(conversation.id)
                                        }
                                    )
                                    Divider()
                                }
                            }
                        }
                    }
                }
                .frame(width: min(300, geometry.size.width * 0.8))
                .background(PlatformColors.systemBackground)
                
                // Tap outside to dismiss
                Color.black.opacity(0.3)
                    .onTapGesture {
                        isPresented = false
                    }
            }
        }
        .edgesIgnoringSafeArea(.all)
        .task {
            await loadConversations()
        }
    }
    
    private func loadConversations() async {
        isLoading = true
        error = nil
        
        do {
            let storage = UserDefaultsStorage()
            let apiClient = APIClient(config: config, storage: storage)
            conversations = try await apiClient.loadConversations()
        } catch {
            self.error = error.localizedDescription
        }
        
        isLoading = false
    }
}

/// Conversation row in sidebar
struct ConversationRow: View {
    let conversation: Conversation
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.title ?? "Untitled")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                if let date = conversation.updatedAt ?? conversation.createdAt {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

