import SwiftUI

/// Manual test launcher shown when the host app is started without the
/// XCUITest driver env vars (see `HostConfiguration.isLaunchedByTestRunner`).
/// Lets a developer pick any of the canned streaming scenarios — stub-fixture
/// or real Django backend — and drive the production `ChatWidgetView` from a
/// button tap, mirroring exactly what XCUITest does headlessly.
struct ScenarioLauncherView: View {
    @AppStorage("launcher.stubUrl") private var stubUrl = "http://127.0.0.1:8765"
    @AppStorage("launcher.backendUrl") private var backendUrl = "http://127.0.0.1:8000"
    @AppStorage("launcher.authToken") private var authToken = ""
    @AppStorage("launcher.agentKey") private var realBackendAgentKey = "agent-echo"

    var body: some View {
        NavigationStack {
            List {
                Section("Endpoints") {
                    LabeledTextField(label: "Stub URL", text: $stubUrl)
                    LabeledTextField(label: "Django URL", text: $backendUrl)
                    LabeledTextField(label: "DRF token", text: $authToken, isSecret: true)
                    LabeledTextField(label: "Real-backend agent key", text: $realBackendAgentKey)
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

    private func makeHost(for scenario: Scenario) -> HostConfiguration {
        switch scenario.kind {
        case .stub(let fixture):
            return HostConfiguration(
                backendUrl: stubUrl,
                agentKey: "test-agent",
                testFixture: fixture,
                autoSendOnLaunch: true,
                autoSendPrompt: scenario.prompt,
                autoSendFollowUps: scenario.followUps,
                authToken: nil
            )
        case .realBackend:
            return HostConfiguration(
                backendUrl: backendUrl,
                agentKey: realBackendAgentKey,
                testFixture: "",
                autoSendOnLaunch: true,
                autoSendPrompt: scenario.prompt,
                autoSendFollowUps: scenario.followUps,
                authToken: authToken.isEmpty ? nil : authToken
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
            authToken: nil
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
