import Foundation

/// Server-Sent Events client for streaming responses
public class SSEClient {
    private var task: URLSessionDataTask?
    private var buffer = ""
    /// Set by `disconnect()` so the URLSession completion callback can tell
    /// "we asked for this" (NSURLErrorCancelled is expected, surface as
    /// `onComplete`) from a genuine network failure (surface as `onError`).
    /// Without this, calling `disconnect()` after a terminal SSE event
    /// produces a "cancelled" banner flash before the next run starts.
    private var expectingDisconnect = false

    public var onEvent: ((SSEEvent) -> Void)?
    public var onError: ((Error) -> Void)?
    public var onComplete: (() -> Void)?

    /// Hook for tests to inject a `URLProtocol` (or otherwise mutate the
    /// session configuration) into every `URLSession` this client builds
    /// internally. No-op by default in production.
    public static var sessionConfigurator: ((URLSessionConfiguration) -> Void)?

    public init() {}

    /// Connect to an SSE endpoint
    public func connect(url: URL, headers: [String: String] = [:]) {
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Reset on every connect — a previous run may have set the flag
        // during teardown.
        expectingDisconnect = false

        let delegate = SSEStreamDelegate { [weak self] data in
            if let text = String(data: data, encoding: .utf8) {
                self?.processData(text)
            }
        } onComplete: { [weak self] in
            DispatchQueue.main.async {
                self?.onComplete?()
            }
        } onError: { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Deliberate teardown after a terminal event (`disconnect()`
                // sets `expectingDisconnect`) — URLSession reports this as
                // NSURLErrorCancelled. Surface as a clean completion so the
                // awaiter wakes but no error banner appears.
                if self.expectingDisconnect ||
                   (error as? URLError)?.code == .cancelled {
                    self.onComplete?()
                    return
                }
                self.onError?(error)
            }
        }

        let streamConfig = URLSessionConfiguration.default
        streamConfig.timeoutIntervalForRequest = 300 // 5 minutes
        streamConfig.timeoutIntervalForResource = 300
        Self.sessionConfigurator?(streamConfig)
        let streamSession = URLSession(configuration: streamConfig, delegate: delegate, delegateQueue: nil)
        task = streamSession.dataTask(with: request)
        task?.resume()
    }

    /// Disconnect from the SSE endpoint
    public func disconnect() {
        expectingDisconnect = true
        task?.cancel()
        task = nil
        buffer = ""
    }
    
    private func processData(_ text: String) {
        buffer += text
        
        // Process complete events (separated by double newlines)
        let events = buffer.components(separatedBy: "\n\n")
        
        // Keep the last incomplete event in the buffer
        if !buffer.hasSuffix("\n\n") {
            buffer = events.last ?? ""
        } else {
            buffer = ""
        }
        
        // Process all complete events
        for eventText in events.dropLast(buffer.isEmpty ? 0 : 1) {
            if let event = parseEvent(eventText) {
                DispatchQueue.main.async { [weak self] in
                    self?.onEvent?(event)
                }
            }
        }
    }
    
    private func parseEvent(_ text: String) -> SSEEvent? {
        var eventType: String?
        var data: String?
        var id: String?
        
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("event:") {
                eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let dataLine = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if data == nil {
                    data = dataLine
                } else {
                    data! += "\n" + dataLine
                }
            } else if line.hasPrefix("id:") {
                id = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
        }
        
        guard let eventData = data else { return nil }
        
        let ev = SSEEvent(
            type: eventType ?? "message",
            data: eventData,
            id: id
        )
        #if DEBUG
        print("[AgentFrontend][SSE] event type=\(ev.type) bytes=\(eventData.count)")
        #endif
        return ev
    }
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
    let onData: (Data) -> Void
    let onComplete: () -> Void
    let onError: (Error) -> Void
    
    init(onData: @escaping (Data) -> Void, onComplete: @escaping () -> Void, onError: @escaping (Error) -> Void) {
        self.onData = onData
        self.onComplete = onComplete
        self.onError = onError
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        onData(data)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            onError(error)
        } else {
            onComplete()
        }
    }
}

