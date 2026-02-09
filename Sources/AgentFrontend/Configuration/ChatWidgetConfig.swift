import Foundation
import SwiftUI

/// Configuration for the chat widget
public struct ChatWidgetConfig {
    // MARK: - Backend Configuration
    
    /// Backend API URL
    public var backendUrl: String
    
    /// Agent identifier
    public var agentKey: String
    
    // MARK: - UI Configuration
    
    /// Widget header title
    public var title: String
    
    /// Widget subtitle
    public var subtitle: String
    
    /// Primary theme color
    public var primaryColor: Color
    
    /// Header text color (auto-detected if nil)
    public var headerTextColor: Color?
    
    /// Input placeholder text
    public var placeholder: String
    
    /// Empty state heading
    public var emptyStateTitle: String
    
    /// Empty state description
    public var emptyStateMessage: String
    
    // MARK: - Feature Flags
    
    /// Show conversation sidebar
    public var showConversationSidebar: Bool
    
    /// Show clear conversation button
    public var showClearButton: Bool
    
    /// Show debug mode toggle
    public var showDebugButton: Bool
    
    /// Enable debug mode
    public var enableDebugMode: Bool
    
    /// Show TTS toggle button
    public var showTTSButton: Bool
    
    /// Enable text-to-speech
    public var enableTTS: Bool
    
    /// Enable voice input
    public var enableVoice: Bool
    
    /// Enable file attachments
    public var enableFiles: Bool
    
    /// Show model selector
    public var showModelSelector: Bool
    
    /// Show tasks tab
    public var showTasksTab: Bool
    
    // MARK: - Authentication
    
    /// Authentication strategy
    public var authStrategy: AuthStrategy?
    
    /// Authentication token
    public var authToken: String?
    
    /// Custom auth header name
    public var authHeader: String?
    
    /// Custom auth token prefix
    public var authTokenPrefix: String?
    
    /// Anonymous token header name
    public var anonymousTokenHeader: String
    
    // MARK: - Storage Keys
    
    /// Key for storing conversation ID
    public var conversationIdKey: String
    
    /// Key for storing session token
    public var sessionTokenKey: String
    
    /// Key for storing anonymous token
    public var anonymousTokenKey: String
    
    /// Key for storing selected model
    public var modelKey: String
    
    // MARK: - API Paths
    
    /// API endpoint paths
    public var apiPaths: APIPaths
    
    /// API case style for request/response transformation
    public var apiCaseStyle: APICaseStyle
    
    // MARK: - Metadata
    
    /// Custom metadata to send with requests
    public var metadata: [String: Any]
    
    /// Default journey type
    public var defaultJourneyType: String
    
    // MARK: - TTS Configuration
    
    /// TTS proxy URL for secure backend calls
    public var ttsProxyUrl: String?
    
    /// ElevenLabs API key (direct mode only)
    public var elevenLabsApiKey: String?
    
    // MARK: - Callbacks
    
    /// Event callback for SSE events
    public var onEvent: ((String, [String: Any]) -> Void)?
    
    /// Auth error callback
    public var onAuthError: ((Error) -> Void)?
    
    // MARK: - Initialization
    
    public init(
        backendUrl: String = "http://localhost:8000",
        agentKey: String = "default-agent"
    ) {
        self.backendUrl = backendUrl
        self.agentKey = agentKey
        self.title = "Chat Assistant"
        self.subtitle = "How can we help you today?"
        self.primaryColor = Color(hex: "#0066cc")
        self.headerTextColor = nil
        self.placeholder = "Type your message..."
        self.emptyStateTitle = "Start a Conversation"
        self.emptyStateMessage = "Send a message to get started."
        self.showConversationSidebar = true
        self.showClearButton = true
        self.showDebugButton = true
        self.enableDebugMode = true
        self.showTTSButton = true
        self.enableTTS = false
        self.enableVoice = true
        self.enableFiles = true
        self.showModelSelector = false
        self.showTasksTab = true
        self.authStrategy = nil
        self.authToken = nil
        self.authHeader = nil
        self.authTokenPrefix = nil
        self.anonymousTokenHeader = "X-Anonymous-Token"
        self.conversationIdKey = "chat_widget_conversation_id"
        self.sessionTokenKey = "chat_widget_session_token"
        self.anonymousTokenKey = "chat_widget_anonymous_token"
        self.modelKey = "chat_widget_selected_model"
        self.apiPaths = APIPaths()
        self.apiCaseStyle = .auto
        self.metadata = [:]
        self.defaultJourneyType = "general"
        self.ttsProxyUrl = nil
        self.elevenLabsApiKey = nil
        self.onEvent = nil
        self.onAuthError = nil
    }
}

