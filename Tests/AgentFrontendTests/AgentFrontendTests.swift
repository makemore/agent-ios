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
        XCTAssertEqual(action, .pinBottom(delayMs: 0))
    }

    func testScrollDecisionUserSubmitDelaysForKeyboardAnimation() {
        // The submit path must wait past the UIKit keyboard-hide animation
        // (~250ms) before committing, otherwise the scroll lands on an
        // intermediate geometry and the row flies off. The exact delay value
        // is load-bearing — changing it is a deliberate behavioural change.
        let action = ScrollDecision.onCountChange(
            oldCount: 8, newCount: 9,
            lastMessageIsUser: true, isNearBottom: false, pendingAnchorId: nil
        )
        XCTAssertEqual(action, .pinBottom(delayMs: ScrollDecision.userSubmitDelayMs))
        XCTAssertGreaterThanOrEqual(ScrollDecision.userSubmitDelayMs, 300)
    }

    func testScrollDecisionAssistantAppendNearBottomPinsImmediately() {
        // No keyboard to wait on for an assistant-driven append.
        let action = ScrollDecision.onCountChange(
            oldCount: 8, newCount: 9,
            lastMessageIsUser: false, isNearBottom: true, pendingAnchorId: nil
        )
        XCTAssertEqual(action, .pinBottom(delayMs: 0))
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
        XCTAssertEqual(action, .pinBottom(delayMs: 0))
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
}

