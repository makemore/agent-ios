import Foundation
#if os(iOS)
import AVFoundation
#endif

/// One accepted system-call action, never a CallKit provider. The host owns the
/// provider, audio preparation/callbacks/reset, and the decision to accept a call.
@MainActor
public final class LiveVoiceSystemCall {
    public let session: LiveVoiceSession
    private let signaling: RevocableLiveVoiceSignaling
    private var hasStarted = false
    private var hasEnded = false
    private var startAuthorized = false

    /// Constructs an inert session. Microphone permission must already have been
    /// granted in the foreground; starting a system call never presents a prompt.
    public convenience init(signaling: any LiveVoiceSignaling, conversationId: String? = nil) {
        self.init(signaling: signaling, conversationId: conversationId) { signaling, conversationId in
            LiveVoiceSession(signaling: signaling, conversationId: conversationId, permission: {
                #if os(iOS)
                return AVAudioSession.sharedInstance().recordPermission == .granted
                #else
                return false
                #endif
            }, makeTransport: {
                // Never fall back to ordinary, self-activated audio if the host
                // forgot preparation or revoked it while permission was checked.
                guard LiveVoiceCallKitAudio.isPrepared else { throw LiveVoiceError.unavailable }
                return try LiveVoicePlatform.makeTransport()
            })
        }
    }

    /// Injection boundary. The factory must return an inert session using the
    /// supplied signaling adapter and must not request OS microphone permission.
    public init(signaling: any LiveVoiceSignaling, conversationId: String? = nil,
                makeSession: @MainActor (any LiveVoiceSignaling, String?) -> LiveVoiceSession) {
        let revocable = RevocableLiveVoiceSignaling(signaling: signaling)
        self.signaling = revocable
        session = makeSession(revocable, conversationId)
        // Exposing the observable session must not expose an alternate start
        // path (including a view's Start button or a retained session after end).
        session.authorizeStart = { [weak self] in
            guard let self, self.startAuthorized, !self.hasEnded else { return false }
            self.startAuthorized = false
            return true
        }
    }

    /// Invoke ONLY from an accepted CallKit action, after audio preparation.
    /// True means the sole start intent was accepted, not that connection succeeded.
    /// Failure, remote hangup, and end never permit another start on this object.
    @discardableResult
    public func start() -> Bool {
        guard !hasStarted, !hasEnded else { return false }
        hasStarted = true
        startAuthorized = true
        session.start()
        startAuthorized = false
        return true
    }

    /// Permanently revokes creation and stops media. Close and status requests
    /// remain available for the session's bounded history-finalization wait.
    public func end() {
        guard !hasEnded else { return }
        hasEnded = true
        signaling.revoke()
        session.end()
    }

    deinit {
        let signaling = signaling
        let session = session
        if Thread.isMainThread {
            MainActor.assumeIsolated { signaling.revoke(); session.end() }
        } else {
            Task { @MainActor in signaling.revoke(); session.end() }
        }
    }
}