import Foundation

extension APIClient: LiveVoiceSignaling {
    /// Signaling only: audio travels directly over native WebRTC media tracks.
    /// Deliberately not retried: creation can succeed even if the response is lost.
    @MainActor
    public func createLiveSession(sdp: String, conversationId: String?) async throws -> LiveSessionResponse {
        let generation = authenticationGeneration
        let token = try await getOrCreateSession()
        try validateAuthenticationGeneration(generation)
        try Task.checkCancellation()
        var body = ["sdp": sdp]
        if let conversationId { body["conversation_id"] = conversationId }
        let data = try JSONEncoder().encode(body)
        let request = liveRequest(path: Self.liveSessionsPath, body: data, token: token, timeout: 30)
        let (responseData, response) = try await session.data(for: request)
        try Self.validateLiveResponse(response)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result: LiveSessionResponse
        do {
            result = try decoder.decode(LiveSessionResponse.self, from: responseData)
        } catch {
            // A malformed answer may still have created a billable session.
            struct CreatedID: Decodable { let id: String }
            if let created = try? decoder.decode(CreatedID.self, from: responseData) {
                await closeCreatedLiveSession(id: created.id, using: request)
            }
            throw APIError.invalidResponse
        }
        do {
            try validateAuthenticationGeneration(generation)
        } catch {
            // Keep the original request's identity solely for cleanup; never
            // close an old user's session using a newly signed-in user's token.
            await closeCreatedLiveSession(id: result.id, using: request)
            throw error
        }
        // Do not discard a successfully created ID on caller cancellation. The
        // attempt owner needs it to close a late-created provider session.
        return result
    }

    @MainActor
    public func closeLiveSession(id: String) async throws {
        guard UUID(uuidString: id) != nil else { throw APIError.invalidResponse }
        let generation = authenticationGeneration
        let token = try await getOrCreateSession()
        try validateAuthenticationGeneration(generation)
        let request = liveRequest(path: "\(Self.liveSessionsPath)\(id)/close/",
                                  body: Data("{}".utf8), token: token, timeout: 10)
        let (_, response) = try await session.data(for: request)
        try Self.validateLiveResponse(response)
    }

    /// A read-only, uncached check of the worker's history commit. Never creates
    /// or retries a live session, refreshes credentials, or trusts provider IDs.
    @MainActor
    public func liveSessionStatus(id: String) async throws -> LiveSessionStatus {
        guard let expectedId = UUID(uuidString: id) else { throw APIError.invalidResponse }
        try Task.checkCancellation()
        let generation = authenticationGeneration
        let token = try await getOrCreateSession()
        try validateAuthenticationGeneration(generation)
        try Task.checkCancellation()
        var request = buildRequest(path: "\(Self.liveSessionsPath)\(id)/", token: token)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("snake", forHTTPHeaderField: "X-Api-Format")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try validateAuthenticationGeneration(generation)
        try Self.validateLiveResponse(response)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let status = try? decoder.decode(LiveSessionStatus.self, from: data),
              UUID(uuidString: status.id) == expectedId else { throw APIError.invalidResponse }
        return status
    }

    private static let liveSessionsPath = "/api/agent-runtime/voice/live/sessions/"

    private func closeCreatedLiveSession(id: String, using request: URLRequest) async {
        guard UUID(uuidString: id) != nil else { return }
        var close = request
        close.url = URL(string: "\(config.backendUrl)\(Self.liveSessionsPath)\(id)/close/")
        close.httpBody = Data("{}".utf8)
        close.timeoutInterval = 10
        _ = try? await session.data(for: close)
    }

    private func liveRequest(path: String, body: Data, token: String?, timeout: TimeInterval) -> URLRequest {
        var request = buildRequest(path: path, method: "POST", body: body, token: token)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("snake", forHTTPHeaderField: "X-Api-Format")
        // Respect host-configured URLSession headers/cookie storage. Django's
        // session authentication additionally needs the same-origin CSRF cookie.
        if authStrategy == .session, let url = request.url {
            let configured = session.configuration.httpAdditionalHeaders ?? [:]
            let hasCSRF = configured.keys.contains { String(describing: $0).lowercased() == "x-csrftoken" }
            if !hasCSRF, let cookie = session.configuration.httpCookieStorage?
                .cookies(for: url)?.first(where: { $0.name == "csrftoken" }) {
                request.setValue(cookie.value, forHTTPHeaderField: "X-CSRFToken")
            }
            request.setValue(config.backendUrl, forHTTPHeaderField: "Referer")
        }
        return request
    }

    private static func validateLiveResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.httpError(statusCode: http.statusCode)
        }
    }
}