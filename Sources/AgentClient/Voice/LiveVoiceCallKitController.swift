import Combine
import Foundation
#if os(iOS)
import AVFoundation
import UIKit
#endif

/// Makes a `LiveVoiceSession` a system call: CallKit's call UI, the lock screen, background audio,
/// mute and hang-up from the system (or a headset), and the call ending with the session and vice versa.
///
/// One controller (one CallKit provider) per app, owned by something that outlives views, so a call
/// started by Siri or the app keeps running when its screen goes. Flow for an outgoing call:
///
/// 1. In the foreground, get microphone permission (`requestMicrophonePermission()`); a system call
///    never prompts.
/// 2. `startCall(...)` asks CallKit for the call. CallKit's accepted start action prepares system-call
///    audio (`LiveVoiceCallKitAudio`), and only then is the session started. CallKit, not the app,
///    activates the audio session.
/// 3. Show `call.session` (captions, levels) as usual. Mute and hang up through `setMuted(_:)` and
///    `endCall()` so the system call UI stays in step; the system's own buttons arrive here too.
/// 4. The session ending (remote close, failure) ends the system call; ending the system call ends
///    the session. `call` stays set while the session finalizes its history, then becomes nil and
///    `onCallEnded` runs.
///
/// Requires the app's `audio` background mode for the call to continue in the background. CallKit is
/// iOS only: elsewhere `startCall` throws `.unsupported` and `isSupported` is false.
@MainActor
public final class LiveVoiceCallKitController: ObservableObject {
    public struct Configuration: Equatable, Sendable {
        /// Whether calls appear in the Phone app's Recents. Off by default: a Recents entry redials
        /// through a SiriKit start-call intent, which the host would then have to handle.
        public var includesCallsInRecents: Bool
        /// A 40×40 pt template image (PNG data) for the system call UI's app button. iOS names the
        /// call provider after the app's display name.
        public var iconTemplateImageData: Data?

        public init(includesCallsInRecents: Bool = false, iconTemplateImageData: Data? = nil) {
            self.includesCallsInRecents = includesCallsInRecents
            self.iconTemplateImageData = iconTemplateImageData
        }
    }

    public struct Call: Identifiable {
        public enum Phase: Equatable, Sendable {
            /// CallKit has been asked for the call; nothing is connecting yet.
            case starting
            /// CallKit accepted the call; the session is connecting.
            case connecting
            /// The session is live.
            case active
            /// The call is over for the person; the session may still be finalizing its history.
            case ending
        }

        /// The system call's UUID.
        public let id: UUID
        /// The opaque, app-defined handle given to CallKit (e.g. the agent's key).
        public let handle: String
        /// What the system call UI shows as the other party.
        public let displayName: String
        public let systemCall: LiveVoiceSystemCall
        public internal(set) var phase: Phase
        public var session: LiveVoiceSession { systemCall.session }
    }

    @Published public private(set) var call: Call?
    /// Runs once per call when it is over and released, after the session finished (or gave up)
    /// finalizing its history. `call.session.conversationId` names the call's conversation.
    public var onCallEnded: ((Call) -> Void)?

    /// Whether this platform has CallKit (iOS).
    public static var isSupported: Bool {
        #if os(iOS) && canImport(CallKit)
        return true
        #else
        return false
        #endif
    }

    private let system: any LiveVoiceCallSystem
    private let audio: LiveVoiceCallAudio
    private let permission: @MainActor () -> Bool
    private let background: LiveVoiceBackgroundWork
    private let startTimeout: UInt64
    private let finalizationTimeout: UInt64
    private var observation: AnyCancellable?
    private var pendingStart: PendingStart?
    private var startTimer: Task<Void, Never>?
    private var finalizationTimer: Task<Void, Never>?
    private var backgroundToken: Any?

    /// The real CallKit provider on iOS. Create one per app and keep it.
    public convenience init(configuration: Configuration = Configuration()) {
        #if os(iOS) && canImport(CallKit)
        let system: any LiveVoiceCallSystem = CallKitLiveVoiceCallSystem(configuration: configuration)
        #else
        let system: any LiveVoiceCallSystem = UnsupportedLiveVoiceCallSystem()
        #endif
        self.init(system: system, audio: .callKit, permission: { LiveVoiceCallKitController.hasMicrophonePermission },
                  background: .application)
    }

    /// Injection boundary for tests.
    init(system: any LiveVoiceCallSystem, audio: LiveVoiceCallAudio, permission: @escaping @MainActor () -> Bool,
         background: LiveVoiceBackgroundWork = .none,
         startTimeoutNanoseconds: UInt64 = 10_000_000_000,
         finalizationTimeoutNanoseconds: UInt64 = 25_000_000_000) {
        self.system = system
        self.audio = audio
        self.permission = permission
        self.background = background
        startTimeout = startTimeoutNanoseconds
        finalizationTimeout = finalizationTimeoutNanoseconds
        system.events = self
    }

    /// Whether the person has already allowed the microphone. Never prompts.
    public static var hasMicrophonePermission: Bool {
        #if os(iOS)
        return AVAudioSession.sharedInstance().recordPermission == .granted
        #else
        return false
        #endif
    }

    /// Asks for the microphone if the person has not decided yet. Call it in the foreground, before
    /// `startCall`; true when allowed.
    public static func requestMicrophonePermission() async -> Bool {
        await LiveVoicePlatform.requestPermission()
    }

    /// Starts a system call with a new Live session on `signaling` (in `conversationId`, if given).
    /// Returns once CallKit has accepted the call and the session has been started, not when it is
    /// connected: follow `call?.session.state` for that.
    @discardableResult
    public func startCall(handle: String, displayName: String, signaling: any LiveVoiceSignaling,
                          conversationId: String? = nil) async throws -> Call {
        try await startCall(LiveVoiceSystemCall(signaling: signaling, conversationId: conversationId),
                            handle: handle, displayName: displayName)
    }

    /// Starts a system call for an inert `systemCall` (one nothing has started). The controller owns it
    /// from here: it is ended if the call cannot be started.
    @discardableResult
    public func startCall(_ systemCall: LiveVoiceSystemCall, handle: String, displayName: String) async throws -> Call {
        guard call == nil else { systemCall.end(); throw LiveVoiceCallKitError.busy }
        guard permission() else { systemCall.end(); throw LiveVoiceCallKitError.microphonePermission }
        guard AudioSessionCoordinator.owner == .unclaimed else { systemCall.end(); throw LiveVoiceCallKitError.audioBusy }
        try Task.checkCancellation()
        let id = UUID()
        call = Call(id: id, handle: handle, displayName: displayName, systemCall: systemCall, phase: .starting)
        beginBackgroundWork()
        startTimer = Task { [weak self, startTimeout] in
            do { try await Task.sleep(nanoseconds: startTimeout) } catch { return }
            guard let self, self.call?.id == id, self.call?.phase == .starting else { return }
            self.end(id, report: .failed, failure: .timedOut)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pendingStart = PendingStart(id: id, continuation: continuation)
                Task { [weak self] in
                    do {
                        try await self?.system.requestStart(id, handle: handle, displayName: displayName)
                        self?.startTransactionAccepted(id)
                    } catch {
                        guard let self else { return }
                        // CallKit refused the transaction: it has no call to report as ended.
                        self.end(id, report: nil, failure: error as? LiveVoiceCallKitError ?? .rejected(code: -1))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.end(id, report: .failed, failure: .cancelled) }
        }
        guard let call, call.id == id else { throw LiveVoiceCallKitError.cancelled }
        return call
    }

    /// Mutes or unmutes the call's microphone through CallKit, so the system call UI shows the same.
    public func setMuted(_ muted: Bool) {
        guard let call, call.phase == .active else { return }
        let id = call.id
        Task { [weak self] in
            do { try await self?.system.requestMute(id, muted: muted) } catch {
                // CallKit could not take it: still honour the person's choice locally.
                guard let self, self.call?.id == id else { return }
                self.call?.session.setMuted(muted)
            }
        }
    }

    /// Hangs up through CallKit (the session and its audio stop at once).
    public func endCall() {
        guard let call, call.phase != .ending else { return }
        let id = call.id
        Task { [weak self] in
            do { try await self?.system.requestEnd(id) } catch {
                // CallKit no longer knows the call: end it here and tell CallKit anyway.
                self?.end(id, report: .remoteEnded, failure: .cancelled)
            }
        }
    }

    // MARK: - Lifecycle

    private struct PendingStart {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
        var transactionAccepted = false
        var actionPerformed = false
    }

    private func startTransactionAccepted(_ id: UUID) {
        guard pendingStart?.id == id else { return }
        pendingStart?.transactionAccepted = true
        resolveStartIfReady()
    }

    /// The caller of `startCall` learns of success once CallKit accepted the transaction and performed
    /// its start action (either may come first).
    private func resolveStartIfReady() {
        guard let pending = pendingStart, pending.transactionAccepted, pending.actionPerformed else { return }
        pendingStart = nil
        pending.continuation.resume()
    }

    private func failStart(_ id: UUID, _ failure: LiveVoiceCallKitError) {
        guard let pending = pendingStart, pending.id == id else { return }
        pendingStart = nil
        pending.continuation.resume(throwing: failure)
    }

    private func observe(_ call: Call) {
        let id = call.id
        observation = call.session.$state.dropFirst().sink { [weak self] state in
            // @Published delivers before the property changes: act on the new value after it lands.
            Task { @MainActor [weak self] in self?.sessionChanged(id, state) }
        }
    }

    private func sessionChanged(_ id: UUID, _ state: LiveVoiceSession.State) {
        guard let call, call.id == id else { return }
        switch state {
        case .active:
            guard call.phase == .connecting else { return }
            self.call?.phase = .active
            system.reportConnected(id)
            // Active CallKit audio now keeps the app running in the background.
            endBackgroundWork()
        case .ending:
            // The session is closing on its own (the voice service hung up): end the system call.
            if call.phase != .ending { end(id, report: .remoteEnded, failure: .cancelled) }
        case .ended:
            if call.phase != .ending { end(id, report: .remoteEnded, failure: .cancelled) }
            finish(id)
        case .failed:
            if call.phase != .ending { end(id, report: .failed, failure: .cancelled) }
            finish(id)
        case .idle, .requestingPermission, .connecting:
            break
        }
    }

    /// The call is over for the person: stop audio, tell CallKit (unless it told us), and wait (bounded)
    /// for the session to finalize before releasing the call.
    private func end(_ id: UUID, report reason: LiveVoiceCallEndReason?, failure: LiveVoiceCallKitError) {
        guard let call, call.id == id, call.phase != .ending else { return }
        self.call?.phase = .ending
        startTimer?.cancel()
        failStart(id, failure)
        if let reason { system.reportEnded(id, reason: reason) }
        call.systemCall.end()
        audio.reset()
        switch call.session.state {
        case .ended, .failed, .idle:
            finish(id)
        default:
            beginBackgroundWork()
            finalizationTimer = Task { [weak self, finalizationTimeout] in
                do { try await Task.sleep(nanoseconds: finalizationTimeout) } catch { return }
                self?.finish(id)
            }
        }
    }

    private func finish(_ id: UUID) {
        guard let call, call.id == id else { return }
        if call.phase != .ending {
            end(id, report: nil, failure: .cancelled)
            guard self.call?.id == id else { return }
        }
        startTimer?.cancel()
        finalizationTimer?.cancel()
        observation = nil
        audio.reset()
        let finished = self.call!
        self.call = nil
        endBackgroundWork()
        onCallEnded?(finished)
    }

    private func beginBackgroundWork() {
        guard backgroundToken == nil else { return }
        backgroundToken = background.begin { [weak self] in
            // iOS is about to suspend the app: end the call rather than leave it half open.
            guard let self, let call = self.call else { return }
            self.end(call.id, report: .failed, failure: .cancelled)
            self.finish(call.id)
            self.endBackgroundWork()
        }
    }

    private func endBackgroundWork() {
        guard let token = backgroundToken else { return }
        backgroundToken = nil
        background.end(token)
    }
}

// MARK: - System call events

extension LiveVoiceCallKitController: LiveVoiceCallSystemEvents {
    func systemStart(_ id: UUID, fulfill: () -> Void, fail: () -> Void) {
        // Unknown, late or repeated start actions never create or restart a call.
        guard let call, call.id == id, call.phase == .starting, permission() else {
            fail()
            if self.call?.id == id { end(id, report: .failed, failure: .microphonePermission) }
            return
        }
        do { try audio.prepare() } catch {
            fail()
            end(id, report: .failed, failure: .audioBusy)
            return
        }
        self.call?.phase = .connecting
        startTimer?.cancel()
        observe(call)
        system.reportConnecting(id)
        // Fulfil before starting: waiting for CallKit's audio activation here would deadlock.
        fulfill()
        call.systemCall.start()
        pendingStart?.actionPerformed = true
        resolveStartIfReady()
    }

    func systemEnd(_ id: UUID) {
        // Fulfilling the end action is CallKit's own end report: do not report it again.
        end(id, report: nil, failure: .cancelled)
    }

    func systemSetMuted(_ id: UUID, muted: Bool) -> Bool {
        // The session takes mute changes only once connected; do not claim a no-op muted audio.
        guard let call, call.id == id, call.session.state == .active else { return false }
        call.session.setMuted(muted)
        return true
    }

    func systemTimedOut(_ id: UUID) {
        end(id, report: .failed, failure: .timedOut)
    }

    func systemReset() {
        if let call { end(call.id, report: nil, failure: .cancelled) }
        audio.reset()
    }

    func systemAudioActivationAllowed() -> Bool {
        guard let call else { return false }
        return call.phase == .connecting || call.phase == .active
    }
}

// MARK: - Errors and reasons

/// Fixed, content-free reasons a system call could not start. Never carries the system's error text.
public enum LiveVoiceCallKitError: Error, Equatable, LocalizedError, Sendable {
    /// No CallKit on this platform.
    case unsupported
    /// A call is already in progress.
    case busy
    /// The microphone is not allowed yet (ask in the foreground first).
    case microphonePermission
    /// Other audio (dictation, another call) holds the audio session.
    case audioBusy
    /// The build lacks what CallKit needs (check the app's capabilities and signing).
    case unentitled
    /// CallKit did not recognise the app's call provider.
    case providerUnavailable
    /// The system's call limit is reached (another call is in progress).
    case callLimitReached
    /// CallKit refused the start action (e.g. requested while the app could not start a call).
    case invalidAction
    /// CallKit refused the request with another code.
    case rejected(code: Int)
    /// CallKit did not start the call in time.
    case timedOut
    /// The call was ended or cancelled before it started.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupported: return "Calls are not available on this device."
        case .busy: return "A call is already in progress. End it before starting another."
        case .microphonePermission: return "Allow the microphone for this app in Settings, then try again."
        case .audioBusy: return "Other audio is using the microphone. Stop it and try again."
        case .unentitled: return "This build cannot make calls. It needs to be rebuilt with calling enabled."
        case .providerUnavailable: return "iOS could not find this app's calls. Open the app and try again."
        case .callLimitReached: return "Another call is in progress. End it and try again."
        case .invalidAction: return "iOS refused to start the call. Open the app and try again."
        case .rejected(let code): return "iOS refused to start the call (code \(code))."
        case .timedOut: return "iOS did not start the call in time. Try again."
        case .cancelled: return "The call was cancelled."
        }
    }
}

/// Why a call ended, as told to the system call UI.
enum LiveVoiceCallEndReason: Equatable {
    case failed, remoteEnded, unanswered
}

// MARK: - Seams (internal)

/// The system call service (CallKit on iOS). Requests are transactions the system then performs
/// through `events`; reports tell the system what happened on its own.
@MainActor
protocol LiveVoiceCallSystem: AnyObject {
    var events: (any LiveVoiceCallSystemEvents)? { get set }
    func requestStart(_ id: UUID, handle: String, displayName: String) async throws
    func requestEnd(_ id: UUID) async throws
    func requestMute(_ id: UUID, muted: Bool) async throws
    func reportConnecting(_ id: UUID)
    func reportConnected(_ id: UUID)
    func reportEnded(_ id: UUID, reason: LiveVoiceCallEndReason)
}

/// What the system performs: its actions (from a request, Siri or the system call UI) and audio.
@MainActor
protocol LiveVoiceCallSystemEvents: AnyObject {
    func systemStart(_ id: UUID, fulfill: () -> Void, fail: () -> Void)
    func systemEnd(_ id: UUID)
    func systemSetMuted(_ id: UUID, muted: Bool) -> Bool
    func systemTimedOut(_ id: UUID)
    func systemReset()
    func systemAudioActivationAllowed() -> Bool
}

/// System-call audio: reserve before CallKit's start action is fulfilled, release once the call ends.
struct LiveVoiceCallAudio {
    let prepare: @MainActor () throws -> Void
    let reset: @MainActor () -> Void

    @MainActor static let callKit = LiveVoiceCallAudio(prepare: { try LiveVoiceCallKitAudio.prepareForSystemCall() },
                                                       reset: { LiveVoiceCallKitAudio.reset() })
}

/// Background time while a call has no active audio to keep the app running (connecting, finalizing).
struct LiveVoiceBackgroundWork {
    let begin: @MainActor (@escaping @MainActor () -> Void) -> Any?
    let end: @MainActor (Any) -> Void

    static let none = LiveVoiceBackgroundWork(begin: { _ in nil }, end: { _ in })

    @MainActor static var application: LiveVoiceBackgroundWork {
        #if os(iOS)
        return LiveVoiceBackgroundWork(begin: { expired in
            let id = UIApplication.shared.beginBackgroundTask(withName: "Live voice call") {
                MainActor.assumeIsolated { expired() }
            }
            return id == .invalid ? nil : id
        }, end: { token in
            if let id = token as? UIBackgroundTaskIdentifier { UIApplication.shared.endBackgroundTask(id) }
        })
        #else
        return .none
        #endif
    }
}

/// Platforms without CallKit: every request fails, so no call is ever started.
@MainActor
final class UnsupportedLiveVoiceCallSystem: LiveVoiceCallSystem {
    weak var events: (any LiveVoiceCallSystemEvents)?
    func requestStart(_ id: UUID, handle: String, displayName: String) async throws { throw LiveVoiceCallKitError.unsupported }
    func requestEnd(_ id: UUID) async throws { throw LiveVoiceCallKitError.unsupported }
    func requestMute(_ id: UUID, muted: Bool) async throws { throw LiveVoiceCallKitError.unsupported }
    func reportConnecting(_ id: UUID) {}
    func reportConnected(_ id: UUID) {}
    func reportEnded(_ id: UUID, reason: LiveVoiceCallEndReason) {}
}
