import Foundation

/// Canned scenario shown as a button in `ScenarioLauncherView`. Each one
/// matches a single XCUITest case in `ChatStreamingUITests.swift` so the
/// in-app launcher and the command-line test runner exercise identical
/// `HostConfiguration` shapes — only the assertion side differs.
struct Scenario: Identifiable, Hashable {
    enum Kind: Hashable {
        /// Replays the named JSON fixture via the local Python stub server.
        case stub(fixture: String)
        /// Hits the real Django `agent_studio` backend with DRF token auth.
        case realBackend
    }

    let id: String
    let title: String
    let subtitle: String
    let kind: Kind
    let prompt: String
    let followUps: [HostConfiguration.FollowUp]
}

extension ScenarioLauncherView {
    /// Mirrors the stub-server XCUITest scenarios in `ChatStreamingUITests`.
    /// Keep this list in sync if a new fixture is added — the in-app
    /// launcher and the test suite are intentionally one-to-one.
    static let stubScenarios: [Scenario] = [
        Scenario(
            id: "simple_streaming",
            title: "Simple streaming",
            subtitle: "Plain typewriter delta → final assistant bubble",
            kind: .stub(fixture: "simple_streaming"),
            prompt: "Hello agent",
            followUps: []
        ),
        Scenario(
            id: "tool_call_with_content_blocks",
            title: "Tool call + content blocks",
            subtitle: "Card + Table from a tool result",
            kind: .stub(fixture: "tool_call_with_content_blocks"),
            prompt: "Find me a place to stay",
            followUps: []
        ),
        Scenario(
            id: "sai_multi_agent_handoff",
            title: "Multi-agent hand-off",
            subtitle: "Parent intro → sub-agent reply, parent echo suppressed",
            kind: .stub(fixture: "sai_multi_agent_handoff"),
            prompt: "I'm feeling overwhelmed",
            followUps: []
        ),
        Scenario(
            id: "sai_multi_agent_with_blocks",
            title: "Multi-agent with blocks",
            subtitle: "Sub-agent emits Callout + CardList + ActionButtons",
            kind: .stub(fixture: "sai_multi_agent_with_blocks"),
            prompt: "Show me my account",
            followUps: []
        ),
        Scenario(
            id: "demo_big_conversation",
            title: "Demo: big conversation (3 turns)",
            subtitle: "~30 s multi-agent itinerary + 2 scripted follow-ups",
            kind: .stub(fixture: "demo_big_conversation"),
            prompt: "Plan me a 3-day trip to Tokyo",
            followUps: [
                HostConfiguration.FollowUp(prompt: "Yes, please book it.", delayMs: 1500),
                HostConfiguration.FollowUp(prompt: "Add the trip to my calendar.", delayMs: 1500),
            ]
        ),
        Scenario(
            id: "run_failed",
            title: "Run failed (error banner)",
            subtitle: "run.failed surfaces ErrorBannerView",
            kind: .stub(fixture: "run_failed"),
            prompt: "Crash on purpose",
            followUps: []
        ),
    ]

    /// Mirrors the real-backend XCUITest scenarios. Both require a running
    /// Django `agent_studio` instance and a DRF token entered in the
    /// launcher's settings section.
    static let realBackendScenarios: [Scenario] = [
        Scenario(
            id: "real_simple",
            title: "Hello round-trip",
            subtitle: "Single LLM round trip — \"hello from agent builder\"",
            kind: .realBackend,
            prompt: "Reply with exactly the words: hello from agent builder",
            followUps: []
        ),
        Scenario(
            id: "real_big",
            title: "Big conversation (3 turns)",
            subtitle: "ACK-ALPHA → ACK-BRAVO → RECAP, exercises memory",
            kind: .realBackend,
            prompt: "Reply with exactly the token ACK-ALPHA on its own line, then a one-sentence greeting.",
            followUps: [
                HostConfiguration.FollowUp(
                    prompt: "Now reply with exactly the token ACK-BRAVO on its own line, then a one-sentence weather remark.",
                    delayMs: 2000
                ),
                HostConfiguration.FollowUp(
                    prompt: "Recap: list the two ACK tokens you used so far, in order, on a single line that begins with the literal prefix RECAP: (e.g. \"RECAP: ACK-ALPHA, ACK-BRAVO\").",
                    delayMs: 2000
                ),
            ]
        ),
    ]
}
