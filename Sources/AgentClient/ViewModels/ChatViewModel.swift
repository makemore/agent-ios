import Foundation
import SwiftUI
import Combine

/// Main view model for chat functionality (equivalent to useChat hook)
@MainActor
public class ChatViewModel: ObservableObject {
    // MARK: - Published State

    @Published public var messages: [Message] = []
    @Published public var isLoading: Bool = false
    @Published public var error: String?
    @Published public var conversationId: String?
    @Published public var hasMoreMessages: Bool = false
    @Published public var loadingMoreMessages: Bool = false
    @Published public var runState: RunState = .idle
    /// In-flight sub-agent activity, surfaced by the UI as a quiet pill
    /// in place of per-event bubbles when the effective
    /// `subAgentActivityStyle` is `.pill`. Stays empty in `.bubbles`
    /// mode (the legacy behaviour) so the view layer can treat it as a
    /// single optional source of truth either way.
    @Published public var subAgentActivity: SubAgentActivityState = SubAgentActivityState()

    // MARK: - Model Options (per-conversation / per-app)

    /// Per-conversation toggle for the LLM's extended-reasoning / "thinking"
    /// mode. Forwarded to the runtime as the `thinking:` parameter on the
    /// next `sendMessage` call. Distinct from `subAgentActivityStyle` —
    /// that controls how multi-agent handoffs *display*; this controls
    /// whether the model is asked to think harder. Reset to `false` in
    /// `clearMessages()` because reasoning is a per-conversation choice,
    /// not an app-wide preference.
    @Published public var extendedThinking: Bool = false

    /// Per-app preference. When `true`, the bundled UI surfaces every
    /// sub-agent's narration as its own bubble (the legacy `.bubbles`
    /// behaviour) regardless of the host's `ChatAppearance` default —
    /// useful for debugging specialist chains. When `false` (default),
    /// the effective style falls back to `config.appearance.subAgentActivityStyle`.
    /// Persisted to `StorageService` under `verboseMultiAgentStorageKey`.
    @Published public var verboseMultiAgent: Bool = false {
        didSet {
            guard oldValue != verboseMultiAgent else { return }
            storage.set(Self.verboseMultiAgentStorageKey, value: verboseMultiAgent ? "1" : "0")
        }
    }

    /// Effective sub-agent activity style after applying the
    /// `verboseMultiAgent` override on top of the host's appearance
    /// default. Read by the reducer (`usesPillActivity`) and available
    /// to view code that needs to render in lockstep.
    public var subAgentActivityStyle: ChatAppearance.SubAgentActivityStyle {
        verboseMultiAgent ? .bubbles : config.appearance.subAgentActivityStyle
    }

    private static let verboseMultiAgentStorageKey = "chat_widget_verbose_multi_agent"

    // MARK: - Model Picker State

    /// Models advertised by the runtime's `/api/agent-runtime/models/`
    /// endpoint. Empty until `loadModels()` succeeds; the picker UI
    /// renders a loading / empty state until then. Sorted as the
    /// server returned them so the runtime can control ordering
    /// (typically: most capable / newest first).
    @Published public var availableModels: [AgentModel] = []

    /// Identifier of the model the user has chosen for the next turn.
    /// `nil` means "let the runtime use its configured default". Persisted
    /// to `StorageService` so the choice survives app restarts. Forwarded
    /// to `createRun(model:)` on every `sendMessage` / edit / retry.
    @Published public var selectedModelId: String? {
        didSet {
            guard oldValue != selectedModelId else { return }
            storage.set(Self.selectedModelStorageKey, value: selectedModelId)
            // Extended thinking only makes sense for models that advertise
            // `supports_thinking`. Quietly switch it off if the user picks
            // a model that doesn't — the toggle in `ModelOptionsSheet`
            // disables itself in lockstep so the state stays coherent.
            if extendedThinking, let model = selectedModel, !model.supportsThinking {
                extendedThinking = false
            }
        }
    }

    /// True while `loadModels()` is in flight. Drives the spinner in the
    /// picker; the toggles below stay interactive throughout.
    @Published public var isLoadingModels: Bool = false

    /// Runtime's advertised default model id (`DEFAULT_MODEL` setting),
    /// captured from `ModelsResponse.default`. Used as the fallback the
    /// picker highlights when `selectedModelId` is `nil`.
    @Published public private(set) var runtimeDefaultModelId: String?

    /// Convenience: the `AgentModel` matching `selectedModelId`, or the
    /// runtime default if the user hasn't chosen explicitly, or `nil` if
    /// the list hasn't loaded yet.
    public var selectedModel: AgentModel? {
        if let id = selectedModelId, let m = availableModels.first(where: { $0.id == id }) {
            return m
        }
        if let id = runtimeDefaultModelId, let m = availableModels.first(where: { $0.id == id }) {
            return m
        }
        return availableModels.first
    }

    /// Short display name suitable for the composer's model pill. Prefers
    /// the picked model's friendly name; falls back to the host's
    /// `ChatAppearance.modelPillLabel` so existing branding (e.g. "S'Ai")
    /// keeps rendering until the picker has resolved a real selection.
    public var selectedModelDisplayName: String? {
        selectedModel?.name ?? config.appearance.modelPillLabel
    }

    private static let selectedModelStorageKey = "chat_widget_selected_model"

    // MARK: - Behaviour preferences (forwarded via run `params`)

    /// Response-style preferences surfaced in the `+` sheet. Forwarded
    /// to the backend under `params["response_style"]`; the runtime
    /// translates the chosen tag into a system-prompt directive (see
    /// `DynamicAgentRuntime` in `django_agent_runtime`). `nil` means
    /// "let the agent's own prompt decide" \u2014 the default.
    public enum ResponseStyle: String, CaseIterable, Sendable {
        case normal
        case concise
        case explanatory
        case formal

        public var displayName: String {
            switch self {
            case .normal: return "Normal"
            case .concise: return "Concise"
            case .explanatory: return "Explanatory"
            case .formal: return "Formal"
            }
        }
    }

    /// Tool-access mode the user picked in the `+` sheet. Maps to
    /// `params["tool_access"]`. The runtime honours this by filtering
    /// or annotating the tool list before the agentic loop.
    public enum ToolAccess: String, CaseIterable, Sendable {
        case auto
        case manual
        case none

        public var displayName: String {
            switch self {
            case .auto: return "Auto"
            case .manual: return "Manual"
            case .none: return "None"
            }
        }
    }

    @Published public var responseStyle: ResponseStyle = .normal {
        didSet {
            guard oldValue != responseStyle else { return }
            storage.set(Self.responseStyleStorageKey, value: responseStyle.rawValue)
        }
    }

    @Published public var toolAccess: ToolAccess = .auto {
        didSet {
            guard oldValue != toolAccess else { return }
            storage.set(Self.toolAccessStorageKey, value: toolAccess.rawValue)
        }
    }

    /// "Deep research" toggle. Surfaced as `params["research"]: Bool`.
    /// The runtime injects a research directive into the system prompt
    /// when true; default false to preserve current behaviour.
    @Published public var researchEnabled: Bool = false {
        didSet {
            guard oldValue != researchEnabled else { return }
            storage.set(Self.researchStorageKey, value: researchEnabled ? "1" : "0")
        }
    }

    /// "Web search" toggle. Surfaced as `params["web_search"]: Bool`.
    /// Defaults to true \u2014 matches the AddToChatSheet's prior visible
    /// state and is a no-op when no web-search tool is configured.
    @Published public var webSearchEnabled: Bool = true {
        didSet {
            guard oldValue != webSearchEnabled else { return }
            storage.set(Self.webSearchStorageKey, value: webSearchEnabled ? "1" : "0")
        }
    }

    private static let responseStyleStorageKey = "chat_widget_response_style"
    private static let toolAccessStorageKey = "chat_widget_tool_access"
    private static let researchStorageKey = "chat_widget_research_enabled"
    private static let webSearchStorageKey = "chat_widget_web_search_enabled"

    /// Snapshot of the user's current behaviour preferences as a JSON
    /// dict suitable for `APIClient.createRun(params:)`. Only includes
    /// keys whose value differs from the implicit server default so the
    /// runtime can stay backwards-compatible with older clients that
    /// don't send these flags. Merged into any caller-supplied params
    /// (caller wins on conflicts).
    public func runParamsSnapshot() -> [String: Any] {
        var p: [String: Any] = [:]
        if responseStyle != .normal {
            p["response_style"] = responseStyle.rawValue
        }
        if toolAccess != .auto {
            p["tool_access"] = toolAccess.rawValue
        }
        if researchEnabled {
            p["research"] = true
        }
        // Only forward web_search when the user explicitly turned it off
        // \u2014 keeps the payload small for the common (default-on) case.
        if !webSearchEnabled {
            p["web_search"] = false
        }
        return p
    }

    // MARK: - System State

    @Published public var systems: [AgentSystem] = []
    @Published public var selectedSystemSlug: String?
    @Published public var selectedSystemVersion: String?
    @Published public var selectedSystemVersionId: String?
    @Published public var isLoadingSystems: Bool = false

    // MARK: - Private State

    private var messagesOffset: Int = 0
    private var currentRunId: String?
    private var sseClient: SSEClient?
    private var assistantContent: String = ""
    private var hasRestoredConversation: Bool = false

    // MARK: - Streaming buffer
    // Decouples network receive rate from visual display rate. OpenAI emits
    // tokens in bursts (silence, then 5+ tokens in one TCP packet); rendering
    // those bursts directly causes visible stutter. We buffer incoming deltas
    // and drain them at a steady cadence so the displayed text flows smoothly.
    private var streamBuffer: String = ""
    private var drainTimer: Timer?
    private let drainInterval: TimeInterval = 0.03   // ~33 Hz
    /// Set true when server signals stream end — lets the drain catch up
    /// at a higher rate without flushing everything instantly.
    private var streamingDone: Bool = false
    /// ID of the in-flight streaming message. Tracked explicitly so we can
    /// find and update it even after non-streaming messages (tool calls,
    /// content blocks, sub-agent events) have been appended after it.
    private var currentStreamingMessageId: String?
    /// Set true at terminal-event time when the drain timer is still
    /// flushing buffered chars; the next `drainTick` that empties the
    /// buffer will then call `persistToLocalHistory()` so the on-disk
    /// snapshot includes the final assistant bubble. Without this flag
    /// the success-path persist would race the typewriter and capture
    /// only the user message (the streaming bubble is appended to
    /// `messages` from inside `drainTick` via `upsertStreamingMessage`).
    private var pendingPersistAfterDrain: Bool = false
    /// Set true when an `assistant.message` finalises the current turn's
    /// bubble. While true, any further `assistant.delta` events are dropped
    /// because they are late-arriving tokens for a turn that has already
    /// been delivered in full — replaying them would produce a duplicate
    /// typewriter bubble below the finalised one.
    /// Reset on any non-streaming event (tool call, tool result, content
    /// block, sub-agent start/end, custom, terminal), which marks the
    /// boundary of a new turn.
    private var turnFinalized: Bool = false

    /// Latches on the first assistant message we surface for the current
    /// conversation lifetime so `config.onFirstAssistantMessage` only
    /// fires once. Reset by `clearMessages()` (new conversation). Set
    /// to `true` by `loadConversation`/`loadLocalConversation` when the
    /// restored history already contains an assistant message, so the
    /// callback doesn't fire for replayed history.
    private var firstAssistantMessageFired: Bool = false

    // MARK: - Sub-agent echo suppression
    /// When a sub-agent finishes streaming its final answer, we snapshot
    /// that text here. The parent agent typically receives the sub-agent's
    /// response as a tool result and re-streams it verbatim as its own
    /// `assistant.delta` events — which without dedup would produce a
    /// duplicate bubble below the sub-agent's one. Keeping this lets us
    /// recognise the echo while still letting the sub-agent's live
    /// narration (intermediate tool-use text, cards, etc.) render.
    /// Cleared when the parent's stream either diverges from the snapshot
    /// or is finalised by `assistant.message`, and on turn boundaries
    /// where continuing to compare would be meaningless (new tool call,
    /// new sub-agent, terminal event, new SSE stream).
    private var pendingEchoReference: String?
    /// Accumulates the parent's delta text while we're still deciding
    /// whether its output is an echo of the sub-agent. Chars in here
    /// are not yet committed to any visible bubble.
    private var pendingEchoBuffer: String = ""
    /// Once the parent's stream has diverged from the snapshot (said
    /// something different, or added content beyond it), we stop
    /// comparing and treat subsequent deltas as a normal stream.
    private var pendingEchoDiverged: Bool = false

    // MARK: - Stream completion awaiter
    /// Resolved when the in-flight SSE stream reaches a terminal state
    /// (run.succeeded / run.failed / run.cancelled / transport error). Lets
    /// `sendMessage` actually wait for the run to finish before returning so
    /// callers using `await vm.sendMessage("a"); await vm.sendMessage("b")`
    /// don't lose the second message to the `guard !isLoading` check.
    /// Single-shot: only one stream is in flight at a time because
    /// `sendMessage` is gated by `isLoading`.
    private var streamContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Ephemeral Memories
    // Client-side memories (facts/preferences) persisted locally and
    // sent to the server with each ephemeral run. Updated via the
    // `memory.update` SSE event.
    private static let memoriesStorageKey = "chat_widget_memories"

    /// Current in-memory cache of client-side memories.
    private var clientMemories: [[String: String]] = []

    // MARK: - Local History (ephemeral mode)

    /// Observable list of locally-persisted conversations (newest first).
    /// Non-ephemeral mode always returns an empty array.
    @Published public var localConversations: [LocalConversationSummary] = []

    /// The backing local-history store (nil when not ephemeral).
    private var localHistoryStore: LocalHistoryStore?

    /// Timestamp when the current ephemeral conversation was first created.
    private var localConversationCreatedAt: Date?

    // MARK: - Dependencies

    private let config: ChatWidgetConfig
    private let apiClient: APIClient
    private let storage: StorageService

    // MARK: - Voice (TTS)
    /// Optional voice controller. When set, ``assistant.delta`` and
    /// ``assistant.message`` events are streamed into it for sentence-level
    /// TTS playback. The controller itself owns the speaker indicator
    /// state via its ``@Published isSpeaking``.
    public var voiceController: VoiceController?

    // MARK: - Initialization

    public init(config: ChatWidgetConfig, apiClient: APIClient, storage: StorageService) {
        self.config = config
        self.apiClient = apiClient
        self.storage = storage

        // Load saved conversation ID — server-side mode only.
        // In ephemeral mode the conversationIdKey slot holds a stale
        // server id that the user has no way to resume; rehydrating it
        // causes createRun to 404. Local conversations are loaded via
        // loadLocalConversation(_:) instead.
        if !config.ephemeral, let savedId = storage.get(config.conversationIdKey) {
            self.conversationId = savedId
        }

        // Load saved system selection
        if let savedSystem = storage.get(config.systemKey) {
            self.selectedSystemSlug = savedSystem
        }
        if let savedVersion = storage.get(config.systemVersionKey) {
            self.selectedSystemVersion = savedVersion
        }
        if let savedVersionId = storage.get(config.systemVersionIdKey) {
            self.selectedSystemVersionId = savedVersionId
        }

        // Load persisted client-side memories (ephemeral mode)
        if let memoriesJson = storage.get(Self.memoriesStorageKey),
           let data = memoriesJson.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            clientMemories = parsed
        }

        // Load persisted "verbose multi-agent" preference. Stored as a
        // simple "1" / "0" string for portability across StorageService
        // implementations. The `didSet` will fire and re-persist the
        // same value on first launch — idempotent, so we accept the
        // trivial extra write rather than threading a load-guard flag.
        if storage.get(Self.verboseMultiAgentStorageKey) == "1" {
            verboseMultiAgent = true
        }

        // Restore the user's previously-chosen model id (if any). The
        // matching `AgentModel` is resolved lazily once `loadModels()`
        // populates `availableModels` — until then the pill falls back
        // to the host's `modelPillLabel`.
        if let savedModelId = storage.get(Self.selectedModelStorageKey), !savedModelId.isEmpty {
            self.selectedModelId = savedModelId
        }

        // Restore behaviour preferences surfaced in the `+` sheet.
        // Unknown enum strings (older app version, manual storage tweak)
        // fall back to the default rather than crashing.
        if let raw = storage.get(Self.responseStyleStorageKey),
           let style = ResponseStyle(rawValue: raw) {
            self.responseStyle = style
        }
        if let raw = storage.get(Self.toolAccessStorageKey),
           let mode = ToolAccess(rawValue: raw) {
            self.toolAccess = mode
        }
        if storage.get(Self.researchStorageKey) == "1" {
            self.researchEnabled = true
        }
        // Default-on toggle: only flip to false if storage explicitly says so.
        if storage.get(Self.webSearchStorageKey) == "0" {
            self.webSearchEnabled = false
        }

        // Initialise local history store for ephemeral mode
        if config.ephemeral {
            let store = LocalHistoryStore(agentKey: config.agentKey)
            self.localHistoryStore = store
            self.localConversations = store.loadIndex()
        }
    }

    /// Restore the saved conversation on launch (call from .task or .onAppear)
    public func restoreConversationIfNeeded() async {
        guard !hasRestoredConversation else { return }
        hasRestoredConversation = true

        // Ephemeral mode: nothing to restore from the server.
        if config.ephemeral { return }

        if let savedId = storage.get(config.conversationIdKey) {
            await loadConversation(savedId)
        }
    }
    
    // MARK: - Public Methods
    
    /// Send a message to the agent
    public func sendMessage(
        _ content: String,
        files: [FileAttachment] = [],
        model: String? = nil,
        thinking: Bool = false,
        supersedeFromMessageIndex: Int? = nil
    ) async {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isLoading else { return }

        isLoading = true
        runState = .sending
        error = nil

        // New turn — drop any half-spoken audio from the previous assistant
        // response and clear the chunker's buffer.
        voiceController?.reset()

        // Add user message
        let userMessage = Message(
            role: .user,
            content: content.trimmingCharacters(in: .whitespacesAndNewlines),
            files: files.isEmpty ? nil : files
        )
        messages.append(userMessage)
        
        do {
            // In ephemeral mode send the full conversation history so the
            // server has complete context (it won't load from the DB).
            let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let apiMessages: [[String: Any]]
            if config.ephemeral {
                let history: [[String: Any]] = messages
                    .filter { $0.role == .user || $0.role == .assistant }
                    .dropLast()  // the user message we just appended is re-added below
                    .map { ["role": $0.role.rawValue, "content": $0.content] }
                apiMessages = history + [["role": "user", "content": trimmedContent]]
            } else {
                apiMessages = [["role": "user", "content": trimmedContent]]
            }

            print("[ChatViewModel] createRun sending conversationId=\(conversationId ?? "nil")")

            // Caller-provided `model:` wins (so deep-link / scripted flows
            // can pin a specific id); otherwise fall back to the user's
            // current picker selection. `nil` lets the runtime use its
            // configured `DEFAULT_MODEL`.
            let resolvedModel = model ?? selectedModelId
            // Build the params payload from the user's current behaviour
            // preferences (response_style, tool_access, research,
            // web_search). Only non-default values are included so the
            // payload stays minimal and old clients/runtimes remain
            // compatible.
            let resolvedParams = runParamsSnapshot()
            let run = try await apiClient.createRun(
                conversationId: conversationId,
                messages: apiMessages,
                model: resolvedModel,
                thinking: thinking,
                supersedeFromMessageIndex: supersedeFromMessageIndex,
                agentKeyOverride: effectiveAgentKey != config.agentKey ? effectiveAgentKey : nil,
                systemVersionId: selectedSystemVersionId,
                ephemeral: config.ephemeral,
                privateOnly: config.privateOnly,
                memories: config.ephemeral ? clientMemories : nil,
                params: resolvedParams.isEmpty ? nil : resolvedParams
            )

            print("[ChatViewModel] createRun response runId=\(run.id) conversationId=\(run.conversationId ?? "nil")")

            currentRunId = run.id
            runState = .streaming

            // Update conversation ID if new
            if conversationId == nil, let newConvId = run.conversationId {
                conversationId = newConvId
                storage.set(config.conversationIdKey, value: newConvId)
                // Mark creation time for the local conversation
                if config.ephemeral {
                    localConversationCreatedAt = Date()
                }
                // Lifecycle hook: a fresh conversation has just been
                // minted by the runtime. Fires exactly once per
                // conversation; restoring an existing one via
                // `loadConversation(_:)` does not trigger this.
                config.onConversationStart?(newConvId)
            }

            // Subscribe to SSE events
            await subscribeToEvents(runId: run.id)
            
        } catch {
            self.error = error.localizedDescription
            isLoading = false
            runState = .failed
        }
    }
    
    /// Cancel the current run
    public func cancelRun() async {
        guard let runId = currentRunId, isLoading else { return }

        do {
            runState = .cancelling
            try await apiClient.cancelRun(id: runId)

            sseClient?.disconnect()
            sseClient = nil
            // Drop any buffered-but-not-yet-drained characters and stop the
            // typewriter timer. Without this, the drain timer keeps revealing
            // whatever the server sent before the disconnect — the user sees
            // text continuing to type for seconds after tapping Stop. This
            // differs from the natural-end path (`handleTerminalEvent`) which
            // deliberately lets the drain finish smoothly.
            resetStreamBuffer()
            // Clear any in-flight sub-agent activity so the pill
            // disappears immediately on Stop.
            subAgentActivity = SubAgentActivityState()
            // Cut off any in-flight TTS playback when the user cancels.
            voiceController?.stop()
            isLoading = false
            runState = .cancelled
            currentRunId = nil
            // Wake the awaiter inside `subscribeToEvents` — disconnecting
            // the SSE client doesn't fire `onComplete`, so without this any
            // outstanding `await sendMessage(...)` would hang forever.
            resumeStreamContinuation()

            // Add cancelled message
            messages.append(Message(
                role: .system,
                content: "⏹ Run cancelled",
                type: .cancelled
            ))
        } catch {
            print("[ChatViewModel] Failed to cancel run: \(error)")
        }
    }
    
    /// Clear all messages and start fresh.
    /// Does NOT delete the conversation from local storage — it just
    /// starts a new in-memory conversation.
    public func clearMessages() {
        messages = []
        conversationId = nil
        localConversationCreatedAt = nil
        error = nil
        hasMoreMessages = false
        messagesOffset = 0
        // Extended-thinking is a per-conversation choice — starting a
        // new chat resets it to the safer (cheaper, faster) default.
        extendedThinking = false
        runState = .idle
        pendingPersistAfterDrain = false
        subAgentActivity = SubAgentActivityState()
        firstAssistantMessageFired = false
        storage.set(config.conversationIdKey, value: nil)
    }

    /// Append an assistant message to the conversation without a
    /// backend round-trip. Useful for host-scripted intros, onboarding
    /// turns, or replaying canned responses in a guided flow.
    ///
    /// The message is inserted as a fully-formed bubble (not a
    /// streaming one) and fires `config.onFirstAssistantMessage` the
    /// first time it lands in a conversation. When `speak == true`
    /// **and** a `voiceController` is attached, the text is pushed
    /// through the chunker + finished so the TTS pipeline plays it
    /// with the same prosody settings used for real model replies.
    ///
    /// Refuses to insert while an SSE stream is in flight (`runState
    /// == .streaming` or there's a live streaming bubble) so a
    /// scripted turn can never split a real one in two. Returns the
    /// resulting `Message`, or `nil` if the insertion was skipped.
    @discardableResult
    public func appendAssistantMessage(
        _ text: String,
        speak: Bool = false,
        blocks: [ContentBlock]? = nil,
        emotion: Emotion? = nil
    ) -> Message? {
        let trimmed = text
        guard !trimmed.isEmpty else { return nil }
        // Don't splice into an active stream — the host should wait
        // for the run to finish before injecting a scripted turn.
        if runState == .streaming || currentStreamingMessageId != nil {
            return nil
        }

        let id = "assistant-injected-\(Date().timeIntervalSince1970)"
        let metadata: MessageMetadata? = (blocks?.isEmpty == false)
            ? MessageMetadata(contentBlocks: blocks)
            : nil
        let msg = Message(
            id: id,
            role: .assistant,
            content: trimmed,
            type: .message,
            metadata: metadata
        )
        messages.append(msg)

        // Fire the first-assistant lifecycle hook just like a normal
        // streamed turn would.
        if !firstAssistantMessageFired {
            firstAssistantMessageFired = true
            config.onFirstAssistantMessage?(id)
        }

        // Voice: re-use the same chunker + finishTurn path as a real
        // run so the host-injected text benefits from the min-chunk
        // prosody fix and any emotion routing.
        if speak, let vc = voiceController {
            vc.reset()
            vc.pushDelta(trimmed, emotion: emotion)
            vc.finishTurn(finalText: nil, emotion: emotion)
        }

        return msg
    }

    /// Inject a scripted assistant turn whose text is *revealed
    /// progressively* in sync with TTS playback, so the bubble feels
    /// alive instead of materialising fully-formed.
    ///
    /// Functionally a streaming-simulation variant of
    /// ``appendAssistantMessage``: the full utterance is pushed to the
    /// `VoiceController` immediately (so audio starts at t=0) while the
    /// on-screen content grows word-by-word at the requested rate. Each
    /// mutation re-publishes ``messages``, which triggers
    /// ``MessageListView``'s content-change handler and keeps the bubble
    /// pinned to the bottom as it expands — the same auto-follow path a
    /// real SSE-driven reply uses.
    ///
    /// Guarded against a live real run the same way the other scripted
    /// inserts are. ``currentStreamingMessageId`` is set for the
    /// duration of the reveal and cleared before ``completion`` runs,
    /// so the host can chain a follow-up insert (e.g. action buttons)
    /// without tripping the scripted-insert refusal in
    /// ``appendContentBlocksMessage``.
    ///
    /// - Parameters:
    ///   - text: The full utterance. Empty / whitespace-only input is a
    ///     no-op and returns `nil`.
    ///   - speak: Push the full text through the `VoiceController`
    ///     chunker + finishTurn so the standard TTS pipeline plays it.
    ///   - emotion: Optional prosody hint forwarded to the voice path.
    ///   - wordsPerMinute: Reveal cadence. 180 wpm is the natural
    ///     conversational band for ElevenLabs at default speed; lower
    ///     for a more deliberate feel, higher for snappier.
    ///   - completion: Called on the main actor after the final word
    ///     lands and `currentStreamingMessageId` is cleared. Audio may
    ///     still be playing — this signals *visual* completion only.
    /// - Returns: The inserted ``Message`` (already in ``messages``
    ///   with empty content), or `nil` if the insert was refused.
    @discardableResult
    public func appendAssistantMessageStreamed(
        _ text: String,
        speak: Bool = false,
        emotion: Emotion? = nil,
        wordsPerMinute: Double = 180,
        completion: (() -> Void)? = nil
    ) -> Message? {
        let trimmed = text
        guard !trimmed.isEmpty else { return nil }
        if runState == .streaming || currentStreamingMessageId != nil {
            return nil
        }

        let id = "assistant-injected-\(Date().timeIntervalSince1970)"
        let msg = Message(
            id: id,
            role: .assistant,
            content: "",
            type: .message,
            metadata: nil
        )
        messages.append(msg)
        currentStreamingMessageId = id

        if !firstAssistantMessageFired {
            firstAssistantMessageFired = true
            config.onFirstAssistantMessage?(id)
        }

        // Voice: start the whole utterance at t=0 so the spoken audio
        // runs alongside the visual reveal. The chunker emits as the
        // host's TTS provider streams audio back; the on-screen
        // word-cadence below is an independent, approximate pacing
        // intended to *feel* synchronised without needing per-phoneme
        // timing callbacks from the voice pipeline.
        if speak {
            if let vc = voiceController {
                print("[Voice/streamed] pushing \(trimmed.count) chars — controller.isEnabled=\(vc.isEnabled)")
                vc.reset()
                vc.pushDelta(trimmed, emotion: emotion)
                vc.finishTurn(finalText: nil, emotion: emotion)
            } else {
                print("[Voice/streamed] SKIPPED — voiceController is nil at inject time")
            }
        } else {
            print("[Voice/streamed] speak=false, no voice push")
        }

        // Per-word delay derived from the requested WPM. Clamp at a
        // floor so a pathologically low WPM (or zero) doesn't stall
        // the reveal indefinitely.
        let wpm = max(wordsPerMinute, 30)
        let perWordSeconds = 60.0 / wpm
        let perWordNanos = UInt64(perWordSeconds * 1_000_000_000)

        // Preserve whitespace runs so contractions / line breaks / em
        // dashes survive the reveal exactly as written.
        let tokens = Self.revealTokens(for: trimmed)

        Task { @MainActor in
            var accumulated = ""
            for token in tokens {
                accumulated += token
                if let idx = messages.firstIndex(where: { $0.id == id }) {
                    messages[idx].content = accumulated
                }
                // Whitespace-only tokens don't add visible characters,
                // so skip the dwell on them — pacing is driven by
                // word emissions only.
                if !token.allSatisfy({ $0.isWhitespace }) {
                    try? await Task.sleep(nanoseconds: perWordNanos)
                }
            }
            // Make sure the final content matches the source exactly,
            // even if a token splitter edge case lost a character.
            if let idx = messages.firstIndex(where: { $0.id == id }),
               messages[idx].content != trimmed {
                messages[idx].content = trimmed
            }
            currentStreamingMessageId = nil
            completion?()
        }

        return msg
    }

    /// Split `text` into a sequence of reveal tokens, alternating
    /// non-whitespace runs (words) and whitespace runs (separators).
    /// Concatenating the tokens in order reproduces the input exactly,
    /// which matters because the streaming reveal mutates the bubble's
    /// content one token at a time.
    private static func revealTokens(for text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentIsSpace: Bool? = nil
        for ch in text {
            let isSpace = ch.isWhitespace
            if let was = currentIsSpace, was != isSpace {
                tokens.append(current)
                current = ""
            }
            current.append(ch)
            currentIsSpace = isSpace
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Inject a scripted assistant turn that consists solely of rich
    /// ``ContentBlock``s (e.g. an action-button row, a card, a callout).
    /// Distinct from ``appendAssistantMessage``: that path produces a
    /// text bubble (`type == .message`) and silently drops any blocks
    /// passed in metadata, because ``MessageView`` only renders content
    /// blocks when the message's discriminator is `.contentBlocks`.
    ///
    /// Typical pairing is one ``appendAssistantMessage(_:speak:blocks:emotion:)``
    /// for the narration followed by this call for the interactive
    /// affordance underneath, mirroring how a real turn streams text
    /// first and then emits a `content.blocks` event.
    ///
    /// Refuses to splice into an active stream for the same reason
    /// ``appendAssistantMessage`` does. Returns the resulting ``Message``,
    /// or `nil` if the insertion was skipped or `blocks` was empty.
    @discardableResult
    public func appendContentBlocksMessage(
        _ blocks: [ContentBlock]
    ) -> Message? {
        guard !blocks.isEmpty else { return nil }
        if runState == .streaming || currentStreamingMessageId != nil {
            return nil
        }

        let id = "assistant-blocks-\(Date().timeIntervalSince1970)"
        let msg = Message(
            id: id,
            role: .assistant,
            content: "",
            type: .contentBlocks,
            metadata: MessageMetadata(contentBlocks: blocks)
        )
        messages.append(msg)
        return msg
    }

    // MARK: - Local History (ephemeral mode)

    /// Returns the list of locally-persisted conversations (newest first).
    /// In non-ephemeral mode this always returns `[]`.
    public func loadLocalConversations() -> [LocalConversationSummary] {
        guard let store = localHistoryStore else { return [] }
        let list = store.loadIndex()
        localConversations = list
        return list
    }

    /// Hydrates the VM with a locally-persisted conversation.
    /// Returns `true` if the conversation was found and loaded.
    @discardableResult
    public func loadLocalConversation(id: String) -> Bool {
        guard let store = localHistoryStore,
              let conv = store.load(id) else { return false }
        messages = conv.messages.map { $0.toMessage() }
        conversationId = id
        localConversationCreatedAt = conv.createdAt
        storage.set(config.conversationIdKey, value: id)
        hasMoreMessages = false
        messagesOffset = 0
        error = nil
        // Restored history already contains earlier assistant turns —
        // the first-assistant lifecycle hook fires only for *new*
        // messages, not for replayed ones.
        firstAssistantMessageFired = messages.contains { $0.role == .assistant }
        return true
    }

    /// Delete a single locally-persisted conversation.
    public func deleteLocalConversation(id: String) {
        localHistoryStore?.delete(id)
        localConversations = localHistoryStore?.loadIndex() ?? []
        // If the active conversation was deleted, clear state
        if conversationId == id {
            clearMessages()
        }
    }

    /// Purge all locally-persisted conversations for this agent.
    public func purgeLocalHistory() {
        localHistoryStore?.purgeAll()
        localConversations = []
    }

    /// Wipe all on-device data for this agent — call on logout / sign-out so a
    /// later holder of the device finds nothing. Clears the local conversation
    /// history, the cached client memories, the in-memory transcript, and the
    /// stored auth/anonymous token (removed from the Keychain when the secure
    /// store is in use).
    public func clearAllLocalData() {
        purgeLocalHistory()
        storage.set(Self.memoriesStorageKey, value: nil)
        clientMemories = []
        messages = []
        conversationId = nil
        apiClient.clearSession()
    }

    /// Persist the current conversation to the on-device store.
    /// No-op outside ephemeral mode or when there's nothing to save.
    private func persistToLocalHistory() {
        guard config.ephemeral,
              let store = localHistoryStore,
              let convId = conversationId,
              !messages.isEmpty else { return }

        let now = Date()
        let title = deriveConversationTitle()
        let localMsgs = messages.map { LocalMessage(from: $0) }
        let conv = LocalConversation(
            id: convId,
            title: title,
            createdAt: localConversationCreatedAt ?? now,
            updatedAt: now,
            messages: localMsgs
        )
        store.upsert(conv)
        localConversations = store.loadIndex()
    }

    /// Derive a title from the first user message, capped to 60 chars.
    /// Falls back to "Untitled conversation" when the conversation has no
    /// user message yet (shouldn't happen in practice but keeps the row
    /// rendering safe).
    private func deriveConversationTitle() -> String {
        guard let firstUser = messages.first(where: { $0.role == .user }) else {
            return "Untitled conversation"
        }
        let collapsed = firstUser.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if collapsed.isEmpty { return "Untitled conversation" }
        return collapsed.count <= 60 ? collapsed : String(collapsed.prefix(60)) + "…"
    }

    // MARK: - System Selection

    /// The effective agent key — uses the selected system's entry agent if set
    public var effectiveAgentKey: String {
        if let slug = selectedSystemSlug,
           let system = systems.first(where: { $0.slug == slug }),
           let entry = system.entryAgent {
            return entry.slug
        }
        return config.agentKey
    }

    /// Load available systems from the backend
    public func loadSystems() async {
        isLoadingSystems = true
        do {
            let loaded = try await apiClient.loadSystems()
            systems = loaded

            // Auto-select if only one system and nothing saved
            if selectedSystemSlug == nil && loaded.count == 1 {
                selectSystem(loaded[0])
            }
        } catch {
            print("[ChatViewModel] Failed to load systems: \(error)")
        }
        isLoadingSystems = false
    }

    /// Select a system — updates the effective agent key and starts a new conversation
    public func selectSystem(_ system: AgentSystem) {
        let previousSlug = selectedSystemSlug
        selectedSystemSlug = system.slug
        storage.set(config.systemKey, value: system.slug)

        // Auto-set version to the active one
        selectedSystemVersion = system.activeVersion
        storage.set(config.systemVersionKey, value: system.activeVersion)

        // Find the active version's ID for backend pinning
        let activeVersionId = system.versions?.first(where: { $0.isActive })?.id
        selectedSystemVersionId = activeVersionId
        storage.set(config.systemVersionIdKey, value: activeVersionId)

        // If the system changed, clear the conversation so the new agent key takes effect
        if previousSlug != system.slug {
            clearMessages()
        }
    }

    /// Select a specific version of the current system
    public func selectSystemVersion(_ version: AgentSystemVersionSummary) {
        selectedSystemVersion = version.version
        storage.set(config.systemVersionKey, value: version.version)
        selectedSystemVersionId = version.id
        storage.set(config.systemVersionIdKey, value: version.id)
        // Changing version within the same system also resets the conversation
        clearMessages()
    }

    /// Clear the system selection
    public func clearSystemSelection() {
        selectedSystemSlug = nil
        selectedSystemVersion = nil
        selectedSystemVersionId = nil
        storage.set(config.systemKey, value: nil)
        storage.set(config.systemVersionKey, value: nil)
        storage.set(config.systemVersionIdKey, value: nil)
    }

    // MARK: - Model picker

    /// Fetch the runtime's catalogue of available LLM models so the
    /// picker in `ModelOptionsSheet` has something to show. Idempotent
    /// and safe to call from `.task` on every appearance — the view
    /// just re-renders with the same list. Failures are logged but not
    /// surfaced as errors, because the picker has a sensible empty
    /// state ("Using runtime default") and the run path still works
    /// without any client-side model selection.
    public func loadModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let response = try await apiClient.loadModels()
            availableModels = response.models
            runtimeDefaultModelId = response.default
            // If the persisted selection refers to a model the runtime
            // no longer advertises (renamed / removed), drop it so the
            // picker falls back to the runtime default rather than
            // showing a stale label.
            if let chosen = selectedModelId,
               !availableModels.contains(where: { $0.id == chosen }) {
                selectedModelId = nil
            }
        } catch {
            print("[ChatViewModel] Failed to load models: \(error)")
        }
    }

    /// User picked a model in `ModelOptionsSheet`. Storing `nil` reverts
    /// to "use the runtime default" — handy when a host wants to expose
    /// a "Reset" affordance later.
    public func selectModel(_ modelId: String?) {
        selectedModelId = modelId
    }

    /// Load a specific conversation
    public func loadConversation(_ convId: String) async {
        // Ephemeral mode: conversation is local-only, nothing to fetch.
        if config.ephemeral {
            conversationId = convId
            isLoading = false
            return
        }

        isLoading = true
        messages = []
        conversationId = convId
        storage.set(config.conversationIdKey, value: convId)

        do {
            let conversation = try await apiClient.loadConversation(id: convId)

            if let apiMessages = conversation.messages {
                messages = apiMessages.flatMap { mapApiMessage($0) }
            }

            hasMoreMessages = conversation.hasMore ?? false
            messagesOffset = conversation.messages?.count ?? 0

            // Suppress the first-assistant lifecycle hook for restored
            // conversations that already contain an assistant turn.
            firstAssistantMessageFired = messages.contains { $0.role == .assistant }

        } catch APIError.notFound {
            conversationId = nil
            storage.set(config.conversationIdKey, value: nil)
        } catch {
            print("[ChatViewModel] Failed to load conversation: \(error)")
        }

        isLoading = false
    }
    
    /// Load more messages (pagination)
    public func loadMoreMessages() async {
        guard let convId = conversationId, !loadingMoreMessages, hasMoreMessages else { return }
        
        loadingMoreMessages = true
        
        do {
            let conversation = try await apiClient.loadConversation(id: convId, limit: 10, offset: messagesOffset)
            
            if let apiMessages = conversation.messages, !apiMessages.isEmpty {
                let olderMessages = apiMessages.flatMap { mapApiMessage($0) }
                messages.insert(contentsOf: olderMessages, at: 0)
                messagesOffset += apiMessages.count
                hasMoreMessages = conversation.hasMore ?? false
            } else {
                hasMoreMessages = false
            }
        } catch {
            print("[ChatViewModel] Failed to load more messages: \(error)")
        }
        
        loadingMoreMessages = false
    }

    /// Edit a message and resend from that point
    public func editMessage(at index: Int, newContent: String, model: String? = nil, thinking: Bool = false) async {
        guard !isLoading, index < messages.count else { return }

        let messageToEdit = messages[index]
        guard messageToEdit.role == .user else { return }

        // Truncate messages to just before this message
        messages = Array(messages.prefix(index))

        // Send the edited message with supersede flag
        await sendMessage(newContent, model: model, thinking: thinking, supersedeFromMessageIndex: index)
    }

    /// Retry from a specific message
    public func retryMessage(at index: Int, model: String? = nil, thinking: Bool = false) async {
        guard !isLoading, index < messages.count else { return }

        let messageAtIndex = messages[index]
        var userMessageIndex = index
        var userMessage = messageAtIndex

        // If this is an assistant message, find the previous user message
        if messageAtIndex.role == .assistant {
            for i in stride(from: index - 1, through: 0, by: -1) {
                if messages[i].role == .user {
                    userMessageIndex = i
                    userMessage = messages[i]
                    break
                }
            }
            guard userMessage.role == .user else { return }
        } else if messageAtIndex.role != .user {
            return
        }

        // Truncate messages to just before the user message
        messages = Array(messages.prefix(userMessageIndex))

        // Resend the same message with supersede flag
        await sendMessage(userMessage.content, model: model, thinking: thinking, supersedeFromMessageIndex: userMessageIndex)
    }

    // MARK: - Private Methods

    private func subscribeToEvents(runId: String) async {
        sseClient?.disconnect()

        let eventPath = config.apiPaths.runEventsUrl(for: runId)
        var urlString = "\(config.backendUrl)\(eventPath)"

        // Add token for anonymous auth
        if let token = try? await apiClient.getOrCreateSession() {
            urlString += "?anonymous_token=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)"
        }

        guard let url = URL(string: urlString) else { return }

        assistantContent = ""
        currentStreamingMessageId = nil
        turnFinalized = false
        resetStreamBuffer()
        clearPendingEcho()
        // Drop any sub-agent activity left over from a previous run —
        // shouldn't happen on the happy path (terminal events drain it)
        // but a transport error mid-bracket would otherwise leave a
        // stale pill hovering on the next send.
        subAgentActivity = SubAgentActivityState()

        let client = SSEClient()
        sseClient = client

        client.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleSSEEvent(event)
            }
        }

        // Suspend until the stream reaches a terminal state. Resolution
        // happens in `onError`, `onComplete`, or `cancelRun` — whichever
        // fires first. `resumeStreamContinuation` is single-shot so a late
        // callback after cancellation is a no-op.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.streamContinuation = continuation

            client.onError = { [weak self] error in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.isLoading = false
                    self.error = error.localizedDescription
                    self.resumeStreamContinuation()
                }
            }

            client.onComplete = { [weak self] in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.isLoading = false
                    self.resumeStreamContinuation()
                }
            }

            print("[ChatViewModel] subscribing runId=\(runId) url=\(redactURLForLogging(url))")
            client.connect(url: url, headers: apiClient.authHeaders())
        }
    }

    /// Single-shot resume of the in-flight stream awaiter. Safe to call
    /// from `onComplete`, `onError`, and `cancelRun`; only the first call
    /// resumes the continuation, subsequent calls are no-ops.
    private func resumeStreamContinuation() {
        guard let continuation = streamContinuation else { return }
        streamContinuation = nil
        continuation.resume()
    }

    private func handleSSEEvent(_ event: SSEEvent) {
        guard let json = event.json(), let payload = json["payload"] as? [String: Any] else {
            #if DEBUG
            print("[AgentFrontend][ChatVM] dropping event type=\(event.type) — no payload")
            #endif
            return
        }

        #if DEBUG
        let payloadKeys = Array(payload.keys).sorted().joined(separator: ",")
        print("[AgentFrontend][ChatVM] dispatch type=\(event.type) payload_keys=[\(payloadKeys)]")
        #endif

        // Notify callback
        config.onEvent?(event.type, payload)
        runState = runState.applying(eventType: event.type)

        switch event.type {
        case "assistant.delta":
            handleAssistantDelta(payload)

        case "assistant.message":
            handleAssistantMessage(payload)

        case "tool.call":
            handleToolCall(payload)

        case "tool.result":
            handleToolResult(payload)

        case "sub_agent.start":
            handleSubAgentStart(payload)

        case "sub_agent.end":
            handleSubAgentEnd(payload)

        case "content.blocks":
            handleContentBlocks(payload)

        case "custom":
            handleCustomEvent(payload)

        case "memory.update":
            handleMemoryUpdate(payload)

        case "client.action.required", "run.suspended":
            handleRequiredAction(payload)

        case "run.succeeded", "run.failed", "run.cancelled", "run.timed_out":
            handleTerminalEvent(event.type, payload)

        default:
            break
        }
    }

    /// Handle an `assistant.delta` event — a single chunk of streamed text.
    /// Backend emits many of these in sequence when STREAM_RESPONSES is on,
    /// each with `{"delta": "<words>"}`. We accumulate them into the current
    /// streaming assistant message for a typewriter effect.
    private func handleAssistantDelta(_ payload: [String: Any]) {
        guard let delta = payload["delta"] as? String else { return }

        // Pill mode: while a sub-agent bracket is active the deltas are
        // narration from a sub-agent (or its own deltas, since we don't
        // emit a parent delta until the bracket closes). Divert them
        // into the activity ticker rather than the message list so the
        // wall of intermediate chatter never produces a bubble. Voice
        // intentionally stays silent here — the user only hears the
        // parent orchestrator's final synthesis.
        if usesPillActivity && subAgentActivity.isActive {
            subAgentActivity.appendDelta(delta)
            return
        }

        // Drop late-arriving deltas for a turn whose authoritative
        // `assistant.message` has already been applied. Otherwise they
        // spawn a second bubble that types out content we've already
        // shown in full. A new turn is signalled by a non-streaming
        // event (tool/video/sub-agent), which resets `turnFinalized`.
        if turnFinalized { return }

        // Per-delta emotion overrides the turn-level value when present.
        let emotion = Emotion.from(payload["emotion"])

        // Sub-agent echo suppression. After a sub-agent finishes streaming
        // its final answer, the parent typically re-streams the exact same
        // text as its own deltas (it's echoing the tool result). Buffer the
        // parent's output silently while it still matches the sub-agent's
        // snapshot as a prefix — only render if it diverges (parent genuinely
        // adds something) or extends past the snapshot.
        if let reference = pendingEchoReference, !pendingEchoDiverged {
            pendingEchoBuffer.append(delta)
            if reference.hasPrefix(pendingEchoBuffer) {
                // Still tracking the sub-agent's content — don't render.
                return
            }
            // Diverged. Decide how much of what we've buffered to show.
            pendingEchoDiverged = true
            pendingEchoReference = nil
            let replay: String
            if pendingEchoBuffer.hasPrefix(reference) {
                // Parent extended the sub-agent's answer. Show only the
                // novel tail as a fresh bubble below.
                replay = String(pendingEchoBuffer.dropFirst(reference.count))
            } else {
                // Parent said something different from the first char —
                // render everything it has sent so far.
                replay = pendingEchoBuffer
            }
            pendingEchoBuffer = ""
            if replay.isEmpty { return }
            // Start a new streaming bubble for the parent's own content.
            // `currentStreamingMessageId` was nilled by the sub_agent.end's
            // closeStreamingSession, so the drain will open a fresh bubble.
            assistantContent = ""
            resetStreamBuffer()
            streamBuffer.append(replay)
            voiceController?.pushDelta(replay, emotion: emotion)
            startDrainTimerIfNeeded()
            return
        }

        // Detect a *fresh* stream session — one where there's nothing
        // already in-flight to belong to. We can't rely on
        // `currentStreamingMessageId` alone: that ID is only assigned on
        // the first `drainTick`, so when multiple deltas arrive within the
        // same runloop turn (network bursts where several SSE events sit
        // in the same TCP read, or replay in tests) the later deltas would
        // all see a nil ID and wipe each other's contribution to the
        // buffer. Treat any of: an existing bubble, a running drain, or
        // un-drained buffered text as proof we're still mid-session.
        // Peering at `messages.last.id.hasPrefix("assistant-stream-")` is
        // also misleading because a just-snapped bubble (from
        // `assistant.message` after the session was closed by a
        // tool/video/sub-agent insertion) shares that prefix but its
        // session is already over — the next stream belongs to a new turn
        // and must create a fresh bubble below it.
        let hasActiveSession = currentStreamingMessageId != nil
            || drainTimer != nil
            || !streamBuffer.isEmpty
        if !hasActiveSession {
            assistantContent = ""
            resetStreamBuffer()
        }

        // Enqueue into buffer; drain timer reveals chars at a steady rate.
        streamBuffer.append(delta)
        voiceController?.pushDelta(delta, emotion: emotion)
        startDrainTimerIfNeeded()
    }

    /// Handle an `assistant.message` event — the final authoritative text
    /// emitted after any deltas (or on its own when streaming is off).
    /// We *replace* the accumulator with the full content so the message is
    /// correct whether or not the client received every delta.
    private func handleAssistantMessage(_ payload: [String: Any]) {
        guard let content = payload["content"] as? String else { return }

        // Pill mode: while a sub-agent bracket is active the
        // authoritative final message belongs to the sub-agent, not to
        // a user-visible bubble. Snap the ticker to the final text so
        // the pill stops mid-stream-looking, and return — the matching
        // `sub_agent.end` will pop the frame and emit the collapsed
        // history row.
        if usesPillActivity && subAgentActivity.isActive {
            subAgentActivity.setFinal(content)
            return
        }

        // Mark the turn finalised *unconditionally* — this is the server's
        // authoritative "this turn is done" signal. Any `assistant.delta`
        // that arrives later (whether because some providers flush a
        // trailing token burst after the final-message event, or because
        // the main agent re-streams the same content it already received
        // via a sub-agent tool result) must be dropped to avoid a second
        // typewriter bubble below the one we're about to finalise.
        turnFinalized = true

        // Voice: if the run streamed deltas the chunker has been fed
        // throughout — `finishTurn(finalText: nil)` flushes the trailing
        // fragment. If it didn't (non-streaming run, or an SSE that only
        // emits the authoritative message), pass `content` so the user
        // still hears the reply.
        let voiceEmotion = Emotion.from(payload["emotion"])
        let needsFallbackText = streamBuffer.isEmpty && drainTimer == nil
        voiceController?.finishTurn(
            finalText: needsFallbackText ? content : nil,
            emotion: voiceEmotion
        )

        // Sub-agent echo resolution. If we were still comparing the parent's
        // stream against a sub-agent snapshot when the final message lands,
        // the snapshot's bubble already shows the authoritative text —
        // anything matching (or shorter than) the reference must NOT produce
        // a second bubble; anything extending it shows only the tail.
        if let reference = pendingEchoReference {
            clearPendingEcho()
            if content == reference || reference.hasPrefix(content) {
                // Pure echo or partial echo — sub-agent bubble covers it.
                return
            }
            if content.hasPrefix(reference) {
                // Parent extended the answer. Render only the novel suffix
                // as a fresh bubble below the sub-agent's one.
                let suffix = String(content.dropFirst(reference.count))
                if suffix.isEmpty { return }
                assistantContent = suffix
                upsertStreamingMessage(content: assistantContent)
                closeStreamingSession()
                turnFinalized = true
                return
            }
            // Parent said something genuinely different — fall through to
            // the normal finalisation path so the full content is rendered.
        }

        // If deltas are still draining, the same content is already queued
        // in streamBuffer; snapping here would produce a visible leap to the
        // end. Let the drain finish smoothly — the turn-finalised flag is
        // already set so any post-drain stragglers will be dropped.
        if drainTimer != nil || !streamBuffer.isEmpty {
            return
        }

        // No drain active — either non-streaming mode, replay, or the
        // stream was already finalised by a non-delta event. Apply the
        // authoritative text to the tracked streaming message; if that
        // session was already closed (e.g. by a preceding content.blocks
        // or tool.result insertion), upsert creates a fresh bubble below.
        assistantContent = content
        upsertStreamingMessage(content: assistantContent)
        // Preserve `turnFinalized` across the close — a non-streaming
        // event (tool/video/sub-agent) is what resets it for the next turn.
        closeStreamingSession()
        turnFinalized = true
    }

    /// Create or update the in-flight streaming assistant message.
    /// Uses `currentStreamingMessageId` to locate the message even when
    /// non-streaming messages (tool calls, content blocks, sub-agent
    /// events) have been appended after it.
    private func upsertStreamingMessage(content: String) {
        if let id = currentStreamingMessageId,
           let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].content = content
        } else {
            let id = "assistant-stream-\(Date().timeIntervalSince1970)"
            currentStreamingMessageId = id
            messages.append(Message(
                id: id,
                role: .assistant,
                content: content,
                type: .message
            ))
            // Lifecycle hook: first assistant bubble in this
            // conversation. Latch so it only fires once per conv.
            if !firstAssistantMessageFired {
                firstAssistantMessageFired = true
                config.onFirstAssistantMessage?(id)
            }
        }
    }

    /// Close out the current streaming session before inserting any
    /// non-delta message (tool call, tool result, sub-agent start/end,
    /// content blocks, custom events, terminal errors).
    ///
    /// Two things must happen atomically here:
    ///   1. **Flush any pending buffer** into the current streaming bubble
    ///      so the user sees the full text the server had already sent —
    ///      otherwise the bubble is truncated mid-sentence.
    ///   2. **Forget the streaming bubble's ID** (`currentStreamingMessageId`)
    ///      so the next text event — whether `assistant.message` (snap)
    ///      or a run of `assistant.delta`s (typewriter) — creates a
    ///      *new* bubble **below** the non-streaming insertion rather
    ///      than reaching back up and overwriting the old bubble above it.
    ///
    /// Skipping step 2 produces the "message appears all at once AND the
    /// typewriter keeps typing below" double-render bug: the authoritative
    /// `assistant.message` lands on the old bubble (above the video card)
    /// while subsequent deltas spawn a fresh bubble below.
    private func closeStreamingSession() {
        if drainTimer != nil || !streamBuffer.isEmpty {
            flushStreamBuffer()
        }
        currentStreamingMessageId = nil
        assistantContent = ""
        streamingDone = false
        // A non-streaming event marks a turn boundary — subsequent deltas
        // belong to a new turn and must flow into a fresh bubble.
        turnFinalized = false
    }

    private func handleToolCall(_ payload: [String: Any]) {
        let name = payload["name"] as? String ?? payload["tool_name"] as? String ?? "tool"

        // Pill mode: tool calls from inside a sub-agent bracket are part
        // of the same "thinking" activity and shouldn't show as a bubble.
        // Surface the latest tool name on the pill instead so the user
        // still sees what the sub-agent is reaching for.
        if usesPillActivity && subAgentActivity.isActive {
            subAgentActivity.noteToolCall(name)
            return
        }

        closeStreamingSession()
        // A new tool call by the parent means it's doing more work rather
        // than echoing a finished sub-agent — any stashed echo reference
        // is stale now.
        clearPendingEcho()
        messages.append(Message(
            id: "tool-call-\(Date().timeIntervalSince1970)",
            role: .assistant,
            content: "🔧 \(name)",
            type: .toolCall,
            metadata: MessageMetadata(
                toolName: name,
                toolCallId: payload["id"] as? String ?? payload["tool_call_id"] as? String,
                arguments: stringifyPayload(payload["arguments"] ?? payload["tool_args"])
            )
        ))
    }

    private func handleToolResult(_ payload: [String: Any]) {
        // Pill mode: silently absorb tool results that arrive inside a
        // sub-agent bracket — the activity pill already reflects the
        // tool call, and we don't want a "✓ Done" row in the history
        // for work the user only saw as a ticker tail.
        if usesPillActivity && subAgentActivity.isActive {
            return
        }

        closeStreamingSession()
        let result = payload["result"] as? [String: Any]
        let isError = result?["error"] != nil
        let content = isError ? "❌ \(result?["error"] ?? "Error")" : "✓ Done"

        messages.append(Message(
            id: "tool-result-\(Date().timeIntervalSince1970)",
            role: .system,
            content: content,
            type: .toolResult,
            metadata: MessageMetadata(
                toolName: payload["name"] as? String ?? payload["tool_name"] as? String,
                toolCallId: payload["tool_call_id"] as? String ?? payload["id"] as? String,
                result: result
            )
        ))
    }

    private func stringifyPayload(_ value: Any?) -> String? {
        guard let value = value else { return nil }
        if let string = value as? String { return string }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return String(describing: value) }
        return String(data: data, encoding: .utf8)
    }

    /// `true` when the host has opted into pill-style sub-agent activity
    /// (the warm-dark default). In this mode the reducer suppresses
    /// per-event sub-agent bubbles and instead diverts the activity into
    /// `subAgentActivity`, leaving behind a single collapsed history row
    /// on bracket close. `false` preserves the original behaviour: every
    /// sub-agent event becomes its own bubble.
    private var usesPillActivity: Bool {
        subAgentActivityStyle == .pill
    }

    private func handleSubAgentStart(_ payload: [String: Any]) {
        closeStreamingSession()
        // A new sub-agent invocation supersedes any pending echo reference
        // from a previous one.
        clearPendingEcho()
        let agentName = payload["agent_name"] as? String ?? payload["sub_agent_key"] as? String ?? "sub-agent"

        if usesPillActivity {
            // Pill mode: don't emit a "🔗 Delegating…" bubble; the pill
            // view will pick up the new frame and render the agent name
            // next to its live ticker tail.
            subAgentActivity.push(SubAgentActivityState.Frame(
                agentName: agentName,
                subAgentKey: payload["sub_agent_key"] as? String
            ))
            return
        }

        messages.append(Message(
            id: "sub-agent-start-\(Date().timeIntervalSince1970)",
            role: .system,
            content: "🔗 Delegating to \(agentName)...",
            type: .subAgentStart,
            metadata: MessageMetadata(
                subAgentKey: payload["sub_agent_key"] as? String,
                agentName: payload["agent_name"] as? String,
                invocationMode: payload["invocation_mode"] as? String
            )
        ))
    }

    private func handleSubAgentEnd(_ payload: [String: Any]) {
        if usesPillActivity {
            // Pop the matching frame. If it was the outermost one, drop a
            // single quiet "Consulted <agent> · 4s" row into the history
            // so the bracket is still represented on reload (and for
            // post-hoc skim-reading). The parent's own final reply will
            // render below this row as the actual answer — no echo
            // suppression in pill mode because the sub-agent never
            // produced a bubble whose echo we'd need to hide.
            let popped = subAgentActivity.pop()
            let agentName = payload["agent_name"] as? String
                ?? popped?.agentName
                ?? "Sub-agent"
            if !subAgentActivity.isActive, let frame = popped {
                let duration = Date().timeIntervalSince(frame.startedAt)
                messages.append(Message(
                    id: "sub-agent-end-\(Date().timeIntervalSince1970)",
                    role: .system,
                    content: "Consulted \(agentName) · \(Self.formatDuration(duration))",
                    type: .subAgentEnd,
                    metadata: MessageMetadata(
                        subAgentKey: payload["sub_agent_key"] as? String,
                        agentName: agentName,
                        subAgentDurationSeconds: duration
                    )
                ))
            }
            return
        }

        closeStreamingSession()
        // After the session is closed the sub-agent's final streamed text is
        // committed to its bubble — capture it as the echo reference so the
        // parent agent's upcoming re-stream of the same response can be
        // suppressed while still letting the sub-agent's narration render.
        let echoReference = lastStreamedAssistantText()
        let agentName = payload["agent_name"] as? String ?? "Sub-agent"
        messages.append(Message(
            id: "sub-agent-end-\(Date().timeIntervalSince1970)",
            role: .system,
            content: "✓ \(agentName) completed",
            type: .subAgentEnd,
            metadata: MessageMetadata(
                subAgentKey: payload["sub_agent_key"] as? String,
                agentName: payload["agent_name"] as? String
            )
        ))
        if let text = echoReference, !text.isEmpty {
            pendingEchoReference = text
            pendingEchoBuffer = ""
            pendingEchoDiverged = false
        }
    }

    /// Format an elapsed-seconds value for the collapsed thought row.
    /// Sub-1s rounds to one decimal so quick handoffs don't display as
    /// "0s"; longer durations show whole seconds.
    private static func formatDuration(_ seconds: Double) -> String {
        if seconds < 1 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds.rounded()))s"
    }

    private func handleContentBlocks(_ payload: [String: Any]) {
        closeStreamingSession()
        guard let blocksArray = payload["blocks"] as? [[String: Any]] else {
            #if DEBUG
            print("[AgentFrontend][ChatVM] content.blocks: payload has no 'blocks' array — keys=\(Array(payload.keys))")
            #endif
            return
        }
        #if DEBUG
        let rawTypes = blocksArray.compactMap { $0["type"] as? String }
        print("[AgentFrontend][ChatVM] content.blocks: \(blocksArray.count) raw block(s) types=\(rawTypes) tool=\(payload["tool_name"] ?? "-")")
        #endif
        let blocks = ContentBlock.parse(from: blocksArray)
        #if DEBUG
        print("[AgentFrontend][ChatVM] content.blocks: parsed \(blocks.count) typed block(s)")
        if blocks.count != blocksArray.count {
            print("[AgentFrontend][ChatVM] content.blocks: WARNING — parse dropped \(blocksArray.count - blocks.count) block(s); check ContentBlock Codable schema")
        }
        #endif
        guard !blocks.isEmpty else {
            #if DEBUG
            print("[AgentFrontend][ChatVM] content.blocks: dropping — parsed to empty")
            #endif
            return
        }

        messages.append(Message(
            id: "content-blocks-\(Date().timeIntervalSince1970)",
            role: .assistant,
            content: "",
            type: .contentBlocks,
            metadata: MessageMetadata(
                toolName: payload["tool_name"] as? String,
                toolCallId: payload["tool_call_id"] as? String,
                contentBlocks: blocks
            )
        ))
    }

    private func handleRequiredAction(_ payload: [String: Any]) {
        closeStreamingSession()
        clearPendingEcho()
        voiceController?.stop()

        let action = payload["required_action"] as? [String: Any] ?? payload
        let title = action["title"] as? String ?? "Action required"
        let message = action["message"] as? String ?? "Please complete the requested action to continue."
        let actionId = action["action_id"] as? String
        let alreadyRendered = actionId != nil && messages.contains {
            $0.type == .requiredAction && $0.metadata?.actionId == actionId
        }
        if !alreadyRendered {
            messages.append(Message(
                id: "required-action-\(Date().timeIntervalSince1970)",
                role: .system,
                content: message,
                type: .requiredAction,
                metadata: MessageMetadata(
                    actionId: actionId,
                    actionType: action["action_type"] as? String,
                    actionURL: action["action_url"] as? String,
                    actionLabel: action["action_label"] as? String ?? title,
                    resumeHint: action["resume_hint"]
                )
            ))
        }

        isLoading = false
        sseClient?.disconnect()
        sseClient = nil
        currentRunId = nil
        runState = .waiting
        resumeStreamContinuation()
        persistToLocalHistory()
    }

    private func handleCustomEvent(_ payload: [String: Any]) {
        closeStreamingSession()
        if payload["type"] as? String == "agent_context" {
            let agentName = payload["agent_name"] as? String ?? "Sub-agent"
            messages.append(Message(
                id: "agent-context-\(Date().timeIntervalSince1970)",
                role: .system,
                content: "🔗 \(agentName) is now handling this request",
                type: .agentContext,
                metadata: MessageMetadata(
                    subAgentKey: payload["agent_key"] as? String,
                    agentName: agentName
                )
            ))
        }
    }

    /// Handle a `memory.update` event — the server extracted memories from
    /// the conversation and is sending them back for client-side persistence.
    private func handleMemoryUpdate(_ payload: [String: Any]) {
        guard let memoriesArray = payload["memories"] as? [[String: Any]] else { return }

        for mem in memoriesArray {
            guard let key = mem["key"] as? String else { continue }
            let action = mem["action"] as? String ?? "upsert"

            if action == "delete" {
                clientMemories.removeAll { $0["key"] == key }
            } else {
                // Upsert: remove old entry with same key, then append
                clientMemories.removeAll { $0["key"] == key }
                var entry: [String: String] = ["key": key]
                if let value = mem["value"] as? String {
                    entry["value"] = value
                }
                if let type = mem["type"] as? String {
                    entry["type"] = type
                }
                clientMemories.append(entry)
            }
        }

        // Persist to local storage
        if let data = try? JSONSerialization.data(withJSONObject: clientMemories),
           let json = String(data: data, encoding: .utf8) {
            storage.set(Self.memoriesStorageKey, value: json)
        }

        #if DEBUG
        print("[AgentFrontend][ChatVM] memory.update: \(clientMemories.count) memories persisted")
        #endif
    }

    // MARK: - Stream buffer helpers

    /// Start the drain timer if it isn't already running.
    /// The timer is added to `.common` RunLoop modes so it continues to fire
    /// while the user is touch-scrolling (UITrackingRunLoopMode). Without this,
    /// `Timer.scheduledTimer` only registers for `.default` mode and the
    /// typewriter effect freezes whenever a scroll gesture is active.
    private func startDrainTimerIfNeeded() {
        guard drainTimer == nil else { return }
        let timer = Timer(timeInterval: drainInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drainTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        drainTimer = timer
    }

    /// Move a slice of buffered chars into the visible message.
    /// Rate is adaptive: small buffer reveals slowly (readable), large buffer
    /// drains faster so a long response never lags far behind the server.
    /// A short word-boundary lookahead lets short words land as a unit
    /// instead of being cut into 2-char pulses, which reads as much
    /// smoother at the same effective char-per-second rate.
    private func drainTick() {
        guard !streamBuffer.isEmpty else {
            drainTimer?.invalidate()
            drainTimer = nil
            streamingDone = false
            // The previous tick committed the final chars to the bubble
            // via upsertStreamingMessage; safe to persist now.
            if pendingPersistAfterDrain {
                pendingPersistAfterDrain = false
                persistToLocalHistory()
            }
            return
        }
        let pending = streamBuffer.count
        // Steady readable typewriter pace (~33 chars/sec) when in sync with
        // the stream; accelerate only when the buffer grows large or the
        // server has finished and we need to catch up without a tail lag.
        let cap = streamingDone ? 6 : 2
        var take = max(1, min(pending / 120, cap))

        // Word-boundary preference: if the slice would end mid-word, look
        // ahead a few chars and extend through the next whitespace so the
        // word lands whole. Long words (no space within the lookahead
        // window) still reveal at the base rate, preserving the
        // typewriter feel for them.
        if take < pending {
            let lastIdx = streamBuffer.index(streamBuffer.startIndex, offsetBy: take - 1)
            if !streamBuffer[lastIdx].isWhitespace {
                let lookahead = min(pending - take, 5)
                var probe = take
                for _ in 0..<lookahead {
                    let idx = streamBuffer.index(streamBuffer.startIndex, offsetBy: probe)
                    probe += 1
                    if streamBuffer[idx].isWhitespace {
                        take = probe
                        break
                    }
                }
            }
        }

        let endIdx = streamBuffer.index(streamBuffer.startIndex, offsetBy: take)
        let slice = String(streamBuffer[..<endIdx])
        streamBuffer.removeFirst(take)
        assistantContent.append(slice)
        upsertStreamingMessage(content: assistantContent)
    }

    /// Drain all remaining buffered chars and stop the timer.
    private func flushStreamBuffer() {
        if !streamBuffer.isEmpty {
            assistantContent.append(streamBuffer)
            streamBuffer.removeAll(keepingCapacity: false)
            upsertStreamingMessage(content: assistantContent)
        }
        drainTimer?.invalidate()
        drainTimer = nil
    }

    /// Drop buffered chars and stop the timer (used on stream start / auth).
    private func resetStreamBuffer() {
        streamBuffer.removeAll(keepingCapacity: false)
        drainTimer?.invalidate()
        drainTimer = nil
        streamingDone = false
    }

    /// Reset the sub-agent echo-suppression state. Called at turn
    /// boundaries where continuing to compare the parent's stream
    /// against a prior sub-agent snapshot would be meaningless.
    private func clearPendingEcho() {
        pendingEchoReference = nil
        pendingEchoBuffer = ""
        pendingEchoDiverged = false
    }

    /// Content of the most recent assistant message bubble, used as the
    /// echo-suppression reference when a sub-agent has just ended.
    /// Intermediate tool-call, tool-result, content-block and sub-agent
    /// markers are skipped — we want the last actual streamed answer.
    private func lastStreamedAssistantText() -> String? {
        for msg in messages.reversed() {
            if msg.role == .assistant && msg.type == .message && !msg.content.isEmpty {
                return msg.content
            }
        }
        return nil
    }

    private func handleTerminalEvent(_ type: String, _ payload: [String: Any]) {
        print("[ChatViewModel] terminal type=\(type) runId=\(currentRunId ?? "nil")")
        if type == "run.failed" {
            // Close out the stream so the error message doesn't orphan a
            // streaming bubble or cause subsequent text to overwrite it.
            closeStreamingSession()
            clearPendingEcho()
            // Cancel any in-flight TTS — the user shouldn't hear a half
            // sentence after the failure banner appears.
            voiceController?.stop()
            let errMsg = payload["error"] as? String ?? "Agent run failed"
            error = errMsg
            messages.append(Message(
                id: "error-\(Date().timeIntervalSince1970)",
                role: .system,
                content: "❌ Error: \(errMsg)",
                type: .error
            ))
        } else {
            // Success / cancelled / timed-out: let the drain timer finish
            // smoothly at its elevated catch-up rate; flushing all remaining
            // chars would produce a visible end-of-reply leap. The timer
            // self-invalidates when the buffer empties.
            streamingDone = true
            // The run is over — any still-pending echo reference can't be
            // resolved by another event and would only leak into the next
            // turn if not cleared.
            clearPendingEcho()
            if type == "run.cancelled" || type == "run.timed_out" {
                voiceController?.stop()
            } else {
                // Success: flush any trailing text the chunker still holds
                // so the final fragment gets spoken. No-op when
                // assistant.message already flushed.
                voiceController?.finishTurn()
            }
        }

        isLoading = false
        sseClient?.disconnect()
        sseClient = nil
        currentRunId = nil

        // Persist to local history store (ephemeral mode).
        // On the success path the drain timer may still be revealing the
        // final assistant chars into the bubble; defer until it empties so
        // the persisted snapshot includes the full assistant message. The
        // error path closes the streaming session up-front (above) so the
        // buffer is already drained.
        if drainTimer != nil || !streamBuffer.isEmpty {
            pendingPersistAfterDrain = true
        } else {
            persistToLocalHistory()
        }
    }

    private func mapApiMessage(_ m: APIMessage) -> [Message] {
        let timestamp = m.timestamp ?? Date()

        // Tool result messages (role: "tool"). If the backend persisted
        // contentBlocks on the tool message we synthesise an extra bubble so
        // the rich UI (videos, cards, etc.) re-renders on conversation reload.
        if m.role == "tool" {
            var out: [Message] = [Message(
                role: .system,
                content: "✓ Done",
                timestamp: timestamp,
                type: .toolResult,
                metadata: MessageMetadata(
                    toolName: m.metadata?.toolName,
                    toolCallId: m.toolCallId,
                    result: m.content
                )
            )]
            if let blocks = m.metadata?.contentBlocks, !blocks.isEmpty {
                out.append(Message(
                    role: .assistant,
                    content: "",
                    timestamp: timestamp,
                    type: .contentBlocks,
                    metadata: MessageMetadata(
                        toolName: m.metadata?.toolName,
                        toolCallId: m.toolCallId,
                        contentBlocks: blocks
                    )
                ))
            }
            return out
        }

        // Assistant messages with tool calls
        if m.role == "assistant", let toolCalls = m.toolCalls, !toolCalls.isEmpty {
            return toolCalls.map { tc in
                let name = tc.function?.name ?? tc.name ?? "tool"
                return Message(
                    role: .assistant,
                    content: "🔧 \(name)",
                    timestamp: timestamp,
                    type: .toolCall,
                    metadata: MessageMetadata(
                        toolName: name,
                        toolCallId: tc.id,
                        arguments: tc.function?.arguments ?? tc.arguments
                    )
                )
            }
        }

        // Skip empty assistant messages
        let content = m.content ?? ""
        if m.role == "assistant" && content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }

        // Regular messages
        return [Message(
            role: MessageRole(rawValue: m.role) ?? .user,
            content: content,
            timestamp: timestamp,
            type: .message
        )]
    }
}

