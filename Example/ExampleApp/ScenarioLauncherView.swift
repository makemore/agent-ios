import SwiftUI

/// Manual test launcher shown when the host app is started without the
/// XCUITest driver env vars (see `HostConfiguration.isLaunchedByTestRunner`).
/// Lets a developer pick any of the canned streaming scenarios — stub-fixture
/// or real Django backend — and drive the production `ChatWidgetView` from a
/// button tap, mirroring exactly what XCUITest does headlessly.
struct ScenarioLauncherView: View {
    /// Only mutable input — DRF token used to authenticate against the real
    /// Django backend. Defaults to a known-good token so a fresh sim run
    /// works out of the box; persisted in `@AppStorage` once edited.
    @AppStorage("launcher.authToken") private var authToken = HostConfiguration.defaultAuthToken

    /// URLs and agent key are now driven by the active Xcode scheme via
    /// env vars (BACKEND_URL, STUB_SERVER_URL, AGENT_KEY). Switch scheme
    /// in the Xcode toolbar to swap targets — no in-app editing needed.
    private var backendUrl: String { HostConfiguration.defaultBackendUrl }
    private var stubUrl: String { HostConfiguration.stubServerUrl }
    private var agentKey: String { HostConfiguration.defaultAgentKey }

    var body: some View {
        NavigationStack {
            List {
                Section("Active scheme") {
                    LabeledValue(label: "Backend URL", value: backendUrl)
                    LabeledValue(label: "Stub URL", value: stubUrl)
                    LabeledValue(label: "Agent key", value: agentKey)
                    Text("Switch the Xcode scheme (toolbar, top-left) to change these.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Auth") {
                    LabeledTextField(label: "DRF token", text: $authToken, isSecret: true)
                }

                Section {
                    ForEach(Self.anthropicShellScenarios) { scenario in
                        scenarioLink(scenario)
                    }
                } header: {
                    Text("S'Ai shell (warm-dark baseline)")
                } footer: {
                    Text("Greeting, rounded composer card, slide-in sidebar on a warm-dark background.")
                        .font(.footnote)
                }

                Section("Stub fixtures (start `clients/test-stub-server`)") {
                    ForEach(Self.stubScenarios) { scenario in
                        scenarioLink(scenario)
                    }
                }

                Section("Real backend (Django)") {
                    if authToken.isEmpty {
                        Text("Set DRF token above to enable.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Self.realBackendScenarios) { scenario in
                            scenarioLink(scenario)
                        }
                    }
                }

                Section {
                    NavigationLink(value: makeManualHost()) {
                        Label("Open empty chat (stub, no auto-send)",
                              systemImage: "bubble.left.and.bubble.right")
                    }
                } footer: {
                    Text("Same chat widget XCUITest drives, but you type the prompts.")
                        .font(.footnote)
                }
            }
            .navigationTitle("AgentFrontend")
            .navigationDestination(for: HostConfiguration.self) { host in
                RootView(host: host)
            }
        }
    }

    private func scenarioLink(_ scenario: Scenario) -> some View {
        NavigationLink(value: makeHost(for: scenario)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(scenario.title).font(.body)
                Text(scenario.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Host construction

    /// Resolve the personalised first name for the greeting: the
    /// scenario's explicit override wins, otherwise we read `USER_NAME`
    /// from the launch environment. Nil falls through to the generic
    /// "Good afternoon" with no comma.
    private func resolvedUserName(for scenario: Scenario) -> String? {
        if let name = scenario.userName, !name.isEmpty { return name }
        let env = ProcessInfo.processInfo.environment["USER_NAME"] ?? ""
        return env.isEmpty ? nil : env
    }

    private func makeHost(for scenario: Scenario) -> HostConfiguration {
        let user = resolvedUserName(for: scenario)
        switch scenario.kind {
        case .stub(let fixture):
            return HostConfiguration(
                backendUrl: stubUrl,
                agentKey: "test-agent",
                testFixture: fixture,
                autoSendOnLaunch: !scenario.manual,
                autoSendPrompt: scenario.prompt,
                autoSendFollowUps: scenario.followUps,
                authToken: nil,
                enableTTS: scenario.enableTTS,
                enableVoice: scenario.enableVoice,
                anthropicShell: scenario.anthropicShell,
                userName: user
            )
        case .realBackend:
            return HostConfiguration(
                backendUrl: backendUrl,
                agentKey: agentKey,
                testFixture: "",
                autoSendOnLaunch: !scenario.manual,
                autoSendPrompt: scenario.prompt,
                autoSendFollowUps: scenario.followUps,
                authToken: authToken.isEmpty ? nil : authToken,
                enableTTS: scenario.enableTTS,
                enableVoice: scenario.enableVoice,
                anthropicShell: scenario.anthropicShell,
                userName: user
            )
        }
    }

    private func makeManualHost() -> HostConfiguration {
        HostConfiguration(
            backendUrl: stubUrl,
            agentKey: "test-agent",
            testFixture: "simple_streaming",
            autoSendOnLaunch: false,
            autoSendPrompt: "",
            autoSendFollowUps: [],
            authToken: nil,
            enableTTS: false,
            enableVoice: false,
            anthropicShell: false,
            userName: nil
        )
    }
}

private struct LabeledTextField: View {
    let label: String
    @Binding var text: String
    var isSecret: Bool = false

    var body: some View {
        HStack {
            Text(label).frame(width: 140, alignment: .leading)
                .font(.caption)
                .foregroundStyle(.secondary)
            if isSecret {
                SecureField(label, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            } else {
                TextField(label, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
            }
        }
    }
}

private struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).frame(width: 140, alignment: .leading)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
