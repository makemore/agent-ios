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
    /// When true, opens the chat without firing `autoSendPrompt` so the
    /// developer can drive the turn manually (e.g. via the mic button).
    var manual: Bool = false
    /// Turn TTS playback on for this scenario. Routes through the
    /// Django voice proxy when the backend has the endpoints mounted.
    var enableTTS: Bool = false
    /// Show the mic button so SFSpeech results land in the input field.
    var enableVoice: Bool = false
    /// Render the warm-dark shell (rounded composer card, greeting
    /// empty state, slide-in sidebar). Defaults to `false` so the
    /// existing scenarios keep their original look; the "S'Ai home"
    /// scenario flips this on.
    var anthropicShell: Bool = false
    /// Optional first name for the greeting. The launcher falls back to
    /// `USER_NAME` from the environment when this is nil so a developer
    /// can personalise the demo without editing source.
    var userName: String? = nil
    /// Per-scenario override for `agentKey`. When nil, real-backend
    /// scenarios fall back to the active scheme's `AGENT_KEY` env var
    /// (or the "chisel" default). Used by the S'Ai local-Django entries
    /// to pin the slug regardless of which scheme is selected.
    var agentKeyOverride: String? = nil
}

extension ScenarioLauncherView {
    /// Warm-dark baseline scenarios. Both flip `anthropicShell` on so
    /// the host opts into the full new look (warm-dark background,
    /// rounded composer, greeting, sidebar). The empty-chat entry
    /// shows the idle home state.
    static let anthropicShellScenarios: [Scenario] = [
        Scenario(
            id: "sai_home_empty",
            title: "S'Ai home (empty chat)",
            subtitle: "Greeting + rounded composer + sidebar, idle empty state",
            kind: .stub(fixture: "simple_streaming"),
            prompt: "",
            followUps: [],
            manual: true,
            enableTTS: false,
            enableVoice: true,
            anthropicShell: true
        ),
        Scenario(
            id: "sai_home_streaming",
            title: "S'Ai home (streaming demo)",
            subtitle: "Same shell, auto-sends a prompt so you can see the chat layout",
            kind: .stub(fixture: "demo_big_conversation"),
            prompt: "Plan me a 3-day trip to Tokyo",
            followUps: [
                HostConfiguration.FollowUp(prompt: "Yes, please book it.", delayMs: 1500)
            ],
            manual: false,
            enableTTS: false,
            enableVoice: true,
            anthropicShell: true
        ),
    ]

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
        Scenario(
            id: "real_voice_chat",
            title: "Voice chat (TTS + mic)",
            subtitle: "Hands-free: tap mic to speak, hear the agent reply",
            kind: .realBackend,
            prompt: "",
            followUps: [],
            manual: true,
            enableTTS: true,
            enableVoice: true
        ),
        Scenario(
            id: "real_voice_tts_only",
            title: "Voice playback (TTS only)",
            subtitle: "Type prompts, hear streamed sentences via ElevenLabs",
            kind: .realBackend,
            prompt: "",
            followUps: [],
            manual: true,
            enableTTS: true,
            enableVoice: false
        ),
        // S'Ai Triage agent on the local Django backend. Mirrors
        // /studio/agents/1b70ad3e-…/test/ and /studio/systems/23298cfd-…/test/
        // — both pages send the same `agentKey` (the system's entry_agent
        // slug is `sai-triage`), so a single entry covers both URLs.
        Scenario(
            id: "real_sai_triage",
            title: "S'Ai Triage (local Django)",
            subtitle: "Warm-dark shell against /studio/agents/.../test/ (slug: sai-triage)",
            kind: .realBackend,
            prompt: "",
            followUps: [],
            manual: true,
            enableTTS: true,
            enableVoice: true,
            anthropicShell: true,
            agentKeyOverride: "sai-triage"
        ),
        Scenario(
            id: "real_sai_dev_guidance_system",
            title: "S'Ai Developmental Guidance system (local Django)",
            subtitle: "Same slug, drives the system's entry agent (sai-triage)",
            kind: .realBackend,
            prompt: "",
            followUps: [],
            manual: true,
            enableTTS: true,
            enableVoice: true,
            anthropicShell: true,
            agentKeyOverride: "sai-triage"
        ),
    ]
}
