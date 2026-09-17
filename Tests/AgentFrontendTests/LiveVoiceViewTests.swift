import AgentClient
import AgentFrontend
import Foundation
import XCTest
#if os(iOS)
import AVFoundation
#endif

@MainActor
final class LiveVoiceViewTests: XCTestCase {
    func testPublicInitializersKeepStartExplicitAndSupportServiceOwnedLifetime() {
        let session = LiveVoiceSession(signaling: UnusedLiveSignaling())
        _ = LiveVoiceView(session: session) { _ in XCTFail("Must not end on construction") }
        _ = LiveVoiceView(session: session, backendActivity: "Incoming",
                          endsOnBackground: false, endsOnDisappear: false) { _ in XCTFail("Must not end on construction") }
        // Type-check both APIClient overload forms without constructing a client.
        let _: @MainActor (APIClient) -> LiveVoiceView = { LiveVoiceView(apiClient: $0) { _ in } }
        let _: @MainActor (APIClient) -> LiveVoiceView = {
            LiveVoiceView(apiClient: $0, conversationId: "incoming", backendActivity: nil,
                          endsOnBackground: false, endsOnDisappear: false) { _ in }
        }
        let _: @MainActor () -> Void = LiveVoiceCallKitAudio.prepare
        let _: @MainActor () -> Void = LiveVoiceCallKitAudio.reset
        #if os(iOS)
        let _: @MainActor (AVAudioSession) -> Void = LiveVoiceCallKitAudio.didActivate
        let _: @MainActor (AVAudioSession) -> Void = LiveVoiceCallKitAudio.didDeactivate
        #endif
        XCTAssertEqual(session.state, .idle)
    }

    /// Match existing lifecycle wiring checks: no mounted SwiftUI/audio stack.
    func testLifetimeDefaultsCallbacksAndAlreadyStartedMountWiring() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentFrontend/Views/LiveVoiceView.swift")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Requires a checkout") }
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "endsOnBackground: Bool = true").count - 1, 2)
        XCTAssertEqual(source.components(separatedBy: "endsOnDisappear: Bool = true").count - 1, 2)
        XCTAssertTrue(source.contains("if endsOnBackground, phase == .background { session.end() }"))
        XCTAssertTrue(source.contains(".onDisappear { if endsOnDisappear { session.end() } }"))
        XCTAssertTrue(source.contains("_session = StateObject(wrappedValue: session)"))
        XCTAssertTrue(source.contains(".onAppear { finishIfNeeded() }"))
        XCTAssertTrue(source.contains(".onChange(of: session.state) { _ in finishIfNeeded() }"))
        XCTAssertTrue(source.contains("let externallyManaged = !endsOnBackground && !endsOnDisappear"))
        XCTAssertTrue(source.contains("guard endingFromButton || externallyManaged else { return }"))
        XCTAssertTrue(source.contains("case .ended, .failed:"))
        XCTAssertTrue(source.contains("if session.finalizationIncomplete && !externallyManaged"))
        XCTAssertEqual(source.components(separatedBy: "session.start").count - 1, 1)
        XCTAssertTrue(source.contains("Button(action: session.start)"), "Start is only an explicit button action")
    }
}

@MainActor
private struct UnusedLiveSignaling: LiveVoiceSignaling {
    func createLiveSession(sdp: String, conversationId: String?) async throws -> LiveSessionResponse {
        XCTFail("View construction must not signal or request microphone access")
        throw LiveVoiceError.unavailable
    }
    func closeLiveSession(id: String) async throws { XCTFail("No session was started") }
}