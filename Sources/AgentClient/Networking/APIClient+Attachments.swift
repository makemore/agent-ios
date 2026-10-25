import Foundation

/// A photo uploaded to the host's attachments URL (`APIPaths.attachments`).
public struct UploadedAttachment: Codable, Equatable {
    public let id: String
    public let name: String
    public let contentType: String
    public let size: Int

    public init(id: String, name: String, contentType: String, size: Int) {
        self.id = id
        self.name = name
        self.contentType = contentType
        self.size = size
    }

    private enum CodingKeys: String, CodingKey { case id, name, contentType, content_type, size }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Photo"
        contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
            ?? c.decodeIfPresent(String.self, forKey: .content_type) ?? "image/jpeg"
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(contentType, forKey: .contentType)
        try c.encode(size, forKey: .size)
    }
}

/// Why a photo could not be uploaded, worded for the person.
public enum AttachmentUploadError: LocalizedError, Equatable {
    /// 413 `too_large`.
    case tooLarge
    /// 503 `attachments_unavailable`: this host keeps no attachments. Hide the photo button.
    case unavailable
    /// 400: not a photo the server can read (its message).
    case rejected(String)
    /// 401/403/404: not allowed to add photos to this conversation.
    case notAllowed
    /// No connection, or the request did not complete.
    case network
    case http(Int)
    /// No attachments URL is configured.
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "This photo is too large."
        case .unavailable: return "Photos can't be added here."
        case .rejected(let message): return message
        case .notAllowed: return "You can't add photos to this conversation."
        case .network: return "Upload failed. Check the connection and try again."
        case .http: return "Upload failed. Try again."
        case .notConfigured: return "Photos can't be added here."
        }
    }
}

/// Upload progress for one request (data tasks report sent body bytes too).
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    let onProgress: (Double) -> Void
    init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}

extension APIClient {

    // MARK: - Attachments (a thread's photos; only when `apiPaths.attachments` is set)

    /// True when the host gave an attachments URL, so photos upload before sending and the
    /// message carries their ids (`attachment_ids`).
    public var attachmentsEnabled: Bool {
        !(config.apiPaths.attachments ?? "").isEmpty
    }

    func attachmentsURL(_ suffix: String = "") -> URL? {
        guard let base = config.apiPaths.attachments, !base.isEmpty else { return nil }
        let path = (base.hasSuffix("/") ? base : base + "/") + suffix
        if path.lowercased().hasPrefix("https://") || path.lowercased().hasPrefix("http://") {
            return URL(string: path)
        }
        return URL(string: "\(config.backendUrl)\(path)")
    }

    /// Upload one photo (multipart, field `file`) with this client's auth and return its id.
    /// `progress` is called with 0...1 as the body is sent. The data should already be a
    /// photo the server takes (see ``PhotoPreparation``).
    public func uploadAttachment(
        data: Data,
        filename: String,
        contentType: String,
        progress: ((Double) -> Void)? = nil
    ) async throws -> UploadedAttachment {
        guard let url = attachmentsURL() else { throw AttachmentUploadError.notConfigured }
        try validateTransport()
        let generation = authenticationGeneration
        let token = try await getOrCreateSession()
        try validateAuthenticationGeneration(generation)

        let boundary = "AgentClient-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in authHeaders(token: token) { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("camel", forHTTPHeaderField: "X-Api-Format")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(data: data, filename: filename, contentType: contentType, boundary: boundary)

        let responseData: Data
        let response: URLResponse
        do {
            if let progress {
                (responseData, response) = try await session.data(for: request, delegate: UploadProgressDelegate(onProgress: progress))
            } else {
                (responseData, response) = try await session.data(for: request)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AttachmentUploadError.network
        }
        try validateAuthenticationGeneration(generation)
        guard let http = response as? HTTPURLResponse else { throw AttachmentUploadError.network }
        let body = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any] ?? [:]
        let code = body["code"] as? String
        switch http.statusCode {
        case 200...299:
            do {
                let uploaded = try JSONDecoder().decode(UploadedAttachment.self, from: responseData)
                guard !uploaded.id.isEmpty else { throw AttachmentUploadError.http(http.statusCode) }
                progress?(1)
                return uploaded
            } catch {
                throw AttachmentUploadError.http(http.statusCode)
            }
        case 413:
            throw AttachmentUploadError.tooLarge
        case 503 where code == "attachments_unavailable":
            throw AttachmentUploadError.unavailable
        case 400:
            let detail = (body["file"] as? [String])?.first ?? (body["file"] as? String) ?? (body["detail"] as? String)
            throw AttachmentUploadError.rejected(detail ?? "That photo couldn't be read.")
        case 401, 403, 404:
            throw AttachmentUploadError.notAllowed
        default:
            throw code == "attachments_unavailable" ? AttachmentUploadError.unavailable : AttachmentUploadError.http(http.statusCode)
        }
    }

    /// Read one attachment's bytes (a photo thumbnail) from `{attachments}{id}/` with this client's auth.
    public func fetchAttachment(id: String) async throws -> Data {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
        guard let url = attachmentsURL("\(encoded)/") else { throw AttachmentUploadError.notConfigured }
        try validateTransport()
        let generation = authenticationGeneration
        let token = try await getOrCreateSession()
        try validateAuthenticationGeneration(generation)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in authHeaders(token: token) { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        try validateAuthenticationGeneration(generation)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw APIError.unauthorized }
        if http.statusCode == 404 { throw APIError.notFound }
        guard http.statusCode == 200 else { throw APIError.httpError(statusCode: http.statusCode) }
        return data
    }

    static func multipartBody(data: Data, filename: String, contentType: String, boundary: String) -> Data {
        // Quotes and line breaks can't appear in the part header's file name.
        let safeName = filename.replacingOccurrences(of: "\"", with: "_")
            .components(separatedBy: .newlines).joined()
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName.isEmpty ? "photo.jpg" : safeName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
