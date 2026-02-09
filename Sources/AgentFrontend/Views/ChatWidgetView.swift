import SwiftUI

/// Main chat widget view — provides the chat flow (messages, error banner, input).
/// Navigation, headers, and sidebars are app-level concerns.
/// See TEMPLATE_APP_SETUP.md for a full ChatGPT-style app scaffold.
public struct ChatWidgetView: View {
    @ObservedObject var viewModel: ChatViewModel
    let config: ChatWidgetConfig

    public init(viewModel: ChatViewModel, config: ChatWidgetConfig) {
        self.viewModel = viewModel
        self.config = config
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Messages list
            MessageListView(
                messages: viewModel.messages,
                isLoading: viewModel.isLoading,
                hasMoreMessages: viewModel.hasMoreMessages,
                loadingMoreMessages: viewModel.loadingMoreMessages,
                config: config,
                onLoadMore: {
                    Task { await viewModel.loadMoreMessages() }
                },
                onRetry: { index in
                    Task { await viewModel.retryMessage(at: index) }
                },
                onEdit: { index, content in
                    Task { await viewModel.editMessage(at: index, newContent: content) }
                }
            )

            // Error display
            if let error = viewModel.error {
                ErrorBannerView(message: error) {
                    viewModel.error = nil
                }
            }

            // Input form
            InputView(
                config: config,
                isLoading: viewModel.isLoading,
                onSend: { content, files in
                    Task { await viewModel.sendMessage(content, files: files) }
                },
                onCancel: {
                    Task { await viewModel.cancelRun() }
                }
            )
        }
    }
}

/// Error banner view
struct ErrorBannerView: View {
    let message: String
    let onDismiss: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            Text(message)
                .font(.caption)
                .foregroundColor(.red)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
    }
}

#if DEBUG
struct ChatWidgetView_Previews: PreviewProvider {
    static var previews: some View {
        let config = ChatWidgetConfig()
        let storage = InMemoryStorage()
        let apiClient = APIClient(config: config, storage: storage)
        let viewModel = ChatViewModel(config: config, apiClient: apiClient, storage: storage)
        
        ChatWidgetView(viewModel: viewModel, config: config)
    }
}
#endif

