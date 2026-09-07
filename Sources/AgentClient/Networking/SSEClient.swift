import Foundation

/// Strip `anonymous_token` / `token` query params from a URL so the
/// value never lands in logs. Keeps the rest of the URL intact for
/// production diagnostics. Internal helper, not part of the public API.
internal func redactURLForLogging(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return url.absoluteString
    }
    if let items = components.queryItems {
        components.queryItems = items.map { item in
            if item.name == "anonymous_token" || item.name == "token" {
                return URLQueryItem(name: item.name, value: "<redacted>")
            }
            return item
        }
    }
    return components.url?.absoluteString ?? url.absoluteString
}

/// Reason the SSE stream was torn down. Mirrors the
/// `DisconnectReason` enum in the Android `ChatWidgetConfig` and the
/// `DisconnectReason` union exported by `@makemore/agent-client` on
/// web. Hosts can use this to distinguish a clean user-driven cancel
/// from a network failure or a lifecycle teardown (e.g. SwiftUI view
/// disappearance, VM deinit).
public enum DisconnectReason: String, Sendable {
    /// `cancelRun()` or an explicit client-side close.
    case explicit
    /// Underlying socket / read error reported by `URLSession`.
    case network
    /// View disappeared, VM deinit, OS backgrounding — the run
    /// continues server-side; the client is just no longer watching.
    case lifecycle
    /// Unhandled / unknown teardown.
    case error
}

public enum SSEFailure: Error, LocalizedError, Equatable {
    case httpStatus(Int), invalidContentType, invalidResponse, invalidUTF8
    case frameTooLarge, malformedEvent, unexpectedEOF
    case connectionTimeout, idleTimeout, overallTimeout, network(Int)

    public var isRetryable: Bool {
        switch self {
        case .unexpectedEOF, .connectionTimeout, .idleTimeout, .overallTimeout, .network: return true
        case .httpStatus(let status): return status == 408 || status == 429 || status >= 500
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let status): return "Stream request rejected (HTTP \(status))."
        case .invalidContentType, .invalidResponse: return "The server did not return an event stream."
        case .invalidUTF8, .frameTooLarge, .malformedEvent: return "The server returned an invalid stream."
        case .unexpectedEOF: return "The stream ended before the run finished."
        case .connectionTimeout, .idleTimeout, .overallTimeout: return "The stream timed out. Checking the saved run."
        case .network: return "The stream connection was interrupted."
        }
    }
}

/// Incremental byte parser: decode only complete lines, never individual packets.
/// Limits cover both unfinished lines and accumulated multiline event data.
struct SSEParser {
    let maxLineBytes: Int
    let maxFrameBytes: Int
    private var line = Data()
    private var dataLines: [String] = []
    private var type = "message"
    private var id: String?
    private var frameBytes = 0
    private var afterCR = false
    private var firstLine = true

    init(maxLineBytes: Int = 256 * 1024, maxFrameBytes: Int = 1024 * 1024) {
        self.maxLineBytes = maxLineBytes
        self.maxFrameBytes = maxFrameBytes
    }

    mutating func append(_ bytes: Data) throws -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in bytes {
            if afterCR {
                afterCR = false
                if byte == 10 { continue }
            }
            if byte == 10 || byte == 13 {
                if let event = try finishLine() { events.append(event) }
                afterCR = byte == 13
            } else {
                guard line.count < maxLineBytes, frameBytes + line.count < maxFrameBytes else {
                    throw SSEFailure.frameTooLarge
                }
                line.append(byte)
            }
        }
        return events
    }

    private mutating func finishLine() throws -> SSEEvent? {
        guard var text = String(data: line, encoding: .utf8) else { throw SSEFailure.invalidUTF8 }
        frameBytes += line.count + 1
        line.removeAll(keepingCapacity: true)
        guard frameBytes <= maxFrameBytes else { throw SSEFailure.frameTooLarge }
        if firstLine {
            firstLine = false
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        }
        if text.isEmpty {
            let event = dataLines.isEmpty ? nil : SSEEvent(type: type, data: dataLines.joined(separator: "\n"), id: id)
            dataLines.removeAll(keepingCapacity: true)
            type = "message"
            frameBytes = 0
            return event
        }
        if text.hasPrefix(":") { return nil }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "data": dataLines.append(value)
        case "event": type = value.isEmpty ? "message" : value
        case "id": if !value.contains("\0") { id = value }
        default: break
        }
        return nil
    }
}

/// All connection state and callbacks are serialized on the main queue. Each
/// delegate is fenced by connection identity, including already queued callbacks.
public final class SSEClient {
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var connection: UUID?
    private var lastRunId: String?
    private var parser = SSEParser()
    private var watchdog: Timer?
    private var started = Date()
    private var lastActivity = Date()
    private var receivedResponse = false
    public struct Timeouts {
        public var connection: TimeInterval = 30
        // The worker has a 900s budget. Allow cleanup headroom, even if a
        // deployment temporarily fails to emit heartbeat bytes during work.
        public var idle: TimeInterval = 960
        public var overall: TimeInterval = 1080
        public init() {}
    }
    private let timeouts: Timeouts
    // Hosts may install callbacks off-main before connecting. Synchronize
    // access independently of the main-queue connection/reducer state.
    private let callbackLock = NSLock()
    private var eventCallback: ((SSEEvent) -> Void)?
    private var errorCallback: ((Error) -> Void)?
    private var completeCallback: (() -> Void)?
    private var disconnectCallback: ((String, DisconnectReason) -> Void)?
    private func withCallbackLock<T>(_ operation: () -> T) -> T {
        callbackLock.lock(); defer { callbackLock.unlock() }
        return operation()
    }
    public var onEvent: ((SSEEvent) -> Void)? {
        get { withCallbackLock { eventCallback } }
        set { withCallbackLock { eventCallback = newValue } }
    }
    public var onError: ((Error) -> Void)? {
        get { withCallbackLock { errorCallback } }
        set { withCallbackLock { errorCallback = newValue } }
    }
    /// Deliberate close only. Socket EOF is always `unexpectedEOF`.
    public var onComplete: (() -> Void)? {
        get { withCallbackLock { completeCallback } }
        set { withCallbackLock { completeCallback = newValue } }
    }
    public var onDisconnect: ((String, DisconnectReason) -> Void)? {
        get { withCallbackLock { disconnectCallback } }
        set { withCallbackLock { disconnectCallback = newValue } }
    }
    public static var sessionConfigurator: ((URLSessionConfiguration) -> Void)?
    public init(timeouts: Timeouts = Timeouts()) { self.timeouts = timeouts }

    public func connect(url: URL, headers: [String: String] = [:], runId: String? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.connect(url: url, headers: headers, runId: runId) }
            return
        }
        close(reason: .explicit, notifyComplete: false)
        // A host disconnect callback can synchronously connect a replacement.
        // Never overwrite its retained session without closing it.
        guard connection == nil else { return }
        let identity = UUID()
        connection = identity
        lastRunId = runId
        parser = SSEParser()
        started = Date()
        lastActivity = started
        receivedResponse = false
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let delegate = SSEStreamDelegate()
        delegate.onResponse = { [weak self] response in
            guard let self, self.connection == identity else { return false }
            if let failure = Self.validate(response) { self.fail(failure); return false }
            self.receivedResponse = true
            self.lastActivity = Date()
            return true
        }
        delegate.onData = { [weak self] data in
            guard let self, self.connection == identity else { return }
            self.lastActivity = Date()
            do {
                for event in try self.parser.append(data) {
                    guard self.connection == identity else { break }
                    self.onEvent?(event)
                }
            } catch { self.fail(error as? SSEFailure ?? .malformedEvent) }
        }
        delegate.onEnd = { [weak self] error in
            guard let self, self.connection == identity else { return }
            self.fail(error.map { .network(($0 as NSError).code) } ?? .unexpectedEOF)
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeouts.idle
        cfg.timeoutIntervalForResource = timeouts.overall
        Self.sessionConfigurator?(cfg)
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: .main)
        self.session = session
        task = session.dataTask(with: request)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.connection == identity else { return }
            let now = Date()
            if now.timeIntervalSince(self.started) >= self.timeouts.overall {
                self.fail(.overallTimeout)
            } else if !self.receivedResponse && now.timeIntervalSince(self.started) >= self.timeouts.connection {
                self.fail(.connectionTimeout)
            } else if now.timeIntervalSince(self.lastActivity) >= self.timeouts.idle {
                self.fail(.idleTimeout)
            }
        }
        watchdog = timer
        RunLoop.main.add(timer, forMode: .common)
        task?.resume()
    }

    static func validate(_ response: URLResponse) -> SSEFailure? {
        guard let http = response as? HTTPURLResponse else { return .invalidResponse }
        guard http.statusCode == 200 else { return .httpStatus(http.statusCode) }
        let mime = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return mime == "text/event-stream" ? nil : .invalidContentType
    }

    public func disconnect(reason: DisconnectReason = .explicit) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [self] in disconnect(reason: reason) }
            return
        }
        close(reason: reason, notifyComplete: true)
    }

    private func fail(_ failure: SSEFailure) {
        let callback = onError
        close(reason: .network, notifyComplete: false)
        if connection == nil { callback?(failure) }
    }

    private func close(reason: DisconnectReason, notifyComplete: Bool) {
        guard connection != nil else { return }
        connection = nil
        let runId = lastRunId
        lastRunId = nil
        watchdog?.invalidate()
        watchdog = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        parser = SSEParser()
        AgentLog.debug(.sse, "[SSE] closed duration_ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        if let runId { onDisconnect?(runId, reason) }
        if notifyComplete, connection == nil { onComplete?() }
    }

    deinit { watchdog?.invalidate(); session?.invalidateAndCancel() }
}

/// SSE Event
public struct SSEEvent {
    public let type: String
    public let data: String
    public let id: String?
    
    /// Parse the data as JSON
    public func json() -> [String: Any]? {
        guard let data = data.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Stream delegate for handling SSE data
private class SSEStreamDelegate: NSObject, URLSessionDataDelegate {
    var onResponse: ((URLResponse) -> Bool)?
    var onData: ((Data) -> Void)?
    var onEnd: ((Error?) -> Void)?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(onResponse?(response) == true ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        onData?(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onEnd?(error)
    }
}

