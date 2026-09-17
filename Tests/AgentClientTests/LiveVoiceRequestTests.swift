import XCTest
@testable import AgentClient

@MainActor
final class LiveVoiceRequestTests: XCTestCase {
    private let internalId = "7E2B1866-BE77-42DA-AC2B-4D159CBAF8FC"

    override func setUp() {
        super.setUp()
        APIClient.sessionConfigurator = { $0.protocolClasses = [MockURLProtocol.self] }
    }

    override func tearDown() {
        APIClient.sessionConfigurator = nil
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func client(strategy: AuthStrategy = .token) -> APIClient {
        var config = ChatWidgetConfig(backendUrl: "https://live.example.test", agentKey: "live-test")
        config.authStrategy = strategy
        config.authToken = strategy == .token ? "synthetic-live-test-owner" : nil
        return APIClient(config: config, storage: InMemoryStorage())
    }

    func testOnlySignalingJSONAndFixedInternalCloseRouteAreSent() async throws {
        let id = internalId
        MockURLProtocol.register { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.host, "live.example.test")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            if request.url?.path.hasSuffix("/close") == true || request.url?.path.hasSuffix("/close/") == true {
                return .json(status: 204, body: Data())
            }
            return .json(status: 201, body: Data("{\"id\":\"\(id)\",\"conversation_id\":\"conversation\",\"session\":{\"id\":\"live_provider\"},\"transport\":{\"type\":\"webrtc\",\"sdp\":\"answer\"}}".utf8))
        }
        let api = client()
        let result = try await api.createLiveSession(sdp: "offer", conversationId: "conversation")
        XCTAssertEqual(result.id, id)
        XCTAssertEqual(result.conversationId, "conversation")
        XCTAssertEqual(result.session.id, "live_provider")
        XCTAssertEqual(result.transport.sdp, "answer")
        try await api.closeLiveSession(id: result.id)
        let requests = MockURLProtocol.recorded
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) },
                       ["api/agent-runtime/voice/live/sessions", "api/agent-runtime/voice/live/sessions/\(id)/close"])
        let body = try XCTUnwrap(requests.first?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["sdp": "offer", "conversation_id": "conversation"])
        XCTAssertFalse(requests.contains { $0.path.contains("tts") || $0.path.contains("transcri") || $0.path.contains("audio") })
    }

    func testSessionAuthUsesConfiguredCookieStorageForCSRF() async throws {
        let cookieStorage = try XCTUnwrap(URLSessionConfiguration.ephemeral.httpCookieStorage)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "live.example.test", .path: "/",
            .name: "csrftoken", .value: "synthetic-csrf-fixture", .secure: "TRUE"]))
        cookieStorage.setCookie(cookie)
        defer { cookieStorage.deleteCookie(cookie) }
        APIClient.sessionConfigurator = {
            $0.protocolClasses = [MockURLProtocol.self]
            $0.httpCookieStorage = cookieStorage
        }
        MockURLProtocol.register { request in
            XCTAssertTrue(request.value(forHTTPHeaderField: "X-CSRFToken") == "synthetic-csrf-fixture")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://live.example.test")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return .json(status: 204, body: Data())
        }
        try await client(strategy: .session).closeLiveSession(id: internalId)
    }

    func testMalformedAnswerWithKnownInternalIdIsClosed() async {
        let id = internalId
        MockURLProtocol.register { request in
            if request.url?.path.contains("/close") == true { return .json(status: 204, body: Data()) }
            return .json(status: 201, body: Data("{\"id\":\"\(id)\"}".utf8))
        }
        do {
            _ = try await client().createLiveSession(sdp: "offer", conversationId: nil)
            XCTFail("Expected malformed answer rejection")
        } catch {}
        XCTAssertEqual(MockURLProtocol.recorded.count, 2)
        XCTAssertTrue(MockURLProtocol.recorded.last?.path.contains("/\(id)/close") == true)
    }

    func testNonUUIDCloseNeverLeavesDevice() async {
        do {
            try await client().closeLiveSession(id: "live_provider/../../elsewhere")
            XCTFail("Expected invalid ID rejection")
        } catch {}
        XCTAssertTrue(MockURLProtocol.recorded.isEmpty)
    }

    func testCreateDoesNotRetryAuthOrServerErrors() async {
        for status in [401, 403, 429, 503] {
            MockURLProtocol.reset()
            MockURLProtocol.register { _ in .json(status: status, body: Data()) }
            do {
                _ = try await client().createLiveSession(sdp: "offer", conversationId: nil)
                XCTFail("Expected HTTP failure")
            } catch {}
            XCTAssertEqual(MockURLProtocol.recorded.count, 1)
        }
    }

    func testStatusUsesUncachedOwnerScopedGetAndDecodesFinalization() async throws {
        let id = internalId
        MockURLProtocol.register { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.host, "live.example.test")
            XCTAssertEqual(request.url?.absoluteString, "https://live.example.test/api/agent-runtime/voice/live/sessions/\(id)/")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Format"), "snake")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.timeoutInterval, 10)
            return .json(status: 200, body: Data("{\"id\":\"\(id.lowercased())\",\"state\":\"closed\",\"usage_finalized\":true}".utf8))
        }
        let status = try await client().liveSessionStatus(id: id)
        XCTAssertEqual(UUID(uuidString: status.id), UUID(uuidString: id))
        XCTAssertTrue(status.usageFinalized)
        XCTAssertTrue(status.isTerminal)
        XCTAssertTrue(status.finalizationConfirmed)
        XCTAssertEqual(MockURLProtocol.recorded.count, 1)
        XCTAssertNil(MockURLProtocol.recorded.first?.body)
    }

    func testOnlyClosedAndUsageFinalizedTogetherConfirmFinalization() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for state in ["ready", "closing", "closed", "incomplete", "failed", "future-state"] {
            for finalized in [true, false] {
                let data = Data("{\"id\":\"\(internalId)\",\"state\":\"\(state)\",\"usage_finalized\":\(finalized)}".utf8)
                let status = try decoder.decode(LiveSessionStatus.self, from: data)
                XCTAssertEqual(status.isTerminal, ["closed", "incomplete", "failed"].contains(state))
                XCTAssertEqual(status.finalizationConfirmed, state == "closed" && finalized)
            }
        }
    }

    func testStatusRejectsMalformedAndForeignResponses() async {
        for body in ["{}", "{\"id\":\"\(internalId)\",\"state\":\"closed\"}",
                     "{\"id\":\"\(UUID().uuidString)\",\"state\":\"closed\",\"usage_finalized\":true}"] {
            MockURLProtocol.reset()
            MockURLProtocol.register { _ in .json(status: 200, body: Data(body.utf8)) }
            do {
                _ = try await client().liveSessionStatus(id: internalId)
                XCTFail("Expected invalid status rejection")
            } catch APIError.invalidResponse {} catch { XCTFail("Unexpected error type") }
            XCTAssertEqual(MockURLProtocol.recorded.count, 1)
        }
    }

    func testStatusRejectsProviderIdsBeforeNetworking() async {
        do {
            _ = try await client().liveSessionStatus(id: "live_provider/../../elsewhere")
            XCTFail("Expected invalid ID rejection")
        } catch APIError.invalidResponse {} catch { XCTFail("Unexpected error type") }
        XCTAssertTrue(MockURLProtocol.recorded.isEmpty)
    }

    func testStatusDoesNotRetryOrCreateSessionsOnHTTPErrors() async {
        for status in [401, 403, 404, 429, 503] {
            MockURLProtocol.reset()
            MockURLProtocol.register { _ in .json(status: status, body: Data()) }
            do {
                _ = try await client().liveSessionStatus(id: internalId)
                XCTFail("Expected HTTP failure")
            } catch APIError.unauthorized {
                XCTAssertEqual(status, 401)
            } catch APIError.httpError(let code) {
                XCTAssertEqual(code, status)
            } catch { XCTFail("Unexpected error type") }
            XCTAssertEqual(MockURLProtocol.recorded.map(\.method), ["GET"])
        }
    }

    func testCancelledStatusCheckNeverLeavesDevice() async {
        let api = client(), id = internalId
        let request = Task { try await api.liveSessionStatus(id: id) }
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error type") }
        XCTAssertTrue(MockURLProtocol.recorded.isEmpty)
    }

    func testStatusDiscardsResponseAfterAuthenticationIsCleared() async {
        let api = client(), id = internalId
        MockURLProtocol.register { _ in
            api.clearSession()
            return .json(status: 200, body: Data("{\"id\":\"\(id)\",\"state\":\"closed\",\"usage_finalized\":true}".utf8))
        }
        do {
            _ = try await api.liveSessionStatus(id: id)
            XCTFail("Must not accept a previous owner's completion")
        } catch is CancellationError {} catch { XCTFail("Unexpected error type") }
        XCTAssertEqual(MockURLProtocol.recorded.map(\.method), ["GET"])
    }

    func testCleartextProductionSignalingIsRefused() async {
        var config = ChatWidgetConfig(backendUrl: "http://live.example.test", agentKey: "live-test")
        config.authStrategy = AuthStrategy.none
        let api = APIClient(config: config, storage: InMemoryStorage())
        do {
            _ = try await api.createLiveSession(sdp: "offer", conversationId: nil)
            XCTFail("Expected insecure transport rejection")
        } catch {}
        XCTAssertTrue(MockURLProtocol.recorded.isEmpty)
    }
}