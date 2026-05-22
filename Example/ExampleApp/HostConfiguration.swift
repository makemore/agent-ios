import Foundation
import SwiftUI
import AgentClient
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
    /// Turn TTS playback on by default (mirrors `ChatWidgetConfig.enableTTS`).
    /// The speaker icon in the chat header still lets the user toggle it.
    let enableTTS: Bool
    /// Show the mic button in the input row and route SFSpeech results
    /// into the text field (mirrors `ChatWidgetConfig.enableVoice`).
    let enableVoice: Bool
    /// Drives the warm-dark shell: rounded composer card, greeting
    /// empty state, slide-in sidebar. When `false` the scenario uses
    /// the legacy classic composer + plain empty state so we can A/B
    /// old vs new.
    let anthropicShell: Bool
    /// Optional first name woven into the greeting (e.g. "Chris" →
    /// "Good afternoon, Chris"). Defaults to the `USER_NAME` env var,
    /// then falls back to nothing.
    let userName: String?

    /// True when the launch environment looks like it came from XCUITest.
    /// We key off `AUTO_SEND_PROMPT` specifically: that's only ever set by
    /// the test runner, never by an Xcode scheme used for manual runs.
    /// `BACKEND_URL` etc. are intentionally not triggers so a scheme can
    /// pre-load the launcher with the right URL without skipping it.
    static func isLaunchedByTestRunner(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        return (env["AUTO_SEND_PROMPT"] ?? "").isEmpty == false
    }

    /// Default DRF token baked into the launcher so a fresh sim run can
    /// hit the local Django backend without copy-paste. Override at any
    /// time by editing the field in the launcher (the new value is
    /// persisted in `@AppStorage`).
    static let defaultAuthToken = "72be8261e1cf35dd3d7ae39c8f9b5268095113ab"

    /// URL the launcher's stub-fixture scenarios point at. Reads
    /// `STUB_SERVER_URL` from the active Xcode scheme, falling back to
    /// the local Python stub server's default port.
    static var stubServerUrl: String {
        let raw = ProcessInfo.processInfo.environment["STUB_SERVER_URL"] ?? ""
        return raw.isEmpty ? "http://127.0.0.1:8765" : raw
    }

    /// URL the launcher's real-backend scenarios point at. Reads
    /// `BACKEND_URL` from the active Xcode scheme so switching scheme
    /// (e.g. "Local (ngrok)" vs "Local (runserver)") swaps the host.
    static var defaultBackendUrl: String {
        let raw = ProcessInfo.processInfo.environment["BACKEND_URL"] ?? ""
        return raw.isEmpty ? "http://127.0.0.1:8000" : raw
    }

    /// Agent key the launcher uses when building real-backend scenarios.
    /// Set `AGENT_KEY` on the Xcode scheme to point at a different agent.
    static var defaultAgentKey: String {
        let raw = ProcessInfo.processInfo.environment["AGENT_KEY"] ?? ""
        return raw.isEmpty ? "chisel" : raw
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
            authToken: token,
            enableTTS: (env["ENABLE_TTS"] ?? "false").lowercased() == "true",
            enableVoice: (env["ENABLE_VOICE"] ?? "false").lowercased() == "true",
            anthropicShell: (env["ANTHROPIC_SHELL"] ?? "false").lowercased() == "true",
            userName: (env["USER_NAME"]).flatMap { $0.isEmpty ? nil : $0 }
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
        // Show the speaker toggle whenever TTS is enabled for this host so
        // the developer can flick playback off mid-stream from the header.
        cfg.showTTSButton = enableTTS
        cfg.enableTTS = enableTTS
        cfg.enableVoice = enableVoice
        cfg.enableFiles = true
        cfg.followStreamingEnabled = true
        if anthropicShell {
            // Library default already enables the warm-dark appearance,
            // greeting, and sidebar — just personalise so the demo
            // picks up the user's name and shows the S'Ai placeholder.
            cfg.appearance.composerStyle = .anthropic
            cfg.appearance.modelPillLabel = "S'Ai"
            cfg.greeting.enabled = true
            cfg.greeting.userName = userName
            cfg.sidebar.enabled = true
            cfg.sidebar.footerInitials = userName?.prefix(1).uppercased()
            cfg.sidebar.footerCaption = userName
            cfg.placeholder = "Chat with S'Ai"
        } else {
            // Opt out of the new baseline so the legacy scenarios keep
            // their original look while we iterate on the redesign.
            cfg.appearance = .classic
            cfg.greeting.enabled = false
            cfg.sidebar.enabled = false
            cfg.placeholder = "Type your message..."
            cfg.primaryColor = Color(hex: "#4a6b8e")
        }
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
