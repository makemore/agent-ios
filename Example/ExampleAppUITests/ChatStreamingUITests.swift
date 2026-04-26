import XCTest

/// Level C streaming UI tests.
///
/// These tests launch the AgentExample host app pointed at the Python stub
/// server (`clients/test-stub-server/`) with a chosen fixture, and assert
/// that the rendered chat reflects the streamed content end-to-end through
/// the production AgentFrontend code path. The stub server must be running
/// at `STUB_SERVER_URL` (default `http://127.0.0.1:8765`) before the tests
/// are executed — see `clients/STREAMING_TESTS.md` for the runner script.
final class ChatStreamingUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// One scripted follow-up turn for `launchApp(followUps:)`. Mirrors the
    /// `{prompt, delay_ms}` shape parsed by `HostConfiguration`.
    struct FollowUp {
        let prompt: String
        let delayMs: Int
    }

    private func launchApp(
        fixture: String,
        prompt: String = "Hello agent",
        followUps: [FollowUp] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        let stubUrl = ProcessInfo.processInfo.environment["STUB_SERVER_URL"]
            ?? "http://127.0.0.1:8765"
        var env: [String: String] = [
            "STUB_SERVER_URL": stubUrl,
            "TEST_FIXTURE": fixture,
            "AUTO_SEND": "true",
            "AUTO_SEND_PROMPT": prompt,
            "AGENT_KEY": "test-agent",
        ]
        if !followUps.isEmpty {
            let arr: [[String: Any]] = followUps.map {
                ["prompt": $0.prompt, "delay_ms": $0.delayMs]
            }
            if let data = try? JSONSerialization.data(withJSONObject: arr),
               let json = String(data: data, encoding: .utf8) {
                env["AUTO_SEND_FOLLOW_UPS"] = json
            }
        }
        app.launchEnvironment = env
        app.launch()
        return app
    }

    /// Launch the host app pointed at a real Django backend with token auth.
    /// Returns nil (after recording an XCTSkip) if BACKEND_URL/AGENT_TOKEN
    /// are not provided — these tests are opt-in and require a running
    /// `agent_studio` server with a valid DRF token.
    private func launchAppAgainstRealBackend(
        agentKey: String,
        prompt: String,
        followUps: [FollowUp] = []
    ) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        guard let backend = env["BACKEND_URL"], !backend.isEmpty,
              let token = env["AGENT_TOKEN"], !token.isEmpty else {
            throw XCTSkip("Set BACKEND_URL and AGENT_TOKEN to run real-backend tests")
        }
        let app = XCUIApplication()
        var launchEnv: [String: String] = [
            "BACKEND_URL": backend,
            "AGENT_TOKEN": token,
            "AGENT_KEY": agentKey,
            "AUTO_SEND": "true",
            "AUTO_SEND_PROMPT": prompt,
        ]
        if !followUps.isEmpty {
            let arr: [[String: Any]] = followUps.map {
                ["prompt": $0.prompt, "delay_ms": $0.delayMs]
            }
            if let data = try? JSONSerialization.data(withJSONObject: arr),
               let json = String(data: data, encoding: .utf8) {
                launchEnv["AUTO_SEND_FOLLOW_UPS"] = json
            }
        }
        app.launchEnvironment = launchEnv
        app.launch()
        return app
    }

    private func assertText(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 20) {
        // Markdown paragraphs become staticTexts; SwiftUI Button labels appear
        // as buttons whose accessibility label is the inner Text. We poll
        // because of typewriter pacing and query both element types so action
        // buttons aren't false negatives.
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
        let staticHit = app.staticTexts.matching(predicate).firstMatch
        let buttonHit = app.buttons.matching(predicate).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if staticHit.exists || buttonHit.exists { return }
            _ = staticHit.waitForExistence(timeout: 0.25)
        } while Date() < deadline
        XCTFail("Expected text not found: \(text)")
    }

    /// Assert that `text` is rendered inside a message row whose
    /// accessibility identifier is `chat.message.user` (when `isUser` is
    /// true) or `chat.message.assistant`. Lets the multi-turn test verify
    /// that user prompts and assistant replies land on the correct side of
    /// the bubble layout, not just that the strings appear somewhere.
    private func assertTextInBubble(
        _ app: XCUIApplication,
        _ text: String,
        isUser: Bool,
        timeout: TimeInterval = 30
    ) {
        assertTextsInBubble(app, [text], isUser: isUser, timeout: timeout)
    }

    /// Assert that *every* substring in `texts` appears inside the **same**
    /// bubble row (one whose accessibility identifier is
    /// `chat.message.user` or `chat.message.assistant`). Implemented by
    /// chaining `containing(predicate)` calls — each chained call keeps
    /// only the rows whose subtree matches the next predicate, so the
    /// final query represents bubbles containing all substrings at once.
    /// This is the only way to prove co-location: a row "containing
    /// ACK-ALPHA AND ACK-BRAVO" cannot be satisfied by two separate
    /// earlier-turn bubbles that each carry only one of them.
    private func assertTextsInBubble(
        _ app: XCUIApplication,
        _ texts: [String],
        isUser: Bool,
        timeout: TimeInterval = 30
    ) {
        let bubbleId = isUser ? "chat.message.user" : "chat.message.assistant"
        var query = app.descendants(matching: .any)
            .matching(identifier: bubbleId)
        for text in texts {
            let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
            query = query.containing(predicate)
        }
        let bubble = query.firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if bubble.exists { return }
            _ = bubble.waitForExistence(timeout: 0.25)
        } while Date() < deadline
        let joined = texts.map { "\"\($0)\"" }.joined(separator: " + ")
        XCTFail("No \(bubbleId) bubble contained all of: \(joined)")
    }

    // MARK: - Scenarios

    func testSimpleStreamingRendersFinalMessage() {
        let app = launchApp(fixture: "simple_streaming")
        assertText(app, "Hello agent")  // user echo
        assertText(app, "Hello there! How can I help you today?")
    }

    func testToolCallContentBlocksRender() {
        let app = launchApp(fixture: "tool_call_with_content_blocks", prompt: "Find me a place to stay")
        assertText(app, "Find me a place to stay")
        // Card title from the fixture
        assertText(app, "Beach House")
        // Table cell from the fixture
        assertText(app, "Mountain Cabin")
        // Final assistant message after the blocks
        assertText(app, "I found 2 options that match.")
    }

    func testMultiAgentHandoffSuppressesParentEcho() {
        let app = launchApp(fixture: "sai_multi_agent_handoff", prompt: "I'm feeling overwhelmed")
        assertText(app, "I'm feeling overwhelmed")
        // Parent's intro
        assertText(app, "let me bring in our therapist")
        // Sub-agent's specialised reply
        assertText(app, "Could you tell me a little about what's on your mind?")
    }

    func testMultiAgentWithBlocks() {
        let app = launchApp(fixture: "sai_multi_agent_with_blocks", prompt: "Show me my account")
        assertText(app, "Show me my account")
        // Callout heading from the sub-agent's tool result
        assertText(app, "Account in good standing")
        // CardList item from the same blocks payload
        assertText(app, "Pro Monthly")
    }

    func testRunFailedSurfacesError() {
        let app = launchApp(fixture: "run_failed", prompt: "Crash on purpose")
        assertText(app, "Crash on purpose")
        // ErrorBannerView renders the upstream error string
        assertText(app, "Upstream provider unavailable", timeout: 20)
    }

    /// Long, slow demo run for hand-watching. Not for CI — the fixture
    /// deliberately paces itself over ~25–30 s and exercises three sub-agent
    /// handoffs plus most content-block renderers (callout, cardList, table,
    /// status, card, actionButtons, collapsible, code, divider). After the
    /// opener, two scripted user follow-ups are auto-sent (chained via the
    /// stub server's `next_fixture` to demo_followup_1 / demo_followup_2)
    /// so we also verify that user prompts render in `chat.message.user`
    /// bubbles and assistant replies in `chat.message.assistant` bubbles.
    func testDemoBigConversation() {
        let prompt1 = "Plan me a 3-day trip to Tokyo"
        let prompt2 = "Yes, please book it."
        let prompt3 = "Add the trip to my calendar."
        let app = launchApp(
            fixture: "demo_big_conversation",
            prompt: prompt1,
            followUps: [
                FollowUp(prompt: prompt2, delayMs: 1500),
                FollowUp(prompt: prompt3, delayMs: 1500),
            ]
        )
        // --- Turn 1: opener ---
        assertTextInBubble(app, prompt1, isUser: true, timeout: 10)
        // Parent intro
        assertText(app, "let me put my team on this", timeout: 30)
        // Researcher sub-agent: callout + cardList + table cells
        assertText(app, "Did you know?", timeout: 60)
        assertText(app, "Shibuya", timeout: 60)
        assertText(app, "Senso-ji Temple", timeout: 60)
        // Booking sub-agent: hotel card + status
        assertText(app, "Shibuya Sky Hotel", timeout: 90)
        assertText(app, "Live availability", timeout: 90)
        // Itinerary writer sub-agent: streamed markdown
        assertText(app, "Day 1 — Shibuya & Harajuku", timeout: 120)
        assertText(app, "teamLab Planets in the morning", timeout: 120)
        // Wrap-up callout + action buttons render via ContentBlockRenderer,
        // which now also carries the chat.message.assistant identifier so
        // we can verify they're on the assistant side.
        assertTextInBubble(app, "Trip ready", isUser: false, timeout: 150)
        assertTextInBubble(app, "Confirm everything", isUser: false, timeout: 150)
        // The streamed assistant wrap-up message lands in a real bubble.
        assertTextInBubble(app, "lock in the hotel", isUser: false, timeout: 150)

        // --- Turn 2: confirm booking (demo_followup_1) ---
        assertTextInBubble(app, prompt2, isUser: true, timeout: 30)
        assertTextInBubble(app, "Hotel booked", isUser: false, timeout: 30)
        assertTextInBubble(app, "add the trip to your calendar", isUser: false, timeout: 30)

        // --- Turn 3: add to calendar (demo_followup_2) ---
        assertTextInBubble(app, prompt3, isUser: true, timeout: 30)
        assertTextInBubble(app, "Calendar updated", isUser: false, timeout: 30)
        assertTextInBubble(app, "have a great trip", isUser: false, timeout: 30)
    }

    // MARK: - Real backend (opt-in)

    /// Drive the production AgentFrontend code path against a real running
    /// Django `agent_studio` backend using DRF token auth. Skipped unless
    /// BACKEND_URL and AGENT_TOKEN are set in the test runner environment.
    ///
    /// The Python smoke harness in
    /// `clients/test-stub-server/real_backend_smoke.py` exercises the same
    /// HTTP contract head-less; this test confirms the iOS chat widget
    /// renders the streamed reply end-to-end through the real backend.
    func testRealBackendAgentBuilderReplies() throws {
        let prompt = "Reply with exactly the words: hello from agent builder"
        let app = try launchAppAgainstRealBackend(
            agentKey: "agent-builder",
            prompt: prompt
        )
        // The user prompt always renders synchronously.
        assertText(app, prompt, timeout: 5)
        // The assistant reply has to round-trip through the LLM, which on
        // a cold path can take 10–30 s. We only assert a substring so the
        // test is robust to capitalisation / punctuation drift.
        assertText(app, "hello from agent builder", timeout: 60)
    }

    /// Three-turn conversation against the real Django backend. Mirrors the
    /// shape of `testDemoBigConversation` (opener + two scripted follow-ups
    /// driven via `AUTO_SEND_FOLLOW_UPS`) but uses sentinel tokens so the
    /// assertions survive LLM wording variability. The third turn relies on
    /// in-conversation memory to recall the first two tokens, which doubles
    /// as a smoke test for the run/messages context being threaded through
    /// the backend correctly. Skipped unless BACKEND_URL/AGENT_TOKEN are set.
    func testRealBackendBigConversation() throws {
        // Sentinels chosen to be unlikely to appear in normal LLM output,
        // ASCII-only (avoids smart-quote substitution), and uppercase so the
        // case-insensitive `CONTAINS[c]` predicate has nothing to trip on.
        let prompt1 = "Reply with exactly the token ACK-ALPHA on its own line, then a one-sentence greeting."
        let prompt2 = "Now reply with exactly the token ACK-BRAVO on its own line, then a one-sentence weather remark."
        let prompt3 = "Recap: list the two ACK tokens you used so far, in order, on a single line that begins with the literal prefix RECAP: (e.g. \"RECAP: ACK-ALPHA, ACK-BRAVO\")."
        let app = try launchAppAgainstRealBackend(
            agentKey: "agent-builder",
            prompt: prompt1,
            followUps: [
                // 2 s gap between turns gives the previous run's terminal
                // event time to flush through SSE before the next prompt
                // is queued. The host's `await sendMessage` already gates
                // on terminal events, the delay is just for breathing room.
                FollowUp(prompt: prompt2, delayMs: 2000),
                FollowUp(prompt: prompt3, delayMs: 2000),
            ]
        )
        // --- Turn 1 ---
        assertTextInBubble(app, prompt1, isUser: true, timeout: 10)
        assertTextInBubble(app, "ACK-ALPHA", isUser: false, timeout: 90)

        // --- Turn 2 ---
        assertTextInBubble(app, prompt2, isUser: true, timeout: 30)
        assertTextInBubble(app, "ACK-BRAVO", isUser: false, timeout: 90)

        // --- Turn 3: memory recall ---
        assertTextInBubble(app, prompt3, isUser: true, timeout: 30)
        // All three substrings must live inside the *same* bubble. Without
        // the co-location requirement the assertion would be trivially
        // satisfied by the turn-1 and turn-2 bubbles still on screen; the
        // RECAP: prefix is unique to this turn so it pins the match to the
        // correct bubble while ALPHA + BRAVO prove prior-turn context made
        // it back into the LLM call.
        assertTextsInBubble(
            app,
            ["RECAP:", "ACK-ALPHA", "ACK-BRAVO"],
            isUser: false,
            timeout: 90
        )
    }
}
