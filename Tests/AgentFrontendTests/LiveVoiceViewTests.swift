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

    func testOptionalAppearanceSupportsBothInitializersWithoutStartingAudio() {
        let session = LiveVoiceSession(signaling: UnusedLiveSignaling())
        let appearance = ChatAppearance.neutral
        _ = LiveVoiceView(session: session, appearance: nil) { _ in XCTFail("Must not end on construction") }
        _ = LiveVoiceView(session: session, appearance: appearance) { _ in XCTFail("Must not end on construction") }
        _ = LiveVoiceView(session: session, backendActivity: "Incoming",
                          endsOnBackground: false, endsOnDisappear: false,
                          appearance: appearance) { _ in XCTFail("Must not end on construction") }
        let _: @MainActor (APIClient) -> LiveVoiceView = {
            LiveVoiceView(apiClient: $0, appearance: nil) { _ in }
        }
        let _: @MainActor (APIClient) -> LiveVoiceView = {
            LiveVoiceView(apiClient: $0, conversationId: "manual", appearance: appearance) { _ in }
        }
        let _: @MainActor (APIClient) -> LiveVoiceView = {
            LiveVoiceView(apiClient: $0, conversationId: "incoming", backendActivity: "Incoming",
                          endsOnBackground: false, endsOnDisappear: false, appearance: appearance) { _ in }
        }
        XCTAssertEqual(session.state, .idle)
    }

    func testAppearanceIsOptInAndPreservesLegacyColorFallbacks() throws {
        let source = try liveVoiceSource()
        XCTAssertEqual(source.components(separatedBy: "appearance: ChatAppearance? = nil").count - 1, 2)
        XCTAssertEqual(source.components(separatedBy: "self.appearance = appearance").count - 1, 2)
        for contract in [
            "appearance.background.ignoresSafeArea()",
            "Color(red: 0.025, green: 0.035, blue: 0.10)",
            "Color(red: 0.08, green: 0.045, blue: 0.19)",
            "appearance?.surface ?? Color(red: 0.055, green: 0.04, blue: 0.15)",
            "appearance?.textPrimary ?? .white",
            "appearance?.textPrimary ?? .yellow",
            "appearance?.textSecondary ?? .white.opacity(0.75)",
            "appearance?.textSecondary ?? .white.opacity(0.8)",
            "appearance?.textSecondary ?? .white.opacity(0.85)",
            "appearance?.textSecondary ?? .white.opacity(0.65)",
            "appearance?.surface ?? .white.opacity(0.06)",
            ".tint(appearance?.accent ?? .purple)",
            ".tint(appearance?.accent ?? .indigo)",
            ".tint(appearance?.accent)",
            ".foregroundStyle(appearance?.textOnAccent ?? .white)",
            ".preferredColorScheme(appearance == nil ? .dark : nil)"
        ] {
            XCTAssertTrue(source.contains(contract), contract)
        }
    }

    func testThemedOrbKeepsMeasuredAudioScalingAndSystemReduceMotion() throws {
        let source = try liveVoiceSource()
        for contract in [
            "@Environment(\\.accessibilityReduceMotion) private var reduceMotion",
            "LiveAudioOrb(level: session.outputLevel, reduceMotion: reduceMotion, appearance: appearance,",
            "diameter: canStart ? 160 : 230)",
            "sqrt(max(0, min(1, level)))",
            "[appearance.surfaceElevated, appearance.accent, appearance.textPrimary]",
            "[Color(red: 0.52, green: 0.77, blue: 1), .blue, .indigo,",
            "Color(red: 0.18, green: 0.04, blue: 0.4)",
            "appearance?.accent ?? .purple",
            "appearance?.surfaceElevated ?? .cyan",
            "appearance?.textPrimary ?? .purple",
            "appearance?.background ?? .white",
            "appearance?.divider ?? .white.opacity(0.25)",
            ".frame(width: 230, height: 230)\n        .scaleEffect(diameter / 230)\n        .frame(width: diameter, height: diameter)",
            ".scaleEffect(reduceMotion ? 1 : 1 + energy * 0.13)",
            ".animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: energy)"
        ] {
            XCTAssertTrue(source.contains(contract), contract)
        }
        XCTAssertFalse(source.contains("repeatForever"))
        XCTAssertFalse(source.contains("TimelineView"))
    }

    /// Match existing lifecycle wiring checks: no mounted SwiftUI/audio stack.
    func testLifetimeDefaultsCallbacksAndAlreadyStartedMountWiring() throws {
        let source = try liveVoiceSource()
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

    private func liveVoiceSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentFrontend/Views/LiveVoiceView.swift")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Requires a checkout") }
        return try String(contentsOf: url, encoding: .utf8)
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