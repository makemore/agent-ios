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
    
    /// Input placeholder text
    public var placeholder: String
    
    /// Empty state heading
    public var emptyStateTitle: String

    /// Empty state description
    public var emptyStateMessage: String

    // MARK: - Appearance / Branding

    /// Visual tokens (palette, typography, composer style, brand mark).
    /// Defaults to `ChatAppearance.anthropic` so the bundled widget
    /// renders the warm-dark look out of the box. Set to `.classic` to
    /// restore the pre-0.8 appearance.
    public var appearance: ChatAppearance

    /// Empty-state greeting (e.g. "Good afternoon, Chris"). Disabled
    /// by default so direct consumers of `MessageListView` see no
    /// change; the bundled `ChatWidgetView` flips it on through
    /// `make(...)` and the convenience initialiser.
    public var greeting: ChatGreetingConfig

    /// Slide-in conversation sidebar. Disabled by default for the
    /// same reason as `greeting`.
    public var sidebar: ChatSidebarConfig

    /// Render the library's built-in top bar (hamburger + new-chat
    /// pencil) above the message list. Set to `false` when the host
    /// app provides its own navigation chrome; in that case the host
    /// is responsible for surfacing equivalents (open sidebar, start
    /// new chat) via its own UI. Default `true`.
    ///
    /// Note: when this is `false` there is no built-in affordance to
    /// open the slide-in sidebar, so hosts that hide the top bar
    /// typically also set `sidebar.enabled = false` and render their
    /// own drawer using `ChatAppearance` tokens for cohesion.
    public var showInternalTopBar: Bool

    /// Render the pencil "new chat" button on the right of the
    /// internal top bar. Only meaningful when `showInternalTopBar`
    /// is `true`. Set to `false` so the host owns the "new chat"
    /// placement entirely — its own button should call
    /// `viewModel.clearMessages()`. Default `true`.
    public var showNewChatButton: Bool

    /// Render the S'Ai presence orb as a small avatar at the leading
    /// edge of each assistant message. The latest assistant message
    /// glows softly while TTS playback is in flight. Set to `false`
    /// when the host wants to place the orb in its own chrome (top
    /// bar, splash, etc.) using the public `PresenceOrbView` directly,
    /// or when no agent-identity affordance is wanted in the
    /// scrollback at all. Default `true`.
    public var showPresenceOrb: Bool

    // MARK: - Feature Flags

    /// Show debug mode toggle button in the UI
    public var showDebugButton: Bool

    /// Enable debug mode (show debug info like tool call args, raw events)
    public var enableDebugMode: Bool

    /// Show tool call/result and sub-agent orchestration messages in the chat thread.
    /// Covers `.toolCall`, `.toolResult`, `.subAgentStart`, `.subAgentEnd`, and `.agentContext`.
    /// When false, these events are still processed internally but not rendered as visible messages.
    public var showToolMessages: Bool

    /// Render assistant messages as markdown (bold, italic, lists, headers, code blocks, links).
    /// Only applies to assistant messages — user messages are always plain text.
    public var enableMarkdown: Bool

    /// Show the speak-aloud control at the left of the composer — the
    /// button that decides whether replies are read out, and stops them
    /// mid-reply when they are.
    ///
    /// This was dark for a while: the global mute stopped making sense
    /// once playback only ever started from a message's speaker button,
    /// because there was nothing to mute. Hands-free conversation brought
    /// automatic speech back, so the control has a job again — and it is
    /// the only unambiguous way to stop a reply being read aloud.
    ///
    /// Inert unless ``enableTTS`` is also on, so hosts that never opted
    /// into voice see no new control.
    public var showTTSButton: Bool

    /// Enable text-to-speech
    public var enableTTS: Bool

    /// Enable voice input
    public var enableVoice: Bool

    /// Offer hands-free continuous conversation — the toggle beside the
    /// mic that makes the composer send on a pause, speak the reply aloud,
    /// and hand the mic straight back for the next turn.
    ///
    /// Off by default, and inert unless ``enableTTS`` and ``enableVoice``
    /// are both on: without a voice to reply in there is no agent turn for
    /// the loop to wait through. Hosts that opt in should expect the mic
    /// to stay live through playback (that is what lets the user interrupt
    /// by talking over the agent), which means a `.voiceChat` audio
    /// session and its echo cancellation for the duration.
    public var enableContinuousVoice: Bool

    /// Policy for choosing remote vs local/system TTS.
    /// In `privateOnly` mode, `.automatic` resolves to `.localOnly` so
    /// assistant text is not sent to remote voice providers by default.
    public var ttsProviderPolicy: TTSProviderPolicy

    /// Policy for speech input privacy. In `privateOnly` mode, `.automatic`
    /// resolves to `.localOnly`; if on-device recognition is unavailable,
    /// the mic affordance fails closed.
    public var speechInputPolicy: SpeechInputPolicy

    /// Which engine transcribes dictation. `.system` is Apple's
    /// recognizer; `.whisper` runs OpenAI Whisper on-device via
    /// WhisperKit (better accuracy, ~150 MB model download on first use).
    public var dictationBackend: DictationBackend

    /// Enable file attachments
    public var enableFiles: Bool

    /// Gates the composer model selector. When `true` the Anthropic
    /// composer renders the model pill, which is the only entry point to
    /// `ModelOptionsSheet` (model picker + extended-thinking / verbose
    /// multi-agent toggles). When `false` (the default) the pill — and
    /// therefore the whole model selector — is hidden; hosts that want it
    /// must opt in explicitly.
    public var showModelSelector: Bool

    /// Show tasks tab
    public var showTasksTab: Bool

    /// Show system picker (settings cog)
    public var showSystemPicker: Bool

    /// Ephemeral mode: conversation history stays on the client.
    /// The server only holds run data for a short pickup window.
    public var ephemeral: Bool

    /// Private-only egress: when true, every run is flagged `private_only`
    /// so the server routes it ONLY to the configured private model endpoint
    /// (fail-closed). Set this for data-sovereignty-restricted users.
    public var privateOnly: Bool

    /// Allow cleartext HTTP to the backend. Default `false`: the client
    /// refuses to send over a non-HTTPS connection (except to local dev
    /// hosts). Only enable for local development against an http:// backend.
    public var allowInsecureHTTP: Bool

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

    /// Key for storing selected system slug
    public var systemKey: String

    /// Key for storing selected system version
    public var systemVersionKey: String

    /// Key for storing selected system version ID (UUID)
    public var systemVersionIdKey: String
    
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

    /// Voice identifier passed to the configured `TTSProvider`. For the
    /// ElevenLabs proxy this is the ElevenLabs voice id (e.g. a 20-char
    /// alphanumeric string from https://elevenlabs.io/app/voice-library).
    /// For ``AVSpeechTTSProvider`` it's a `AVSpeechSynthesisVoice`
    /// identifier. When nil, the provider's own default voice is used.
    public var voiceId: String?

    /// Model id for the TTS provider (e.g. ElevenLabs model such as
    /// `eleven_turbo_v2_5`). nil falls back to the provider/proxy default.
    public var voiceModelId: String?
    
    // MARK: - Callbacks
    
    /// Event callback for SSE events
    public var onEvent: ((String, [String: Any]) -> Void)?

    /// Auth error callback
    public var onAuthError: ((Error) -> Void)?

    /// Video full-screen toggle callback. Invoked with `true` when a `VideoBlockView`
    /// enters full-screen playback and `false` when it exits. Host apps can use this
    /// to manage orientation locks or other chrome. Orientation handling is intentionally
    /// left to the host.
    public var onVideoFullScreenChange: ((Bool) -> Void)?

    /// Video playback-start callback. Invoked when a native video block
    /// begins playback, before the player audio starts. Host apps can use
    /// this to stop/pause TTS so agent speech does not overlap media audio.
    public var onVideoPlaybackStart: (() -> Void)?

    /// Fires exactly once per conversation lifetime, the moment the
    /// runtime mints a fresh `conversationId` (i.e. the first
    /// `createRun` response carries one and `messages` was empty).
    /// Does **not** fire when an existing conversation is restored
    /// from local storage or loaded via `loadConversation(_:)`. Useful
    /// for analytics, first-launch coach marks, or kicking off
    /// host-side flows that should bind to a stable conversation id.
    public var onConversationStart: ((String) -> Void)?

    /// Fires exactly once per conversation lifetime, when the first
    /// assistant message becomes visible in `messages` — whether it
    /// arrives via streaming deltas, a non-streaming `assistant.message`
    /// snap, or a host call to `appendAssistantMessage(_:)`. Suppressed
    /// when an existing conversation already containing assistant
    /// messages is restored. Useful for dismissing splash screens or
    /// chaining onboarding steps once S'Ai has actually spoken.
    public var onFirstAssistantMessage: ((String) -> Void)?

    /// Called inside ``ChatWidgetView.task`` the moment the
    /// internal ``VoiceController`` is attached to the supplied
    /// ``ChatViewModel``. Useful when the host wants to play a
    /// scripted opening turn (TTS + content blocks) and needs to
    /// know voice is live before pushing deltas — polling the VM
    /// from the host races the widget mount and is unreliable on
    /// flows where the chat surface isn't visible at trigger time.
    ///
    /// Fires exactly once per widget mount. A `resetToFreshConversation`
    /// or any other action that swaps the VM will cause the widget
    /// to remount and the callback to fire again with the new VM.
    public var onVoiceControllerReady: ((ChatViewModel) -> Void)?

    /// Fired exactly once per run, the moment the SSE stream is torn
    /// down. The first argument is the runId of the stream that just
    /// closed; the second classifies the teardown so the host can
    /// distinguish a user-driven cancel (`.explicit`) from a network
    /// failure (`.network`) or a view/VM/OS lifecycle event
    /// (`.lifecycle`). The library does not perform any network call
    /// in response — this is purely a signal for the host to decide
    /// what to do (e.g. notify a backend that the user left).
    /// Default `nil` preserves the existing behaviour where the
    /// library does nothing on stream teardown.
    public var onDisconnect: ((String, DisconnectReason) -> Void)?

    // MARK: - Initialization
    
    public init(
        backendUrl: String = "http://localhost:8000",
        agentKey: String = "default-agent"
    ) {
        self.backendUrl = backendUrl
        self.agentKey = agentKey
        self.title = "Chat Assistant"
        self.subtitle = "How can we help you today?"
        self.primaryColor = Color(hex: "#D97757")
        self.placeholder = "How can I help you today?"
        self.emptyStateTitle = "Start a Conversation"
        self.emptyStateMessage = "Send a message to get started."
        self.appearance = .anthropic
        // Library default is the full warm-dark baseline: greeting
        // empty state + slide-in sidebar both on. Host apps can opt
        // out per-feature without touching the appearance.
        self.greeting = ChatGreetingConfig(enabled: true)
        self.sidebar = ChatSidebarConfig(enabled: true)
        self.showInternalTopBar = true
        self.showNewChatButton = true
        self.showPresenceOrb = true
        self.showDebugButton = false
        self.enableDebugMode = false
        self.showToolMessages = false
        self.enableMarkdown = true
        self.showTTSButton = true
        self.enableTTS = false
        self.enableVoice = true
        self.enableContinuousVoice = false
        self.ttsProviderPolicy = .automatic
        self.speechInputPolicy = .automatic
        self.dictationBackend = .system
        self.enableFiles = true
        self.showModelSelector = false
        self.showTasksTab = true
        self.showSystemPicker = true
        self.ephemeral = false
        self.privateOnly = false
        self.allowInsecureHTTP = false
        self.authStrategy = nil
        self.authToken = nil
        self.authHeader = nil
        self.authTokenPrefix = nil
        self.anonymousTokenHeader = "X-Anonymous-Token"
        self.conversationIdKey = "chat_widget_conversation_id"
        self.sessionTokenKey = "chat_widget_session_token"
        self.anonymousTokenKey = "chat_widget_anonymous_token"
        self.modelKey = "chat_widget_selected_model"
        self.systemKey = "chat_widget_selected_system"
        self.systemVersionKey = "chat_widget_selected_system_version"
        self.systemVersionIdKey = "chat_widget_selected_system_version_id"
        self.apiPaths = APIPaths()
        self.apiCaseStyle = .auto
        self.metadata = [:]
        self.defaultJourneyType = "general"
        self.ttsProxyUrl = nil
        self.elevenLabsApiKey = nil
        self.voiceId = nil
        self.voiceModelId = nil
        self.onEvent = nil
        self.onAuthError = nil
        self.onVideoFullScreenChange = nil
        self.onVideoPlaybackStart = nil
        self.onConversationStart = nil
        self.onFirstAssistantMessage = nil
        self.onVoiceControllerReady = nil
        self.onDisconnect = nil
    }
}

public extension ChatWidgetConfig {
    /// Effective TTS policy after protected/private defaults are applied.
    var effectiveTTSProviderPolicy: TTSProviderPolicy {
        if privateOnly && ttsProviderPolicy == .automatic { return .localOnly }
        return ttsProviderPolicy
    }

    /// Effective speech-input policy after protected/private defaults are applied.
    var effectiveSpeechInputPolicy: SpeechInputPolicy {
        if privateOnly && speechInputPolicy == .automatic { return .localOnly }
        return speechInputPolicy
    }
}

