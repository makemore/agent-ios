import Foundation

/// Authentication strategy for API requests
public enum AuthStrategy: String, Codable {
    /// Token authentication (Django REST Framework style)
    /// Sends: Authorization: Token {token}
    case token
    
    /// JWT/Bearer authentication
    /// Sends: Authorization: Bearer {token}
    case jwt
    
    /// Session-based authentication (cookies)
    /// Relies on session cookies, no auth header
    case session
    
    /// Anonymous session tokens
    /// Fetches token from endpoint, sends: X-Anonymous-Token: {token}
    case anonymous
    
    /// No authentication
    case none
    
    /// Default header name for this strategy
    public var defaultHeader: String {
        switch self {
        case .token, .jwt:
            return "Authorization"
        case .anonymous:
            return "X-Anonymous-Token"
        case .session, .none:
            return ""
        }
    }
    
    /// Default token prefix for this strategy
    public var defaultPrefix: String {
        switch self {
        case .token:
            return "Token"
        case .jwt:
            return "Bearer"
        case .anonymous, .session, .none:
            return ""
        }
    }
}

/// API case style for request/response transformation
public enum APICaseStyle: String, Codable {
    /// Backend uses camelCase
    case camel
    
    /// Backend uses snake_case
    case snake
    
    /// Accept both in responses, send snake_case in requests
    case auto
}

