import Foundation

/// API errors
public enum APIError: LocalizedError {
    case invalidResponse
    case unauthorized
    case notFound
    case httpError(statusCode: Int)
    case serverError(message: String)
    case sessionCreationFailed
    case cancelFailed
    case decodingError(Error)
    case networkError(Error)
    case insecureTransport(host: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .unauthorized:
            return "Unauthorized - please check your credentials"
        case .notFound:
            return "Resource not found"
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        case .serverError(let message):
            return message
        case .sessionCreationFailed:
            return "Failed to create session"
        case .cancelFailed:
            return "Failed to cancel run"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .insecureTransport(let host):
            return "Refusing to send over an insecure (non-HTTPS) connection to \(host). "
                + "Use an https:// backend URL, or set allowInsecureHTTP for local development."
        }
    }
}

