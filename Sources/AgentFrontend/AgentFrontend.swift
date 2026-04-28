import SwiftUI
import AgentClient

/// Main entry point for the AgentFrontend chat widget
public struct AgentFrontend {
    
    /// Create a chat widget view with the given configuration
    /// - Parameter config: Configuration for the chat widget
    /// - Returns: A SwiftUI view containing the chat widget
    @MainActor
    public static func createChatWidget(config: ChatWidgetConfig) -> some View {
        let storage = UserDefaultsStorage(prefix: config.agentKey)
        let apiClient = APIClient(config: config, storage: storage)
        let viewModel = ChatViewModel(config: config, apiClient: apiClient, storage: storage)

        return ChatWidgetView(viewModel: viewModel, config: config)
    }

    /// Create a chat widget with custom storage
    /// - Parameters:
    ///   - config: Configuration for the chat widget
    ///   - storage: Custom storage service implementation
    /// - Returns: A SwiftUI view containing the chat widget
    @MainActor
    public static func createChatWidget(config: ChatWidgetConfig, storage: StorageService) -> some View {
        let apiClient = APIClient(config: config, storage: storage)
        let viewModel = ChatViewModel(config: config, apiClient: apiClient, storage: storage)

        return ChatWidgetView(viewModel: viewModel, config: config)
    }
    
    /// Create a chat view model for custom UI implementations
    /// - Parameter config: Configuration for the chat widget
    /// - Returns: A ChatViewModel instance
    @MainActor
    public static func createViewModel(config: ChatWidgetConfig) -> ChatViewModel {
        let storage = UserDefaultsStorage(prefix: config.agentKey)
        let apiClient = APIClient(config: config, storage: storage)
        return ChatViewModel(config: config, apiClient: apiClient, storage: storage)
    }
    
    /// Create a chat view model with custom dependencies
    /// - Parameters:
    ///   - config: Configuration for the chat widget
    ///   - storage: Custom storage service implementation
    /// - Returns: A ChatViewModel instance
    @MainActor
    public static func createViewModel(config: ChatWidgetConfig, storage: StorageService) -> ChatViewModel {
        let apiClient = APIClient(config: config, storage: storage)
        return ChatViewModel(config: config, apiClient: apiClient, storage: storage)
    }
}

// MARK: - Convenience Extensions

public extension ChatWidgetConfig {
    /// Create a configuration with common settings
    static func make(
        backendUrl: String,
        agentKey: String,
        title: String = "Chat Assistant",
        primaryColor: Color = Color(hex: "#4a6b8e")
    ) -> ChatWidgetConfig {
        var config = ChatWidgetConfig(backendUrl: backendUrl, agentKey: agentKey)
        config.title = title
        config.primaryColor = primaryColor
        return config
    }
    
    /// Configure authentication
    mutating func withAuth(strategy: AuthStrategy, token: String? = nil) -> ChatWidgetConfig {
        self.authStrategy = strategy
        self.authToken = token
        return self
    }
    
    /// Configure UI options
    mutating func withUI(
        showTasks: Bool = true,
        showModelSelector: Bool = false
    ) -> ChatWidgetConfig {
        self.showTasksTab = showTasks
        self.showModelSelector = showModelSelector
        return self
    }
}

// MARK: - SwiftUI View Extension

public extension View {
    /// Present a chat widget as a sheet
    func chatSheet(
        isPresented: Binding<Bool>,
        config: ChatWidgetConfig
    ) -> some View {
        self.sheet(isPresented: isPresented) {
            AgentFrontend.createChatWidget(config: config)
        }
    }
    
    /// Present a chat widget as a full screen cover (iOS only)
    #if os(iOS)
    func chatFullScreen(
        isPresented: Binding<Bool>,
        config: ChatWidgetConfig
    ) -> some View {
        self.fullScreenCover(isPresented: isPresented) {
            AgentFrontend.createChatWidget(config: config)
        }
    }
    #endif
}

