import XCTest
@testable import AgentFrontend
@testable import AgentClient

final class AgentFrontendTests: XCTestCase {

    // MARK: - AgentFrontend convenience API (requires both modules)

    func testConfigurationMake() {
        let config = ChatWidgetConfig.make(
            backendUrl: "https://api.example.com",
            agentKey: "test-agent",
            title: "Test Chat"
        )

        XCTAssertEqual(config.backendUrl, "https://api.example.com")
        XCTAssertEqual(config.agentKey, "test-agent")
        XCTAssertEqual(config.title, "Test Chat")
    }

    // MARK: - Scroll Decision Tests

    func testScrollDecisionInitialLoadPinsBottomImmediately() {
        let action = ScrollDecision.onCountChange(
            oldCount: 0, newCount: 12,
            lastMessageIsUser: false, isNearBottom: false, pendingAnchorId: nil
        )
        XCTAssertEqual(action, .pinBottom)
    }

    func testScrollDecisionUserSubmitPinsWhenNearBottom() {
        // The new default behaviour respects the user's scroll position:
        // a user-submit only pins when the user is already near the
        // bottom. ``testScrollDecisionUserSubmitScrolledUpDoesNothing``
        // covers the "don't yank the user back" case; this one covers
        // the "pin when already near bottom" case.
        //
        // There is no longer a delay baked into the decision: the view
        // layer handles scheduling (one-frame wait + corrective clamp
        // loop). The decision layer only states the *intent*.
        let action = ScrollDecision.onCountChange(
            oldCount: 8, newCount: 9,
            lastMessageIsUser: true, isNearBottom: true, pendingAnchorId: nil
        )
        XCTAssertEqual(action, .pinBottom)
    }

    func testScrollDecisionUserSubmitScrolledUpDoesNothing() {
        // When the user has scrolled up to read old content, sending a
        // reply must not yank them back to the bottom — that's the
        // "screen jumps down" symptom reported on long conversations.
        // The new message appears above the viewport and the user can
        // scroll down when they're ready. ``forcePinOnUserSubmit`` is
        // the opt-in escape hatch for guided flows.
        let action = ScrollDecision.onCountChange(
            oldCount: 8, newCount: 9,
            lastMessageIsUser: true, isNearBottom: false, pendingAnchorId: nil
        )
        XCTAssertEqual(action, .none)
    }

    func testScrollDecisionUserSubmitScrolledUpForcePins() {
        // Guided flows that must show the agent's reply opt in via
        // ``forcePinOnUserSubmit: true``.
        let action = ScrollDecision.onCountChange(
            oldCount: 8, newCount: 9,
            lastMessageIsUser: true, isNearBottom: false,
            pendingAnchorId: nil, forcePinOnUserSubmit: true
        )
        XCTAssertEqual(action, .pinBottom)
    }

    func testScrollDecisionAssistantAppendNearBottomPinsImmediately() {
        // No keyboard to wait on for an assistant-driven append.
        let action = ScrollDecision.onCountChange(
            oldCount: 8, newCount: 9,
            lastMessageIsUser: false, isNearBottom: true, pendingAnchorId: nil
        )
        XCTAssertEqual(action, .pinBottom)
    }

    func testScrollDecisionAssistantAppendScrolledUpDoesNothing() {
        let action = ScrollDecision.onCountChange(
            oldCount: 8, newCount: 9,
            lastMessageIsUser: false, isNearBottom: false, pendingAnchorId: nil
        )
        XCTAssertEqual(action, .none)
    }

    func testScrollDecisionPrependPreservesAnchor() {
        let action = ScrollDecision.onCountChange(
            oldCount: 10, newCount: 20,
            lastMessageIsUser: false, isNearBottom: false,
            pendingAnchorId: "msg-99"
        )
        XCTAssertEqual(action, .preserveTopAnchor(id: "msg-99"))
    }

    func testScrollDecisionPrependWithoutPriorMessagesFallsThroughToPin() {
        // Edge case: oldCount==0 with a pending anchor. Treat as initial load,
        // not as prepend. (Anchor should have been cleared by the caller, but
        // test the pure logic anyway.)
        let action = ScrollDecision.onCountChange(
            oldCount: 0, newCount: 5,
            lastMessageIsUser: false, isNearBottom: false,
            pendingAnchorId: "msg-0"
        )
        XCTAssertEqual(action, .pinBottom)
    }

    func testScrollDecisionCountUnchangedDoesNothing() {
        let action = ScrollDecision.onCountChange(
            oldCount: 5, newCount: 5,
            lastMessageIsUser: true, isNearBottom: true, pendingAnchorId: nil
        )
        XCTAssertEqual(action, .none)
    }

    func testScrollDecisionCountDecreasedDoesNothing() {
        // Retry/edit truncates messages. The decision layer does not
        // re-position the user; SwiftUI keeps the current scroll.
        let action = ScrollDecision.onCountChange(
            oldCount: 10, newCount: 7,
            lastMessageIsUser: true, isNearBottom: true, pendingAnchorId: nil
        )
        XCTAssertEqual(action, .none)
    }

    // MARK: - VideoBlockView full-screen callback

    func testVideoBlockViewFullScreenCallbackDefaultsNil() {
        let block = VideoBlock(
            type: "video",
            url: "https://example.com/a.mp4",
            title: nil, caption: nil, thumbnailUrl: nil, autoplay: nil, mimeType: nil
        )
        let view = VideoBlockView(block: block)
        XCTAssertNil(view.onFullScreenChange)
    }

    func testVideoBlockViewForwardsFullScreenCallback() {
        var received: [Bool] = []
        let block = VideoBlock(
            type: "video",
            url: "https://example.com/a.mp4",
            title: "T", caption: nil, thumbnailUrl: nil, autoplay: nil, mimeType: nil
        )
        let view = VideoBlockView(block: block, onFullScreenChange: { received.append($0) })
        view.onFullScreenChange?(true)
        view.onFullScreenChange?(false)
        XCTAssertEqual(received, [true, false])
    }

    // MARK: - ChatWidgetConfig video full-screen wiring

    func testChatWidgetConfigVideoFullScreenDefaultsNil() {
        let config = ChatWidgetConfig()
        XCTAssertNil(config.onVideoFullScreenChange)
    }

    func testChatWidgetConfigVideoFullScreenIsAssignable() {
        var received: [Bool] = []
        var config = ChatWidgetConfig()
        config.onVideoFullScreenChange = { received.append($0) }
        config.onVideoFullScreenChange?(true)
        config.onVideoFullScreenChange?(false)
        XCTAssertEqual(received, [true, false])
    }

    // MARK: - ChatWidgetConfig forcePinOnUserSubmit

    func testChatWidgetConfigForcePinOnUserSubmitDefaultsToFalse() {
        // The new default respects the user's scroll position on submit.
        // Hosts that need the legacy "always pin" behaviour (e.g. a
        // guided flow) opt in explicitly.
        let config = ChatWidgetConfig()
        XCTAssertFalse(config.forcePinOnUserSubmit)
    }
}

