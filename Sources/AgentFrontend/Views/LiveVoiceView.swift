import AgentClient
import SwiftUI

/// Full-screen native voice UI. The host makes chat inactive before presenting
/// this view and uses onEnd to dismiss/reload the resulting conversation.
@MainActor
public struct LiveVoiceView: View {
    @StateObject private var session: LiveVoiceSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsCaptions = false
    @State private var endingFromButton = false
    @State private var didEnd = false
    @State private var showsFinalizationWarning = false
    private let onEnd: (String?) -> Void
    /// Optional authoritative host/sideband activity, never inferred from text
    /// or silence. Kept separate from listening and measured audio output.
    private let backendActivity: String?

    public init(apiClient: APIClient, conversationId: String? = nil,
                backendActivity: String? = nil, onEnd: @escaping (String?) -> Void) {
        _session = StateObject(wrappedValue: LiveVoiceSession(apiClient: apiClient, conversationId: conversationId))
        self.backendActivity = backendActivity
        self.onEnd = onEnd
    }

    public init(session: LiveVoiceSession, backendActivity: String? = nil, onEnd: @escaping (String?) -> Void) {
        _session = StateObject(wrappedValue: session)
        self.backendActivity = backendActivity
        self.onEnd = onEnd
    }

    public var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.025, green: 0.035, blue: 0.10),
                                    Color(red: 0.08, green: 0.045, blue: 0.19)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    Text("Kinto Live")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("An AI conversation, at your pace")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                    LiveAudioOrb(level: session.outputLevel, reduceMotion: reduceMotion)
                        .frame(width: 230, height: 230)
                        .padding(.vertical, 20)
                        .accessibilityHidden(true)
                    status
                    if session.finalizationIncomplete {
                        Text("Audio has stopped. Conversation history may be incomplete because server finalization could not be confirmed.")
                            .font(.footnote)
                            .foregroundStyle(.yellow)
                    }
                    if canStart {
                        Text("You’re talking with an AI, not a person. Audio goes directly to OpenAI over an encrypted connection. Kinto saves text transcripts to your conversation. OpenAI also sends audio copies to Kinto’s control connection; Kinto discards these without recording them.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                        Button(action: session.start) {
                            Label("Start live voice", systemImage: "mic.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 56)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                        .accessibilityHint("Requests microphone permission and connects to the AI voice service")
                    }
                    controls
                    Toggle("Show captions", isOn: $showsCaptions)
                        .tint(.purple)
                        .frame(minHeight: 48)
                    if showsCaptions { captions }
                }
                .multilineTextAlignment(.center)
                .padding(28)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(session.state == .ending || session.finalizationIncomplete)
        .alert("Conversation history may be incomplete", isPresented: $showsFinalizationWarning) {
            Button("Return to chat") { notifyEnd() }
            Button("Stay here", role: .cancel) { endingFromButton = false }
        } message: {
            Text("Audio has stopped, but the server could not confirm that this conversation finished saving. Some spoken messages may be missing. Reopen the conversation later to check.")
        }
        .onChange(of: session.state) { _ in finishIfNeeded() }
        .onChange(of: scenePhase) { phase in
            if phase == .background { session.end() }
        }
        // No auto-start or auto-resume, including after interruptions.
        .onDisappear { session.end() }
    }

    private var canStart: Bool {
        switch session.state {
        case .idle, .ended, .failed: return !endingFromButton
        default: return false
        }
    }

    private var statusTitle: String {
        switch session.state {
        case .idle: return "Ready when you are"
        case .requestingPermission: return "Waiting for microphone permission"
        case .connecting: return "Connecting securely…"
        case .active: return session.isListening ? "Listening" : "Microphone muted"
        case .ending: return "Finishing conversation…"
        case .ended: return "Conversation ended"
        case .failed: return "Live voice stopped"
        }
    }

    private var status: some View {
        VStack(spacing: 10) {
            Text(statusTitle).font(.title2.weight(.medium))
            if session.state == .active {
                Label(session.isSpeaking ? "AI speaking" : "Connected",
                      systemImage: session.isSpeaking ? "waveform" : "checkmark.circle")
                    .foregroundStyle(.white.opacity(0.8))
                if session.acknowledgedMuted == nil && session.isMuted {
                    Text("Muted on this device • waiting for confirmation").font(.caption)
                }
                if let backendActivity {
                    Text(backendActivity).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                }
            }
            if case .failed(let message) = session.state {
                Text(message).font(.callout).foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            if session.state == .active {
                Button { session.setMuted(!session.isMuted) } label: {
                    Label(session.isMuted ? "Unmute" : "Mute", systemImage: session.isMuted ? "mic.slash.fill" : "mic.fill")
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.bordered)
                .accessibilityValue(session.isMuted ? "Microphone off" : "Microphone on")
            }
            Button(role: .destructive) {
                endingFromButton = true
                session.end()
                finishIfNeeded()
            } label: {
                Label(canStart ? "Done" : "End", systemImage: "xmark")
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.72, green: 0.12, blue: 0.24))
            .disabled(session.state == .ending)
            .accessibilityHint("Immediately stops your microphone and AI audio")
        }
    }

    private var captions: some View {
        // Two stable, independently growing lanes rather than guessed turns.
        // Scrolling is user-controlled; no forced jumps as fragments arrive.
        VStack(alignment: .leading, spacing: 20) {
            captionLane("You", text: session.inputTranscript)
            captionLane("AI", text: session.outputTranscript)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
    }

    private func captionLane(_ speaker: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(speaker).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.65))
            Text(text.isEmpty ? "No captions yet" : text)
                .font(.body)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
        }
    }

    private func finishIfNeeded() {
        guard endingFromButton, !didEnd else { return }
        switch session.state {
        case .ended, .failed:
            if session.finalizationIncomplete {
                // onEnd dismisses the screen immediately. Keep the warning on
                // screen until acknowledged rather than flashing it and losing it.
                showsFinalizationWarning = true
            } else {
                notifyEnd()
            }
        default: break
        }
    }

    private func notifyEnd() {
        guard !didEnd else { return }
        didEnd = true
        onEnd(session.conversationId)
    }
}

/// The orb responds only to measured inbound audio. No repeating pulse or
/// transcript-driven speaking animation; reduced motion fixes its geometry.
private struct LiveAudioOrb: View {
    let level: Double
    let reduceMotion: Bool
    private var energy: Double { sqrt(max(0, min(1, level))) }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.purple.opacity(0.22 + energy * 0.35))
                .blur(radius: 28)
                .scaleEffect(1.05)
            Circle()
                .fill(RadialGradient(colors: [Color(red: 0.52, green: 0.77, blue: 1), .blue, .indigo,
                                             Color(red: 0.18, green: 0.04, blue: 0.4)],
                                     center: .topLeading, startRadius: 8, endRadius: 220))
            ZStack {
                Ellipse().fill(.cyan.opacity(0.6)).frame(width: 200, height: 72).rotationEffect(.degrees(-35)).offset(y: -24)
                Ellipse().fill(.purple.opacity(0.8)).frame(width: 245, height: 72).rotationEffect(.degrees(40)).offset(y: 40)
                Circle().fill(.white.opacity(0.5)).frame(width: 65, height: 65).offset(x: -45, y: -60)
            }
            .blur(radius: 20)
            .clipShape(Circle())
            Circle().stroke(.white.opacity(0.25), lineWidth: 1)
        }
        .scaleEffect(reduceMotion ? 1 : 1 + energy * 0.13)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: energy)
    }
}