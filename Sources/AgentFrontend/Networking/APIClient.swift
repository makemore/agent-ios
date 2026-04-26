import Foundation

/// API client for chat widget backend communication
public class APIClient {
    let config: ChatWidgetConfig
    let storage: StorageService
    private var authToken: String?

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

    private lazy var decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private lazy var encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

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
    
    /// Get or create a session token
    public func getOrCreateSession(forceRefresh: Bool = false) async throws -> String? {
        let strategy = authStrategy
        
        if strategy != .anonymous {
            return authToken ?? config.authToken
        }
        
        // Check existing token
        if !forceRefresh {
            if let token = authToken {
                return token
            }
            if let stored = storage.get(config.anonymousTokenKey) {
                authToken = stored
                return stored
            }
        }
        
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
        
        let tokenResponse = try decoder.decode(TokenResponse.self, from: data)
        authToken = tokenResponse.token
        storage.set(config.anonymousTokenKey, value: tokenResponse.token)
        
        return tokenResponse.token
    }
    
    /// Clear the stored session
    public func clearSession() {
        authToken = nil
        storage.set(config.anonymousTokenKey, value: nil)
    }
    
    /// Update auth token
    public func setAuthToken(_ token: String?) {
        authToken = token
    }
    
    // MARK: - Request Building
    
    /// Build auth headers for a request
    public func authHeaders(token: String? = nil) -> [String: String] {
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

