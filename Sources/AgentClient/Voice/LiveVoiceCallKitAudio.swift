import Foundation
#if os(iOS)
import AVFoundation
#if canImport(WebRTC)
import WebRTC
#endif
#endif

/// Call before fulfilling CXAnswerCallAction, then explicitly start the session.
/// Forward the provider's audio callbacks and reset after ending the session.
/// On macOS this retains only the ownership/gate state; it never opens audio.
@MainActor
public enum LiveVoiceCallKitAudio {
    private(set) static var isPrepared = false
    private(set) static var isAudioActive = false
    private static var token: UUID?
    private static var claimed = false
    private static var mediaReady = false
    static var isAudioEnabled: Bool { isPrepared && claimed && mediaReady && isAudioActive }
    #if os(iOS) && canImport(WebRTC)
    private static var previousManualAudio = false
    private static var previousAudioEnabled = false
    private static var activeSession: AVAudioSession?
    #endif

    /// Reserve the manual WebRTC gate and configure the system-call category
    /// before fulfilling an accepted CallKit action. Only CallKit activates audio.
    /// Unlike legacy prepare(), an existing reservation/owner is an error.
    public static func prepareForSystemCall() throws {
        try prepareForSystemCall(configure: {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat,
                                                           options: [.defaultToSpeaker, .allowBluetooth])
            #endif
        })
    }

    /// Configuration injection avoids any real audio-session calls in tests.
    static func prepareForSystemCall(configure: () throws -> Void) throws {
        guard token == nil, AudioSessionCoordinator.owner == .unclaimed else {
            throw LiveVoiceError.unavailable
        }
        prepare()
        do {
            try configure()
        } catch {
            reset()
            throw error
        }
    }

    /// Reserves Live audio and closes WebRTC's capture/playout gate before the
    /// system answer. Repeated preparation never steals an existing audio owner.
    public static func prepare() {
        guard token == nil, AudioSessionCoordinator.owner == .unclaimed else { return }
        token = UUID()
        isPrepared = true
        AudioSessionCoordinator.owner = .liveVoice
        #if os(iOS) && canImport(WebRTC)
        let audio = RTCAudioSession.sharedInstance()
        previousManualAudio = audio.useManualAudio
        previousAudioEnabled = audio.isAudioEnabled
        audio.useManualAudio = true
        audio.isAudioEnabled = false
        #endif
    }

    #if os(iOS)
    public static func didActivate(_ audioSession: AVAudioSession) {
        guard isPrepared, !isAudioActive else { return }
        #if canImport(WebRTC)
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        activeSession = audioSession
        #endif
        activationChanged(true)
    }

    public static func didDeactivate(_ audioSession: AVAudioSession) {
        guard isPrepared, isAudioActive else { return }
        // Close capture/playout before forwarding the system's deactivation.
        activationChanged(false)
        #if canImport(WebRTC)
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
        activeSession = nil
        #endif
    }
    #endif

    /// Idempotent. A transport also releases its lease on close, so a delayed
    /// host reset/deactivation cannot disable a subsequent ordinary Live call.
    public static func reset() {
        guard token != nil else { return }
        isPrepared = false
        isAudioActive = false
        mediaReady = false
        applyGate()
        #if os(iOS) && canImport(WebRTC)
        if let activeSession {
            // Balance WebRTC's external-activation bookkeeping, not AVAudioSession
            // activation. Only CallKit may activate/deactivate the system session.
            RTCAudioSession.sharedInstance().audioSessionDidDeactivate(activeSession)
            Self.activeSession = nil
        }
        #endif
        // Never restore automatic audio while a peer still has live tracks.
        guard !claimed else { return }
        #if os(iOS) && canImport(WebRTC)
        let audio = RTCAudioSession.sharedInstance()
        audio.isAudioEnabled = previousAudioEnabled
        audio.useManualAudio = previousManualAudio
        #endif
        token = nil
        if AudioSessionCoordinator.owner == .liveVoice { AudioSessionCoordinator.owner = .unclaimed }
    }

    static func claim() -> UUID? {
        guard isPrepared, !claimed, let token else { return nil }
        claimed = true
        return token
    }

    static func setMediaReady(_ ready: Bool, for lease: UUID) {
        guard token == lease, isPrepared, claimed else { return }
        mediaReady = ready
        applyGate()
    }

    static func release(_ lease: UUID) {
        guard token == lease else { return }
        claimed = false
        reset()
    }

    static func activationChanged(_ active: Bool) {
        guard isPrepared else { return }
        isAudioActive = active
        applyGate()
    }

    private static func applyGate() {
        #if os(iOS) && canImport(WebRTC)
        RTCAudioSession.sharedInstance().isAudioEnabled = isAudioEnabled
        #endif
    }
}