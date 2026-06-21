import Foundation

/// `URLProtocol` that intercepts every HTTP request issued by either
/// `URLSession.shared` (used by `APIClient`) or any custom session whose
/// configuration includes it in `protocolClasses` (we route `SSEClient`
/// here via `SSEClient.sessionConfigurator`).
///
/// Tests register a `Handler` that maps an incoming request to either a
/// one-shot JSON response or a sequence of SSE chunks. The chunks are
/// delivered with no real delay so tests stay deterministic; the
/// `ChatViewModel`'s own drain timer is what governs visible pacing.
final class MockURLProtocol: URLProtocol {

    enum Response {
        case json(status: Int, body: Data, headers: [String: String] = [:])
        case sse(chunks: [Data])
        case error(Error)
    }

    typealias Handler = (URLRequest) -> Response?

    /// A captured request — method, path, and decoded JSON body. Used by the
    /// parity tests to assert exactly what the client put on the wire.
    struct Recorded {
        let method: String
        let path: String
        let body: Data?
    }

    private static var handlers: [Handler] = []
    private static var recordedRequests: [Recorded] = []
    private static let lock = NSLock()

    static func register(handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers.append(handler)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handlers.removeAll()
        recordedRequests.removeAll()
    }

    /// Snapshot of every request seen since the last `reset()`, in order.
    static var recorded: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests
    }

    private static func record(_ r: Recorded) {
        lock.lock(); defer { lock.unlock() }
        recordedRequests.append(r)
    }

    /// URLProtocol nils `httpBody` and exposes the payload as a stream, so we
    /// drain `httpBodyStream` to recover the bytes the client sent.
    static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data.isEmpty ? nil : data
    }

    private static func response(for request: URLRequest) -> Response? {
        lock.lock(); defer { lock.unlock() }
        for handler in handlers.reversed() {
            if let response = handler(request) { return response }
        }
        return nil
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        MockURLProtocol.record(Recorded(
            method: request.httpMethod ?? "GET",
            path: url.path,
            body: MockURLProtocol.bodyData(of: request)
        ))
        guard let outcome = MockURLProtocol.response(for: request) else {
            // No handler matched. Fail loudly so the test author notices
            // an unexpected request rather than silently hanging.
            let err = NSError(
                domain: "MockURLProtocol",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No handler for \(request.httpMethod ?? "?") \(url.absoluteString)"]
            )
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        switch outcome {
        case .json(let status, let body, let extra):
            var headers = ["Content-Type": "application/json"]
            for (k, v) in extra { headers[k] = v }
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .sse(let chunks):
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        case .error(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
