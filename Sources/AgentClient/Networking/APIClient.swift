import Foundation

/// API client for chat widget backend communication
public class APIClient {
    let config: ChatWidgetConfig
    let storage: StorageService
    private var authToken: String?
    private var sessionCleared = false
    private let authLock = NSRecursiveLock()
    private var authGeneration = UUID()

    private func withAuthLock<T>(_ operation: () throws -> T) rethrows -> T {
        authLock.lock()
        defer { authLock.unlock() }
        return try operation()
    }

    var authenticationGeneration: UUID { withAuthLock { authGeneration } }

    func validateAuthenticationGeneration(_ generation: UUID) throws {
        try withAuthLock {
            guard !sessionCleared, authGeneration == generation else { throw CancellationError() }
        }
    }

    /// A one-way scope fingerprint; never persist credentials in a pending
    /// request or emit them in diagnostics. A changed credential fails closed.
    func recoveryScope(agentKey: String) -> String? {
        authLock.lock(); defer { authLock.unlock() }
        guard !sessionCleared,
              let principal = authToken ?? config.authToken ?? storage.get(config.anonymousTokenKey),
              !principal.isEmpty else { return nil }
        return PendingRunStore.scope(backend: config.backendUrl, agent: "\(agentKey):\(config.defaultJourneyType)", principal: principal)
    }

    var recoveryOwnerScope: String? {
        authLock.lock(); defer { authLock.unlock() }
        guard !sessionCleared, let principal = authToken ?? config.authToken ?? storage.get(config.anonymousTokenKey) else { return nil }
        return PendingRunStore.scope(backend: config.backendUrl, agent: "", principal: principal)
    }

    /// Opaque account/backend/agent/surface namespace for host-owned storage.
    public static func storageNamespace(config: ChatWidgetConfig) -> String? {
        guard let principal = config.authToken else { return nil }
        return PendingRunStore.scope(backend: config.backendUrl,
                                    agent: "\(config.agentKey):\(config.defaultJourneyType)", principal: principal)
    }

    /// Clears all pending agent/surface scopes, including VMs not instantiated
    /// this launch. Call before clearing the authenticated session.
    public func clearPendingRunData() {
        if let owner = recoveryOwnerScope { pendingRunStore.clearAll(owner: owner) }
    }

    /// Explicitly abandon only this agent/surface, leaving other chats intact.
    public func discardPendingRunData() {
        if let scope = recoveryScope(agentKey: config.agentKey) { pendingRunStore.clear(scope: scope) }
    }

    private var pendingRunStore: PendingRunStore {
        let pendingStorage: StorageService = storage is InMemoryStorage
            ? storage : KeychainStorage(service: "com.makemore.agent.pending-runs")
        return PendingRunStore(storage: pendingStorage)
    }

    /// Hook for tests to inject a `URLProtocol` (or otherwise mutate the
    /// session configuration) into the `URLSession` this client uses for
    /// every request. No-op by default in production. Mirrors the same
    /// pattern on `SSEClient` so a test setup can route the entire HTTP
    /// surface through a single mock.
    public static var sessionConfigurator: ((URLSessionConfiguration) -> Void)?

    /// The session used for all HTTP requests. Defaults to a fresh
    /// session built from `URLSessionConfiguration.default` so the
    /// `sessionConfigurator` hook can install custom protocols. Tests
    /// don't need to know this exists — setting `sessionConfigurator`
    /// before constructing the client is enough.
    let session: URLSession

    public init(config: ChatWidgetConfig, storage: StorageService) {
        self.config = config
        self.storage = storage
        self.authToken = config.authToken
        let cfg = URLSessionConfiguration.default
        Self.sessionConfigurator?(cfg)
        self.session = URLSession(configuration: cfg)
    }
    
    // MARK: - Authentication
    
    /// Get the effective auth strategy
    public var authStrategy: AuthStrategy {
        if let strategy = config.authStrategy {
            return strategy
        }
        if config.authToken != nil {
            return .token
        }
        if !config.apiPaths.anonymousSession.isEmpty {
            return .anonymous
        }
        return .none
    }
    
    /// Standard local-development hosts that may use cleartext HTTP even when
    /// `allowInsecureHTTP` is off: loopback, the Android emulator alias, and
    /// `.local` (mDNS/Bonjour) dev servers.
    static func isDevHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "localhost" || h == "127.0.0.1" || h == "::1"
            || h == "10.0.2.2" || h.hasSuffix(".local")
    }

    /// Fail closed on cleartext transport. Called before any network egress so
    /// a misconfigured (http://) production backend never receives data.
    func validateTransport() throws {
        guard let url = URL(string: config.backendUrl),
              let scheme = url.scheme?.lowercased() else {
            throw APIError.insecureTransport(host: config.backendUrl)
        }
        if scheme == "https" { return }
        if config.allowInsecureHTTP { return }
        if Self.isDevHost(url.host) { return }
        throw APIError.insecureTransport(host: url.host ?? config.backendUrl)
    }

    /// Get or create a session token
    public func getOrCreateSession(forceRefresh: Bool = false) async throws -> String? {
        try validateTransport()
        let strategy = authStrategy
        let (generation, existing): (UUID, String?) = try withAuthLock {
            guard !sessionCleared else { throw APIError.unauthorized }
            let existing = authToken ?? (strategy == .anonymous ? storage.get(config.anonymousTokenKey) : config.authToken)
            if let existing { authToken = existing }
            return (authGeneration, existing)
        }
        if strategy != .anonymous || (!forceRefresh && existing != nil) { return existing }
        
        // Fetch new token
        let url = URL(string: "\(config.backendUrl)\(config.apiPaths.anonymousSession)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("camel", forHTTPHeaderField: "X-Api-Format")
        
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.sessionCreationFailed
        }
        
        struct TokenResponse: Codable {
            let token: String
        }
        
        // Session creation may race across callers; keep decoding state local.
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        return try withAuthLock {
            try validateAuthenticationGeneration(generation)
            // Concurrent anonymous-session requests adopt the first accepted
            // identity instead of replacing an identity already used by a send.
            if !forceRefresh, let authToken { return authToken }
            authToken = tokenResponse.token
            storage.set(config.anonymousTokenKey, value: tokenResponse.token)
            return tokenResponse.token
        }
    }
    
    /// Clear the stored session
    public func clearSession() {
        authLock.lock(); defer { authLock.unlock() }
        clearPendingRunData()
        authGeneration = UUID()
        sessionCleared = true
        authToken = nil
        storage.set(config.anonymousTokenKey, value: nil)
    }
    
    /// Update auth token
    public func setAuthToken(_ token: String?) {
        authLock.lock(); defer { authLock.unlock() }
        if authToken != token {
            clearPendingRunData()
            authGeneration = UUID()
        }
        sessionCleared = token == nil
        authToken = token
    }
    
    // MARK: - Request Building
    
    /// Build auth headers for a request
    public func authHeaders(token: String? = nil) -> [String: String] {
        authLock.lock(); defer { authLock.unlock() }
        guard !sessionCleared else { return [:] }
        var headers: [String: String] = [:]
        let strategy = authStrategy
        let effectiveToken = token ?? authToken ?? config.authToken
        
        switch strategy {
        case .token:
            if let token = effectiveToken {
                let header = config.authHeader ?? strategy.defaultHeader
                let prefix = config.authTokenPrefix ?? strategy.defaultPrefix
                headers[header] = prefix.isEmpty ? token : "\(prefix) \(token)"
            }
        case .jwt:
            if let token = effectiveToken {
                let header = config.authHeader ?? strategy.defaultHeader
                let prefix = config.authTokenPrefix ?? strategy.defaultPrefix
                headers[header] = prefix.isEmpty ? token : "\(prefix) \(token)"
            }
        case .anonymous:
            if let token = effectiveToken {
                let header = config.authHeader ?? config.anonymousTokenHeader
                headers[header] = token
            }
        case .session, .none:
            break
        }
        
        return headers
    }
    
    /// Build a URLRequest with auth headers
    public func buildRequest(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        token: String? = nil
    ) -> URLRequest {
        let url = URL(string: "\(config.backendUrl)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = method
        
        for (key, value) in authHeaders(token: token) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // Opt in to the camelCase JSON wire format on backends that
        // support per-request format negotiation. Backends that do not
        // recognise the header simply ignore it.
        request.setValue("camel", forHTTPHeaderField: "X-Api-Format")
        
        if let body = body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        
        return request
    }
}

