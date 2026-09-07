import Foundation

extension APIClient {
    
    // MARK: - Conversations
    
    /// Load conversations list
    public func loadConversations() async throws -> [Conversation] {
        let generation = authenticationGeneration
        let token = try await getOrCreateSession()
        try validateAuthenticationGeneration(generation)
        let path = "\(config.apiPaths.conversations)?agent_key=\(config.agentKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? config.agentKey)"
        let request = buildRequest(path: path, method: "GET", token: token)
        
        let (data, response) = try await session.data(for: request)
        try validateAuthenticationGeneration(generation)
        
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
    
    /// Recent bounded page; explicit nil retains the legacy unpaginated API.
    /// Keyset cursors take precedence over offsets when supplied by the server.
    public func loadConversation(id: String, limit: Int? = 50, offset: Int = 0, beforeSeq: Int? = nil) async throws -> Conversation {
        let generation = authenticationGeneration
        let token = try await getOrCreateSession()
        try validateAuthenticationGeneration(generation)
        var path = "\(config.apiPaths.conversations)\(id)/"
        if let limit {
            path += "?limit=\(max(1, min(limit, 100)))"
            path += beforeSeq.map { "&before_seq=\($0)" } ?? "&offset=\(max(0, offset))"
        }
        let request = buildRequest(path: path, method: "GET", token: token)
        
        let (data, response) = try await session.data(for: request)
        try validateAuthenticationGeneration(generation)
        
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
    @MainActor public func createRun(
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
        params: [String: Any]? = nil,
        idempotencyKey: String = UUID().uuidString,
        beforePost: (@MainActor (Data) throws -> Void)? = nil
    ) async throws -> AgentRun {
        var body: [String: Any] = [
            "idempotency_key": idempotencyKey,
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

        let jsonData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try await postRun(body: jsonData, beforePost: beforePost)
    }

    /// Transport retry only: never reconstruct a request from current UI settings.
    @MainActor public func postRun(body jsonData: Data, beforePost: (@MainActor (Data) throws -> Void)? = nil) async throws -> AgentRun {
        let generation = authenticationGeneration
        let token = try await getOrCreateSession()
        try validateAuthenticationGeneration(generation)
        try Task.checkCancellation()
        // No actor suspension between the host's identity/lifecycle fence,
        // durable save, and submitting the original bytes to URLSession.
        try beforePost?(jsonData)
        try validateAuthenticationGeneration(generation)
        let request = buildRequest(path: config.apiPaths.runs, method: "POST", body: jsonData, token: token)
        
        let (data, response) = try await session.data(for: request)
        try validateAuthenticationGeneration(generation)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        
        if httpResponse.statusCode == 401 {
            // Minting a different anonymous identity cannot recover this send.
            // Let the host restore authentication; never retry as another owner.
            throw APIError.unauthorized
        }
        
        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
        
        return try decoder.decode(AgentRun.self, from: data)
    }

    public func loadRun(id: String) async throws -> AgentRun {
        try await getRun(path: "\(config.apiPaths.runs)\(id)/")
    }

    /// 404 means unknown key (safe to retry identical creation while retained);
    /// 410 means expired/deleted, and must never cause another POST.
    public func loadRun(idempotencyKey: String) async throws -> AgentRun {
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "idempotency_key", value: idempotencyKey)]
        return try await getRun(path: "\(config.apiPaths.runs)by-idempotency-key/?\(query.percentEncodedQuery ?? "")")
    }

    private func getRun(path: String) async throws -> AgentRun {
        let generation = authenticationGeneration
        let token = try await getOrCreateSession()
        try validateAuthenticationGeneration(generation)
        let request = buildRequest(path: path, method: "GET", token: token)
        let (data, response) = try await session.data(for: request)
        try validateAuthenticationGeneration(generation)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.unauthorized }
        if http.statusCode == 404 { throw APIError.notFound }
        guard http.statusCode == 200 else { throw APIError.httpError(statusCode: http.statusCode) }
        return try decoder.decode(AgentRun.self, from: data)
    }
    
    /// Cancel a run
    public func cancelRun(id: String) async throws {
        let generation = authenticationGeneration
        let token = try await getOrCreateSession()
        try validateAuthenticationGeneration(generation)
        let path = config.apiPaths.cancelRunUrl(for: id)
        let request = buildRequest(path: path, method: "POST", token: token)
        
        let (_, response) = try await session.data(for: request)
        try validateAuthenticationGeneration(generation)
        
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

