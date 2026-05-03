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
        error = nil
        
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

            let run = try await apiClient.createRun(
                conversationId: conversationId,
                messages: apiMessages,
                model: model,
                thinking: thinking,
                supersedeFromMessageIndex: supersedeFromMessageIndex,
                agentKeyOverride: effectiveAgentKey != config.agentKey ? effectiveAgentKey : nil,
                systemVersionId: selectedSystemVersionId,
                ephemeral: config.ephemeral,
                memories: config.ephemeral ? clientMemories : nil
            )

            print("[ChatViewModel] createRun response runId=\(run.id) conversationId=\(run.conversationId ?? "nil")")

            currentRunId = run.id

            // Update conversation ID if new
            if conversationId == nil, let newConvId = run.conversationId {
                conversationId = newConvId
                storage.set(config.conversationIdKey, value: newConvId)
                // Mark creation time for the local conversation
                if config.ephemeral {
                    localConversationCreatedAt = Date()
                }
            }

            // Subscribe to SSE events
            await subscribeToEvents(runId: run.id)
            
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }
    
    /// Cancel the current run
    public func cancelRun() async {
        guard let runId = currentRunId, isLoading else { return }

        do {
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
            isLoading = false
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
        pendingPersistAfterDrain = false
        storage.set(config.conversationIdKey, value: nil)
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

        // Drop late-arriving deltas for a turn whose authoritative
        // `assistant.message` has already been applied. Otherwise they
        // spawn a second bubble that types out content we've already
        // shown in full. A new turn is signalled by a non-streaming
        // event (tool/video/sub-agent), which resets `turnFinalized`.
        if turnFinalized { return }

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
        startDrainTimerIfNeeded()
    }

    /// Handle an `assistant.message` event — the final authoritative text
    /// emitted after any deltas (or on its own when streaming is off).
    /// We *replace* the accumulator with the full content so the message is
    /// correct whether or not the client received every delta.
    private func handleAssistantMessage(_ payload: [String: Any]) {
        guard let content = payload["content"] as? String else { return }

        // Mark the turn finalised *unconditionally* — this is the server's
        // authoritative "this turn is done" signal. Any `assistant.delta`
        // that arrives later (whether because some providers flush a
        // trailing token burst after the final-message event, or because
        // the main agent re-streams the same content it already received
        // via a sub-agent tool result) must be dropped to avoid a second
        // typewriter bubble below the one we're about to finalise.
        turnFinalized = true

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
        closeStreamingSession()
        // A new tool call by the parent means it's doing more work rather
        // than echoing a finished sub-agent — any stashed echo reference
        // is stale now.
        clearPendingEcho()
        let name = payload["name"] as? String ?? "tool"
        messages.append(Message(
            id: "tool-call-\(Date().timeIntervalSince1970)",
            role: .assistant,
            content: "🔧 \(name)",
            type: .toolCall,
            metadata: MessageMetadata(
                toolName: name,
                toolCallId: payload["id"] as? String,
                arguments: payload["arguments"] as? String
            )
        ))
    }

    private func handleToolResult(_ payload: [String: Any]) {
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
                toolName: payload["name"] as? String,
                toolCallId: payload["tool_call_id"] as? String,
                result: result
            )
        ))
    }

    private func handleSubAgentStart(_ payload: [String: Any]) {
        closeStreamingSession()
        // A new sub-agent invocation supersedes any pending echo reference
        // from a previous one.
        clearPendingEcho()
        let agentName = payload["agent_name"] as? String ?? payload["sub_agent_key"] as? String ?? "sub-agent"
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
        if type == "run.failed" {
            // Close out the stream so the error message doesn't orphan a
            // streaming bubble or cause subsequent text to overwrite it.
            closeStreamingSession()
            clearPendingEcho()
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

