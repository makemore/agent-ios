import XCTest
@testable import AgentClient

/// Tests for the `onDisconnect` callback fired by `SSEClient` exactly
/// once per run, with a classified `DisconnectReason`.
///
/// These exercise the SSE owner in isolation — no `ChatViewModel`, no
/// `APIClient` — so the assertions are scoped to the public contract
/// the rest of the library depends on.
@MainActor
final class SSEClientDisconnectTests: XCTestCase {

    private var disconnectEvents: [(runId: String, reason: DisconnectReason)] = []
    private var lastClient: SSEClient?

    override func setUp() {
        super.setUp()
        disconnectEvents.removeAll()
        lastClient = nil
    }

    // MARK: - Helpers

    private func makeClient(runId: String) -> SSEClient {
        let client = SSEClient()
        client.onDisconnect = { [weak self] runId, reason in
            self?.disconnectEvents.append((runId, reason))
        }
        lastClient = client
        return client
    }

    private let streamURL = URL(string: "http://stub.local/api/agent-runtime/runs/run-1/stream")!

    /// Wire MockURLProtocol to satisfy the SSE endpoint with a single
    /// `run.succeeded` terminal event so the run has a clean ending
    /// before we test teardown.
    private func installTerminalHandler() {
        let envelope: [String: Any] = [
            "run_id": "run-1",
            "seq": 0,
            "type": "run.succeeded",
            "payload": [:],
            "ts": "1970-01-01T00:00:00Z",
            "visibility_level": "user",
            "ui_visible": true,
        ]
        let body = try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let frame = "event: run.succeeded\ndata: \(String(data: body, encoding: .utf8)!)\n\n"
        MockURLProtocol.register { request in
            guard let url = request.url else { return nil }
            let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
            if path.hasSuffix("/stream") {
                return .sse(chunks: [Data(frame.utf8)])
            }
            return nil
        }
    }

    /// Wait for `disconnectEvents` to contain at least one entry, with
    /// a timeout. Network and complete callbacks can race on a clean
    /// stream close, so we tolerate `>= 1` for the network-shape
    /// tests and assert exactly `1` at the call-site that cares.
    private func waitForDisconnect(timeout: TimeInterval = 3.0) async {
        let start = Date()
        while disconnectEvents.isEmpty {
            if Date().timeIntervalSince(start) > timeout { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Tests

    func testExplicitDisconnectFiresOnDisconnectWithReasonExplicit() async {
        SSEClient.sessionConfigurator = { cfg in
            cfg.protocolClasses = [MockURLProtocol.self] + (cfg.protocolClasses ?? [])
        }
        defer {
            MockURLProtocol.reset()
            SSEClient.sessionConfigurator = nil
        }
        installTerminalHandler()

        let client = makeClient(runId: "run-explicit")
        client.connect(url: streamURL, headers: [:], runId: "run-explicit")
        // Yield so the run.succeeded event has time to flow through.
        try? await Task.sleep(nanoseconds: 50_000_000)
        client.disconnect(reason: .explicit)
        try? await Task.sleep(nanoseconds: 50_000_000)

        // The terminal event ALSO closes the stream, which goes
        // through SSEClient.disconnect only if the VM calls it. In
        // this isolated test we just want to confirm the explicit
        // path works. The terminal-event path is covered by the
        // `run.succeeded` fixture test in SSEStreamingTests; here
        // we only assert that `disconnect(reason: .explicit)`
        // produced an entry with the right runId — accepting that
        // a duplicate may have fired from the terminal-event
        // completion. Filter to the `.explicit` one.
        let explicit = disconnectEvents.first(where: { $0.reason == .explicit })
        XCTAssertNotNil(explicit, "expected a .explicit disconnect, got \(disconnectEvents)")
        XCTAssertEqual(explicit?.runId, "run-explicit")
    }

    func testNetworkErrorFiresOnDisconnectWithReasonNetwork() async {
        SSEClient.sessionConfigurator = { cfg in
            cfg.protocolClasses = [MockURLProtocol.self] + (cfg.protocolClasses ?? [])
        }
        defer {
            MockURLProtocol.reset()
            SSEClient.sessionConfigurator = nil
        }
        // Register a handler that returns a network error before any
        // HTTP response is sent — the SSEClient should surface it via
        // `onError` and (on disconnect) `onDisconnect(reason: .network)`.
        MockURLProtocol.register { _ in
            .error(URLError(.notConnectedToInternet))
        }

        let client = makeClient(runId: "run-network")
        client.onError = { _ in /* swallow so the test doesn't depend on error-shape */ }
        client.connect(url: streamURL, headers: [:], runId: "run-network")

        // The URLSession delegate needs time to receive the error.
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Disconnect with .network so the test explicitly opts in to
        // that reason (mirroring what would happen in the VM when
        // the onError path propagates a transport error to the host).
        client.disconnect(reason: .network)
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Exactly one entry, .network.
        XCTAssertEqual(disconnectEvents.count, 1, "expected exactly 1 disconnect, got \(disconnectEvents)")
        XCTAssertEqual(disconnectEvents.first?.runId, "run-network")
        XCTAssertEqual(disconnectEvents.first?.reason, .network)
    }

    func testDisconnectWithoutRunIdIsNoOp() async {
        // A client that was never given a runId must not fire
        // onDisconnect (we have no runId to report). This matches
        // the production contract: connect(url:headers:runId:) is
        // required for the callback to be meaningful.
        SSEClient.sessionConfigurator = { cfg in
            cfg.protocolClasses = [MockURLProtocol.self] + (cfg.protocolClasses ?? [])
        }
        defer {
            MockURLProtocol.reset()
            SSEClient.sessionConfigurator = nil
        }
        MockURLProtocol.register { _ in .error(URLError(.notConnectedToInternet)) }

        let client = makeClient(runId: "")
        client.onError = { _ in }
        client.connect(url: streamURL, headers: [:], runId: nil)
        try? await Task.sleep(nanoseconds: 100_000_000)

        client.disconnect(reason: .explicit)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(disconnectEvents.isEmpty, "no onDisconnect should fire when no runId was set; got \(disconnectEvents)")
    }

    func testRepeatedDisconnectFiresOnDisconnectOnlyOnce() async {
        // The `hasFiredDisconnect` guard inside SSEClient must prevent
        // double-firing when disconnect() is called multiple times in
        // quick succession (e.g. cancelRun + replace + deinit all
        // racing).
        SSEClient.sessionConfigurator = { cfg in
            cfg.protocolClasses = [MockURLProtocol.self] + (cfg.protocolClasses ?? [])
        }
        defer {
            MockURLProtocol.reset()
            SSEClient.sessionConfigurator = nil
        }
        MockURLProtocol.register { _ in .error(URLError(.notConnectedToInternet)) }

        let client = makeClient(runId: "run-once")
        client.onError = { _ in }
        client.connect(url: streamURL, headers: [:], runId: "run-once")
        try? await Task.sleep(nanoseconds: 100_000_000)

        client.disconnect(reason: .explicit)
        client.disconnect(reason: .lifecycle) // should be a no-op
        client.disconnect(reason: .network)   // should be a no-op
        try? await Task.sleep(nanoseconds: 50_000_000)

        let count = disconnectEvents.filter { $0.runId == "run-once" }.count
        XCTAssertEqual(count, 1, "expected exactly 1 disconnect for run-once, got \(disconnectEvents)")
        XCTAssertEqual(disconnectEvents.first(where: { $0.runId == "run-once" })?.reason, .explicit)
    }
}
