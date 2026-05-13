import XCTest
@testable import AgentClient

final class AgentStreamStateTests: XCTestCase {
    func testParserPreservesKnownEnvelopeAndMalformedFrames() {
        let event = AgentStreamEvent.parse(#"{"run_id":"r1","seq":2,"type":"assistant.delta","payload":{"delta":"hi"}}"#)
        XCTAssertTrue(event.known)
        XCTAssertEqual(event.type, "assistant.delta")
        XCTAssertEqual(event.runId, "r1")
        XCTAssertEqual(event.seq, 2)
        XCTAssertEqual(event.payload["delta"] as? String, "hi")

        let malformed = AgentStreamEvent.parse("{not-json}")
        XCTAssertFalse(malformed.known)
        XCTAssertEqual(malformed.type, "unknown")
        XCTAssertNotNil(malformed.parseError)
    }

    func testReducerMergesDeltasAndDedupesReplay() throws {
        let fixture = try SSEFixture.load("duplicate_replayed_event")
        var state = AgentRunReducerState()
        for (idx, ev) in fixture.events.enumerated() {
            let envelope: [String: Any] = [
                "run_id": fixture.runId,
                "seq": ev.seq_override ?? idx,
                "type": ev.event,
                "payload": ev.payload?.mapValues { $0.value } ?? [:]
            ]
            state.apply(AgentStreamEvent.parse(envelope, eventTypeHint: ev.event))
        }
        XCTAssertEqual(state.status, .succeeded)
        XCTAssertEqual(state.assistantText, "Hello world")
        XCTAssertTrue(state.seenEventKeys.contains("test-run-duplicate-001:0"))
    }

    func testReducerTracksToolFailureAndRequiredActionLifecycle() throws {
        var toolState = AgentRunReducerState()
        for event in try fixtureEvents("tool_call_failure") { toolState.apply(event) }
        XCTAssertEqual(toolState.toolCalls["call_fail_001"]?.status, "failed")

        var actionState = AgentRunReducerState()
        for event in try fixtureEvents("required_action_lifecycle") { actionState.apply(event) }
        XCTAssertEqual(actionState.requiredActions["act-approval-001"]?.status, "resolved")
        XCTAssertTrue(actionState.unknownEvents.contains { $0.type == "client.action.submitted" })
    }

    private func fixtureEvents(_ name: String) throws -> [AgentStreamEvent] {
        let fixture = try SSEFixture.load(name)
        return fixture.events.enumerated().map { idx, ev in
            let seq = ev.seq_override ?? idx
            let envelope: [String: Any] = [
                "run_id": fixture.runId,
                "seq": seq,
                "type": ev.event,
                "payload": ev.payload?.mapValues { $0.value } ?? [:]
            ]
            return AgentStreamEvent.parse(envelope, eventTypeHint: ev.event)
        }
    }
}
