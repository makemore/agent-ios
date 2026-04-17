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

    // MARK: - Dependencies

    private let config: ChatWidgetConfig
    private let apiClient: APIClient
    private let storage: StorageService

    // MARK: - Initialization

    public init(config: ChatWidgetConfig, apiClient: APIClient, storage: StorageService) {
        self.config = config
        self.apiClient = apiClient
        self.storage = storage

        // Load saved conversation ID
        if let savedId = storage.get(config.conversationIdKey) {
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
    }

    /// Restore the saved conversation on launch (call from .task or .onAppear)
    public func restoreConversationIfNeeded() async {
        guard !hasRestoredConversation else { return }
        hasRestoredConversation = true

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
            // Create the run
            let apiMessages: [[String: Any]] = [["role": "user", "content": content.trimmingCharacters(in: .whitespacesAndNewlines)]]
            
            let run = try await apiClient.createRun(
                conversationId: conversationId,
                messages: apiMessages,
                model: model,
                thinking: thinking,
                supersedeFromMessageIndex: supersedeFromMessageIndex,
                agentKeyOverride: effectiveAgentKey != config.agentKey ? effectiveAgentKey : nil,
                systemVersionId: selectedSystemVersionId
            )
            
            currentRunId = run.id
            
            // Update conversation ID if new
            if conversationId == nil, let newConvId = run.conversationId {
                conversationId = newConvId
                storage.set(config.conversationIdKey, value: newConvId)
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
    
    /// Clear all messages and start fresh
    public func clearMessages() {
        messages = []
        conversationId = nil
        error = nil
        hasMoreMessages = false
        messagesOffset = 0
        storage.set(config.conversationIdKey, value: nil)
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
        resetStreamBuffer()

        let client = SSEClient()
        sseClient = client

        client.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleSSEEvent(event)
            }
        }

        client.onError = { [weak self] error in
            Task { @MainActor in
                self?.isLoading = false
                self?.error = error.localizedDescription
            }
        }

        client.onComplete = { [weak self] in
            Task { @MainActor in
                self?.isLoading = false
            }
        }

        client.connect(url: url, headers: apiClient.authHeaders())
    }

    private func handleSSEEvent(_ event: SSEEvent) {
        guard let json = event.json(), let payload = json["payload"] as? [String: Any] else { return }

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

        // Start a fresh accumulator if the last message isn't an in-flight
        // streaming assistant message (e.g. a tool.call was just inserted).
        let lastIsStreaming = messages.last.map {
            $0.role == .assistant && $0.id.hasPrefix("assistant-stream-")
        } ?? false
        if !lastIsStreaming {
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

        // If deltas are still draining, the same content is already queued
        // in streamBuffer; snapping here would produce a visible leap to the
        // end. Ignore and let the drain finish smoothly instead.
        if drainTimer != nil || !streamBuffer.isEmpty {
            return
        }

        // No drain active (non-streaming mode or replay) — apply directly.
        assistantContent = content
        upsertStreamingMessage(content: assistantContent)
    }

    /// Create or update the in-flight streaming assistant message.
    private func upsertStreamingMessage(content: String) {
        if let lastIndex = messages.indices.last,
           messages[lastIndex].role == .assistant,
           messages[lastIndex].id.hasPrefix("assistant-stream-") {
            messages[lastIndex].content = content
        } else {
            messages.append(Message(
                id: "assistant-stream-\(Date().timeIntervalSince1970)",
                role: .assistant,
                content: content,
                type: .message
            ))
        }
    }

    private func handleToolCall(_ payload: [String: Any]) {
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
    }

    private func handleContentBlocks(_ payload: [String: Any]) {
        guard let blocksArray = payload["blocks"] as? [[String: Any]] else { return }
        let blocks = ContentBlock.parse(from: blocksArray)
        guard !blocks.isEmpty else { return }

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


    // MARK: - Stream buffer helpers

    /// Start the drain timer if it isn't already running.
    private func startDrainTimerIfNeeded() {
        guard drainTimer == nil else { return }
        drainTimer = Timer.scheduledTimer(withTimeInterval: drainInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drainTick() }
        }
    }

    /// Move a slice of buffered chars into the visible message.
    /// Rate is adaptive: small buffer reveals slowly (readable), large buffer
    /// drains faster so a long response never lags far behind the server.
    private func drainTick() {
        guard !streamBuffer.isEmpty else {
            drainTimer?.invalidate()
            drainTimer = nil
            streamingDone = false
            return
        }
        let pending = streamBuffer.count
        // Steady readable typewriter pace (~33 chars/sec) when in sync with
        // the stream; accelerate only when the buffer grows large or the
        // server has finished and we need to catch up without a tail lag.
        let cap = streamingDone ? 6 : 2
        let take = max(1, min(pending / 120, cap))
        let slice = streamBuffer.prefix(take)
        streamBuffer.removeFirst(slice.count)
        assistantContent.append(contentsOf: slice)
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

    private func handleTerminalEvent(_ type: String, _ payload: [String: Any]) {
        // Let the drain timer finish smoothly at its elevated catch-up rate;
        // flushing all remaining chars would produce a visible end-of-reply
        // leap. The timer self-invalidates when the buffer empties.
        streamingDone = true

        if type == "run.failed" {
            let errMsg = payload["error"] as? String ?? "Agent run failed"
            error = errMsg
            messages.append(Message(
                id: "error-\(Date().timeIntervalSince1970)",
                role: .system,
                content: "❌ Error: \(errMsg)",
                type: .error
            ))
        }

        isLoading = false
        sseClient?.disconnect()
        sseClient = nil
        currentRunId = nil
    }

    private func mapApiMessage(_ m: APIMessage) -> [Message] {
        let timestamp = m.timestamp ?? Date()

        // Tool result messages (role: "tool")
        if m.role == "tool" {
            return [Message(
                role: .system,
                content: "✓ Done",
                timestamp: timestamp,
                type: .toolResult,
                metadata: MessageMetadata(
                    toolCallId: m.toolCallId,
                    result: m.content
                )
            )]
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

