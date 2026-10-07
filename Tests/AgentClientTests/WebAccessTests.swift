import XCTest
@testable import AgentClient

/// Web access (agent_runtime_core.web_access): the agent's setting decides whether the
/// "Web" switch appears; the switch sends `params["web_search"] = false` when turned off.
@MainActor
final class WebAccessTests: XCTestCase {
    override func setUp() {
        super.setUp()
        APIClient.sessionConfigurator = { $0.protocolClasses = [MockURLProtocol.self] }
    }

    override func tearDown() {
        MockURLProtocol.reset()
        APIClient.sessionConfigurator = nil
        super.tearDown()
    }

    private func model(agentKey: String = "helper") -> ChatViewModel {
        var config = ChatWidgetConfig(backendUrl: "https://example.test", agentKey: agentKey)
        config.authStrategy = .token
        config.authToken = "synthetic-web-access"
        let storage = InMemoryStorage()
        return ChatViewModel(config: config, apiClient: APIClient(config: config, storage: storage), storage: storage)
    }

    func testFeaturesEndpointDecidesWhetherTheSwitchAppears() async {
        let vm = model()
        MockURLProtocol.register { request in
            let url = request.url!
            XCTAssertTrue(url.absoluteString.contains("/runs/features/?agent_key="), url.absoluteString)
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "agent_key", value: "helper")])
            XCTAssertEqual(request.httpMethod, "GET")
            return .json(status: 200, body: Data(#"{"agent_key":"helper","web_access":true}"#.utf8))
        }
        XCTAssertFalse(vm.webAccessAvailable)
        await vm.loadAgentFeatures()
        XCTAssertTrue(vm.webAccessAvailable)
    }

    func testAgentsWithoutWebAccessOrOlderHostsKeepTheSwitchHidden() async {
        let vm = model()
        MockURLProtocol.register { _ in .json(status: 200, body: Data(#"{"agent_key":"helper","web_access":false}"#.utf8)) }
        await vm.loadAgentFeatures()
        XCTAssertFalse(vm.webAccessAvailable)

        MockURLProtocol.reset()
        MockURLProtocol.register { _ in .json(status: 404, body: Data()) }
        await vm.loadAgentFeatures()
        XCTAssertFalse(vm.webAccessAvailable)
    }

    func testTurningTheSwitchOffSendsWebSearchFalseOnly() {
        let vm = model()
        XCTAssertNil(vm.runParamsSnapshot()["web_search"])
        vm.webSearchEnabled = false
        XCTAssertEqual(vm.runParamsSnapshot()["web_search"] as? Bool, false)
        vm.webSearchEnabled = true
        XCTAssertNil(vm.runParamsSnapshot()["web_search"])
    }

    func testFeaturesDecodeFromTheRuntimeShape() throws {
        let features = try JSONDecoder().decode(AgentFeatures.self, from: Data(#"{"agent_key":"a","web_access":true}"#.utf8))
        XCTAssertEqual(features, AgentFeatures(agentKey: "a", webAccess: true))
    }
}
