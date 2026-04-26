import Foundation
import AgentFrontend

/// Resolves runtime configuration from `ProcessInfo.processInfo.environment`.
/// XCUITest sets these via `XCUIApplication.launchEnvironment`. Defaults are
/// chosen so the app is also runnable by hand against the local stub server.
struct HostConfiguration: Hashable {
    /// One scripted user turn, fired by the host after the previous run
    /// finishes streaming.
    struct FollowUp: Hashable {
        let prompt: String
        let delayMs: Int
    }

    let backendUrl: String
    let agentKey: String
    let testFixture: String
    let autoSendOnLaunch: Bool
    let autoSendPrompt: String
    /// Scripted follow-up user prompts sent in order after the initial
    /// auto-send completes. Each one waits `delayMs` after the previous
    /// run stops streaming, then drives `sendMessage` like a real user.
    let autoSendFollowUps: [FollowUp]
    /// When non-nil, the chat widget is configured for token auth against
    /// a real Django backend instead of anonymous-session against the stub.
    let authToken: String?

    /// True when the launch environment looks like it came from XCUITest
    /// (or a hand-rolled `xcodebuild ... env` invocation). Used by the
    /// host app to skip the in-app `ScenarioLauncherView` and route
    /// straight to the chat. The launcher sets none of these vars when
    /// it builds its own `HostConfiguration`, so manual launches always
    /// land on the launcher.
    static func isLaunchedByTestRunner(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let driverKeys = [
            "STUB_SERVER_URL", "BACKEND_URL", "TEST_FIXTURE",
            "AUTO_SEND_PROMPT", "AUTO_SEND_FOLLOW_UPS", "AGENT_TOKEN",
        ]
        return driverKeys.contains { (env[$0] ?? "").isEmpty == false }
    }

    static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> HostConfiguration {
        // STUB_SERVER_URL is set explicitly by the stub-driven UI tests via
        // `app.launchEnvironment` and always wins, so the scheme-level
        // BACKEND_URL/AGENT_TOKEN baked in for the real-backend test cannot
        // leak into stub runs (XCUIApplication merges launchEnvironment with
        // the runner's environment, which includes scheme variables).
        let stub = env["STUB_SERVER_URL"].flatMap { $0.isEmpty ? nil : $0 }
        let backend = env["BACKEND_URL"].flatMap { $0.isEmpty ? nil : $0 }
        let url = stub ?? backend ?? "http://127.0.0.1:8765"
        // Token only counts as a real-backend signal when no stub override is
        // active; otherwise we'd sign requests against the stub uselessly.
        let token: String? = (stub == nil)
            ? env["AGENT_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
            : nil
        return HostConfiguration(
            backendUrl: url,
            agentKey: env["AGENT_KEY"] ?? "test-agent",
            testFixture: env["TEST_FIXTURE"] ?? "simple_streaming",
            autoSendOnLaunch: (env["AUTO_SEND"] ?? "true").lowercased() != "false",
            autoSendPrompt: env["AUTO_SEND_PROMPT"] ?? "Hello agent",
            autoSendFollowUps: parseFollowUps(env["AUTO_SEND_FOLLOW_UPS"]),
            authToken: token
        )
    }

    /// Decode the `AUTO_SEND_FOLLOW_UPS` env var, which is a JSON array of
    /// `{"prompt": String, "delay_ms": Int}` objects. Anything malformed is
    /// silently dropped — the env var is optional and demo-only.
    private static func parseFollowUps(_ raw: String?) -> [FollowUp] {
        guard let raw = raw, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { dict in
            guard let prompt = dict["prompt"] as? String, !prompt.isEmpty else { return nil }
            let delay = (dict["delay_ms"] as? Int) ?? 0
            return FollowUp(prompt: prompt, delayMs: delay)
        }
    }

    /// Build a `ChatWidgetConfig`. When `authToken` is set we configure
    /// DRF token auth (`Authorization: Token <key>`) and skip anonymous
    /// session bootstrapping. Otherwise the widget falls back to anonymous
    /// auth against the stub server, which uses `metadata.test_fixture` to
    /// pick the canned event stream.
    func makeWidgetConfig() -> ChatWidgetConfig {
        var cfg = ChatWidgetConfig(backendUrl: backendUrl, agentKey: agentKey)
        cfg.title = "Agent Example"
        cfg.subtitle = "Streaming UI test host"
        cfg.showSystemPicker = false
        cfg.showTasksTab = false
        cfg.showTTSButton = false
        cfg.enableTTS = false
        cfg.enableVoice = false
        cfg.enableFiles = false
        cfg.followStreamingEnabled = true
        if let token = authToken {
            cfg.authStrategy = .token
            cfg.authToken = token
            cfg.metadata = [:]
        } else {
            cfg.metadata = ["test_fixture": testFixture]
        }
        return cfg
    }
}
