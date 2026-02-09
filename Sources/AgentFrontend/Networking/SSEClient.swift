import Foundation

/// Server-Sent Events client for streaming responses
public class SSEClient {
    private var task: URLSessionDataTask?
    private var buffer = ""
    
    public var onEvent: ((SSEEvent) -> Void)?
    public var onError: ((Error) -> Void)?
    public var onComplete: (() -> Void)?
    
    private let session: URLSession
    
    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300 // 5 minutes
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }
    
    /// Connect to an SSE endpoint
    public func connect(url: URL, headers: [String: String] = [:]) {
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        task = session.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.onError?(error)
                }
                return
            }
            
            guard let data = data, let text = String(data: data, encoding: .utf8) else {
                return
            }
            
            self?.processData(text)
        }
        
        // Use streaming delegate for real-time updates
        let streamTask = session.dataTask(with: request)
        
        // Create a custom delegate to handle streaming
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
                self?.onError?(error)
            }
        }
        
        let streamSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        task = streamSession.dataTask(with: request)
        task?.resume()
    }
    
    /// Disconnect from the SSE endpoint
    public func disconnect() {
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
        
        return SSEEvent(
            type: eventType ?? "message",
            data: eventData,
            id: id
        )
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

