import XCTest
@testable import AgentClient

/// Layer B — cross-platform parity. Drives the shared
/// `clients/test-fixtures/ephemeral/contract.json` scenarios through a real
/// `ChatViewModel` + `APIClient` + `SSEClient` and asserts exactly what the
/// client puts on the wire in ephemeral mode. The Android
/// `EphemeralContractParityTest` asserts the same contract — that shared
/// oracle is what keeps the two platforms consistent.
///
/// See agent/docs/ephemeral-security-validation-plan.md (Layer B).
@MainActor
final class EphemeralContractParityTests: XCTestCase {

    private var storage: InMemoryStorage!

    override func setUp() {
        super.setUp()
        let injectMock: (URLSessionConfiguration) -> Void = { cfg in
            cfg.protocolClasses = [MockURLProtocol.self] + (cfg.protocolClasses ?? [])
        }
        SSEClient.sessionConfigurator = injectMock
        APIClient.sessionConfigurator = injectMock
        storage = InMemoryStorage()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        SSEClient.sessionConfigurator = nil
        APIClient.sessionConfigurator = nil
        super.tearDown()
    }

    func testEphemeralWireContract() async throws {
        let contract = try EphemeralContract.load()
        for scenario in contract.scenarios {
            try await run(scenario)
        }
    }

    private func run(_ scenario: EphemeralContract.Scenario) async throws {
        MockURLProtocol.reset()
        let fixture = try SSEFixture.load(scenario.fixture)
        installHandlers(for: fixture)

        // Unique agent key isolates the shared on-device SQLite store.
        var config = ChatWidgetConfig(
            backendUrl: "http://stub.local",
            agentKey: "\(scenario.agentKey)-\(UUID().uuidString)"
        )
        config.ephemeral = true
        config.privateOnly = scenario.privateOnly ?? false
        let apiClient = APIClient(config: config, storage: storage)
        let vm = ChatViewModel(config: config, apiClient: apiClient, storage: storage)
        defer { vm.purgeLocalHistory() }

        for turn in scenario.turns {
            await vm.sendMessage(turn)
            try await waitForStreamSettled(vm: vm)
        }

        // Pull the create-run bodies in order.
        let creates = MockURLProtocol.recorded.filter {
            $0.method == "POST" && $0.path.hasSuffix("/runs")
        }
        XCTAssertEqual(creates.count, scenario.turns.count,
                       "[\(scenario.name)] expected one create per turn")

        for (i, recorded) in creates.enumerated() {
            let body = try XCTUnwrap(recorded.body, "[\(scenario.name)] turn \(i) had no body")
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )

            // (a) ephemeral flag present on every turn.
            if scenario.expect.everyRequestEphemeralTrue {
                XCTAssertEqual(json["ephemeral"] as? Bool, true,
                               "[\(scenario.name)] turn \(i) missing ephemeral:true")
            }

            // (b) full history re-sent — exact roles + contents.
            let msgs = try XCTUnwrap(json["messages"] as? [[String: Any]])
            let expected = scenario.expect.expectedMessagesPerTurn[i]
            XCTAssertEqual(msgs.count, scenario.expect.messageCountPerTurn[i],
                           "[\(scenario.name)] turn \(i) wrong message count")
            XCTAssertEqual(msgs.count, expected.count)
            for (j, exp) in expected.enumerated() where j < msgs.count {
                XCTAssertEqual(msgs[j]["role"] as? String, exp.role,
                               "[\(scenario.name)] turn \(i) msg \(j) role")
                XCTAssertEqual(msgs[j]["content"] as? String, exp.content,
                               "[\(scenario.name)] turn \(i) msg \(j) content")
            }

            // (c) conversationId: absent on turn 1, reused thereafter.
            let sentConvId = json["conversationId"] as? String
            XCTAssertEqual(sentConvId, scenario.expect.conversationIdSentPerTurn[i],
                           "[\(scenario.name)] turn \(i) conversationId mismatch")

            // (e) private_only egress flag forwarded exactly as configured.
            XCTAssertEqual(json["private_only"] as? Bool ?? false,
                           scenario.privateOnly ?? false,
                           "[\(scenario.name)] turn \(i) private_only mismatch")
        }

        // (d) the client never fetched history from the server.
        let needle = scenario.expect.forbiddenPathSubstring
        XCTAssertFalse(MockURLProtocol.recorded.contains { $0.path.contains(needle) },
                       "[\(scenario.name)] client hit a forbidden history path (\(needle))")
    }

    // MARK: - Handlers (mirror EphemeralPersistenceTests)

    private func installHandlers(for fixture: SSEFixture) {
        let runResponse: [String: Any] = [
            "id": fixture.runId,
            "conversationId": fixture.conversationId,
            "status": "running",
        ]
        let runJSON = try! JSONSerialization.data(withJSONObject: runResponse)
        let chunks = fixture.sseChunks()

        MockURLProtocol.register { request in
            guard let url = request.url else { return nil }
            let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
            let method = request.httpMethod ?? "GET"
            switch (method, path) {
            case ("POST", "/api/accounts/anonymous-session"):
                return .json(status: 200, body: Data(#"{"token":"stub-anon-token"}"#.utf8))
            case ("POST", "/api/agent-runtime/runs"):
                return .json(status: 200, body: runJSON)
            case (_, _) where path.hasSuffix("/stream"):
                return .sse(chunks: chunks)
            default:
                return nil
            }
        }
    }

    private func waitForStreamSettled(vm: ChatViewModel, timeout: TimeInterval = 8.0) async throws {
        let start = Date()
        while vm.isLoading {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("waitForStreamSettled timed out after \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
    }
}

// MARK: - Contract model + loader

struct EphemeralContract: Decodable {
    struct Msg: Decodable, Equatable {
        let role: String
        let content: String
    }
    struct Expect: Decodable {
        let everyRequestEphemeralTrue: Bool
        let messageCountPerTurn: [Int]
        let expectedMessagesPerTurn: [[Msg]]
        let conversationIdSentPerTurn: [String?]
        let forbiddenPathSubstring: String
    }
    struct Scenario: Decodable {
        let name: String
        let agentKey: String
        let fixture: String
        let assistantReply: String
        let serverConversationId: String
        let privateOnly: Bool?
        let turns: [String]
        let expect: Expect
    }
    let scenarios: [Scenario]

    static func load(file: StaticString = #filePath) throws -> EphemeralContract {
        var url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            for candidate in [
                url.appendingPathComponent("clients/test-fixtures/ephemeral/contract.json"),
                url.appendingPathComponent("test-fixtures/ephemeral/contract.json"),
            ] where FileManager.default.fileExists(atPath: candidate.path) {
                let data = try Data(contentsOf: candidate)
                return try JSONDecoder().decode(EphemeralContract.self, from: data)
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "EphemeralContract", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate test-fixtures/ephemeral/contract.json from \(file)",
        ])
    }
}
