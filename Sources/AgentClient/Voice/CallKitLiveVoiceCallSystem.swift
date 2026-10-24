#if os(iOS) && canImport(CallKit)
import AVFoundation
import CallKit
import Foundation

/// `LiveVoiceCallKitController`'s CallKit provider and call controller. Its delegate runs on the main
/// queue; every action is checked by the controller, which fulfils or fails it.
@MainActor
final class CallKitLiveVoiceCallSystem: NSObject, LiveVoiceCallSystem, CXProviderDelegate {
    weak var events: (any LiveVoiceCallSystemEvents)?
    private let provider: CXProvider
    private let controller = CXCallController(queue: .main)
    /// Display names by call, for the update reported when CallKit starts the call.
    private var names: [UUID: String] = [:]

    init(configuration: LiveVoiceCallKitController.Configuration) {
        // iOS shows the app's display name for the provider.
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = configuration.includesCallsInRecents
        config.iconTemplateImageData = configuration.iconTemplateImageData
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    deinit { provider.invalidate() }

    func requestStart(_ id: UUID, handle: String, displayName: String) async throws {
        names[id] = displayName
        let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: handle))
        action.isVideo = false
        do { try await request(action) } catch {
            names[id] = nil
            throw error
        }
    }

    func requestEnd(_ id: UUID) async throws {
        try await request(CXEndCallAction(call: id))
    }

    func requestMute(_ id: UUID, muted: Bool) async throws {
        try await request(CXSetMutedCallAction(call: id, muted: muted))
    }

    func reportConnecting(_ id: UUID) {
        let update = CXCallUpdate()
        if let name = names[id] { update.localizedCallerName = name }
        update.hasVideo = false
        update.supportsDTMF = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        provider.reportCall(with: id, updated: update)
        provider.reportOutgoingCall(with: id, startedConnectingAt: Date())
    }

    func reportConnected(_ id: UUID) {
        provider.reportOutgoingCall(with: id, connectedAt: Date())
    }

    func reportEnded(_ id: UUID, reason: LiveVoiceCallEndReason) {
        names[id] = nil
        let systemReason: CXCallEndedReason
        switch reason {
        case .failed: systemReason = .failed
        case .remoteEnded: systemReason = .remoteEnded
        case .unanswered: systemReason = .unanswered
        }
        provider.reportCall(with: id, endedAt: Date(), reason: systemReason)
    }

    private func request(_ action: CXAction) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controller.request(CXTransaction(action: action)) { error in
                if let error { continuation.resume(throwing: Self.failure(error)) } else { continuation.resume() }
            }
        }
    }

    /// Only a fixed reason and CallKit's integer code; never the system's description.
    nonisolated static func failure(_ error: Error) -> LiveVoiceCallKitError {
        let error = error as NSError
        guard error.domain == CXErrorDomainRequestTransaction else { return .rejected(code: error.code) }
        switch CXErrorCodeRequestTransactionError.Code(rawValue: error.code) {
        case .unentitled: return .unentitled
        case .unknownCallProvider: return .providerUnavailable
        case .maximumCallGroupsReached: return .callLimitReached
        case .invalidAction: return .invalidAction
        default: return .rejected(code: error.code)
        }
    }

    // MARK: CXProviderDelegate (delivered on the main queue)

    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            names = [:]
            events?.systemReset()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        MainActor.assumeIsolated {
            guard let events, action.handle.type == .generic, !action.isVideo else { action.fail(); return }
            events.systemStart(action.callUUID, fulfill: { action.fulfill() }, fail: { action.fail() })
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // This provider makes outgoing calls only.
        action.fail()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated {
            names[action.callUUID] = nil
            events?.systemEnd(action.callUUID)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated {
            if events?.systemSetMuted(action.callUUID, muted: action.isMuted) == true { action.fulfill() } else { action.fail() }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        // Holding is not offered; another call ends this one instead.
        action.fail()
    }

    nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        MainActor.assumeIsolated {
            if let start = action as? CXStartCallAction { events?.systemTimedOut(start.callUUID) }
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            guard events?.systemAudioActivationAllowed() == true else { return }
            LiveVoiceCallKitAudio.didActivate(audioSession)
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { LiveVoiceCallKitAudio.didDeactivate(audioSession) }
    }
}

#endif
