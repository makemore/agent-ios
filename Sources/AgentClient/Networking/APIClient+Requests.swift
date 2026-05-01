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
    public func createRun(
        conversationId: String?,
        messages: [[String: Any]],
        model: String? = nil,
        thinking: Bool = false,
        supersedeFromMessageIndex: Int? = nil,
        agentKeyOverride: String? = nil,
        systemVersionId: String? = nil,
        ephemeral: Bool = false
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

        if let systemVersionId = systemVersionId {
            body["systemVersionId"] = systemVersionId
        }

        if ephemeral {
            body["ephemeral"] = true
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
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
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

    // MARK: - Decoder

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

