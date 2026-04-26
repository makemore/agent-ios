import SwiftUI
import AgentFrontend

/// Minimal host app that embeds `AgentFrontend.ChatWidgetView`. Two launch
/// modes:
/// - **XCUITest / scripted**: when launch env vars (BACKEND_URL, STUB_SERVER_URL,
///   TEST_FIXTURE, AUTO_SEND_PROMPT, …) are present, jump straight to
///   `RootView` so the test runner sees the chat immediately. This is the
///   path Level C streaming tests use.
/// - **Manual**: when none of those are set, show `ScenarioLauncherView`
///   so a developer running the app from Xcode can pick any of the same
///   scenarios with a button tap.
@main
struct ExampleApp: App {
    var body: some Scene {
        WindowGroup {
            if HostConfiguration.isLaunchedByTestRunner() {
                RootView(host: HostConfiguration.fromEnvironment())
            } else {
                ScenarioLauncherView()
            }
        }
    }
}
