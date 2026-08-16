import Foundation

extension APIClient {
    
    // MARK: - Conversations
    
    /// Load conversations list
    public func loadConversations() async throws -> [Conversation] {
        let token = try await getOrCreateSession()
        let path = "\(config.apiPaths.conversations)?agent_key=\(config.agentKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? config.agentKey)"
        let request = buildRequest(path: path, method: "GET", token: token)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }
        
        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        // Try to decode as paginated response first, then as array
        if let listResponse = try? decoder.decode(ConversationListResponse.self, from: data) {
            return listResponse.results ?? []
        }
        
        return try decoder.decode([Conversation].self, from: data)
    }
    
    /// Load a specific conversation
    public func loadConversation(id: String, limit: Int = 10, offset: Int = 0) async throws -> Conversation {
        let token = try await getOrCreateSession()
        let path = "\(config.apiPaths.conversations)\(id)/?limit=\(limit)&offset=\(offset)"
        let request = buildRequest(path: path, method: "GET", token: token)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        if httpResponse.statusCode == 404 {
            throw APIError.notFound
        }
        
        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try decoder.decode(Conversation.self, from: data)
    }
    
    // MARK: - Runs
    
    /// Create a new agent run
    ///
    /// `params` is forwarded verbatim under the request body's `params`
    /// key. The backend's `AgentRunCreateSerializer` already accepts an
    /// arbitrary dict here and folds `model` / `thinking` into it on
    /// arrival — see `agent/django_agent_runtime/api/views.py`. This is
    /// how we ship behaviour knobs (response_style, tool_access,
    /// research, web_search, etc.) without breaking the wire format
    /// every time a new toggle is added.
    public func createRun(
        conversationId: String?,
        messages: [[String: Any]],
        model: String? = nil,
        thinking: Bool = false,
        supersedeFromMessageIndex: Int? = nil,
        supersedeOriginalContent: String? = nil,
        supersedeUserMessageOrdinal: Int? = nil,
        agentKeyOverride: String? = nil,
        systemVersionId: String? = nil,
        ephemeral: Bool = false,
        privateOnly: Bool = false,
        memories: [[String: String]]? = nil,
        params: [String: Any]? = nil
    ) async throws -> AgentRun {
        let token = try await getOrCreateSession()

        var body: [String: Any] = [
            "agentKey": agentKeyOverride ?? config.agentKey,
            "messages": messages,
            "metadata": config.metadata.merging(["journeyType": config.defaultJourneyType]) { _, new in new }
        ]

        if let conversationId = conversationId {
            body["conversationId"] = conversationId
        }

        if let model = model {
            body["model"] = model
        }

        if thinking {
            body["thinking"] = true
        }

        if let index = supersedeFromMessageIndex {
            body["supersedeFromMessageIndex"] = index
        }

        // Robust edit/retry hints: the edited user message's original text
        // and its ordinal among user-role messages. The backend prefers
        // these over the display-row index above, which can drift from the
        // server's transcript (tool rows, hidden trigger messages).
        if let original = supersedeOriginalContent {
            body["supersedeOriginalContent"] = original
        }
        if let ordinal = supersedeUserMessageOrdinal {
            body["supersedeUserMessageOrdinal"] = ordinal
        }

        if let systemVersionId = systemVersionId {
            body["systemVersionId"] = systemVersionId
        }

        if ephemeral {
            body["ephemeral"] = true
        }

        if privateOnly {
            body["private_only"] = true
        }

        if let memories = memories, !memories.isEmpty {
            body["memories"] = memories
        }

        if let params = params, !params.isEmpty {
            body["params"] = params
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)
        let request = buildRequest(path: config.apiPaths.runs, method: "POST", body: jsonData, token: token)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        if httpResponse.statusCode == 401 {
            // Try refreshing token
            clearSession()
            if let newToken = try await getOrCreateSession(forceRefresh: true) {
                let retryRequest = buildRequest(path: config.apiPaths.runs, method: "POST", body: jsonData, token: newToken)
                let (retryData, retryResponse) = try await session.data(for: retryRequest)
                
                guard let retryHttpResponse = retryResponse as? HTTPURLResponse, retryHttpResponse.statusCode == 200 || retryHttpResponse.statusCode == 201 else {
                    throw APIError.unauthorized
                }
                
                return try decoder.decode(AgentRun.self, from: retryData)
            }
            throw APIError.unauthorized
        }
        
        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            if let errorData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorData["error"] as? String ?? errorData["detail"] as? String {
                throw APIError.serverError(message: error)
            }
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try decoder.decode(AgentRun.self, from: data)
    }
    
    /// Cancel a run
    public func cancelRun(id: String) async throws {
        let token = try await getOrCreateSession()
        let path = config.apiPaths.cancelRunUrl(for: id)
        let request = buildRequest(path: path, method: "POST", token: token)
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...204).contains(httpResponse.statusCode) else {
            throw APIError.cancelFailed
        }
    }
    
    // MARK: - Systems Discovery

    /// Load available agent systems
    public func loadSystems() async throws -> [AgentSystem] {
        let token = try await getOrCreateSession()
        let path = config.apiPaths.systems
        let request = buildRequest(path: path, method: "GET", token: token)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // Try paginated response first, then plain array
        if let listResponse = try? decoder.decode(SystemsListResponse.self, from: data) {
            return listResponse.results ?? []
        }

        return try decoder.decode([AgentSystem].self, from: data)
    }

    // MARK: - Voice

    /// Mint a short-lived bearer token for the TTS streaming endpoint.
    ///
    /// The token is bound to the current authenticated principal and may
    /// embed quota/rate-limit metadata. Voice providers should call this
    /// before each playback session and refresh on 401.
    ///
    /// Returns ``nil`` when the backend has no voice endpoint configured.
    public func voiceToken() async throws -> VoiceToken? {
        guard let path = config.apiPaths.voiceToken else { return nil }
        let token = try await getOrCreateSession()
        let request = buildRequest(path: path, method: "POST", body: Data("{}".utf8), token: token)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.httpError(statusCode: http.statusCode)
        }

        // The Django voice endpoint emits snake_case keys regardless of
        // the per-request format header (the response is a tiny dict that
        // the view assembles directly). Decode against both shapes.
        struct WireToken: Decodable {
            let token: String
            let ttsUrl: String?
            let tts_url: String?
            let expiresAt: Date?
            let expires_at: Date?
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let wire = try dec.decode(WireToken.self, from: data)
        let urlField = (wire.ttsUrl ?? wire.tts_url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let absolute = urlField.hasPrefix("/") ? "\(config.backendUrl)\(urlField)" : urlField
        let expires = wire.expiresAt ?? wire.expires_at ?? Date().addingTimeInterval(240)
        return VoiceToken(token: wire.token, ttsUrl: absolute, expiresAt: expires)
    }

    /// List voices the configured provider exposes (e.g. ElevenLabs).
    public func voices() async throws -> [VoiceDescriptor] {
        guard let path = config.apiPaths.voiceVoices else { return [] }
        let token = try await getOrCreateSession()
        let request = buildRequest(path: path, method: "GET", token: token)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 404 { return [] }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.httpError(statusCode: http.statusCode)
        }
        struct WireVoices: Decodable {
            let voices: [VoiceDescriptor]?
        }
        let dec = JSONDecoder()
        return (try? dec.decode(WireVoices.self, from: data).voices) ?? []
    }

    // MARK: - Models

    /// Fetch the list of LLM models the runtime is willing to route to.
    /// Hits `GET /api/agent-runtime/models/` (configurable via
    /// `APIPaths.models`) — the same endpoint the web client uses to
    /// populate its model dropdown. Decodes the snake_case payload via
    /// the explicit `CodingKeys` on `AgentModel`.
    public func loadModels() async throws -> ModelsResponse {
        let token = try await getOrCreateSession()
        let request = buildRequest(path: config.apiPaths.models, method: "GET", token: token)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.httpError(statusCode: http.statusCode)
        }
        return try decoder.decode(ModelsResponse.self, from: data)
    }

    // MARK: - Decoder

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

