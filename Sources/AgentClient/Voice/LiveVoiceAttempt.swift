import Foundation
#if os(iOS)
import AVFoundation
import UIKit
import Network
#endif

/// Owns resources independently of the observable model. Outstanding permission
/// and POST operations retain this cleanup owner, never the screen/model.
@MainActor
final class LiveVoiceAttempt {
    enum Update {
        case connecting, created(LiveSessionResponse), transport(LiveVoiceTransportEvent)
        case finalizing, finished(finalized: Bool, historyConfirmed: Bool), failed(String)
    }

    var onUpdate: ((Update) -> Void)?
    private let signaling: any LiveVoiceSignaling
    private let closeTimeout: UInt64
    private let finalizationTimeout: UInt64
    private let finalizationPollInterval: UInt64
    private(set) var transport: (any LiveVoiceTransport)?
    private var backendId: String?
    private var started = false
    private var ending = false
    private var finalizing = false
    private var providerClosed = false
    private var disposed = false
    private var backendCloseSent = false
    private var timeoutTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    #if os(iOS)
    private var networkMonitor: NWPathMonitor?
    #endif

    init(signaling: any LiveVoiceSignaling, closeTimeout: UInt64,
         finalizationTimeout: UInt64, finalizationPollInterval: UInt64) {
        self.signaling = signaling
        self.closeTimeout = closeTimeout
        self.finalizationTimeout = finalizationTimeout
        self.finalizationPollInterval = finalizationPollInterval
    }

    func begin(conversationId: String?, connectionTimeout: UInt64,
               permission: @escaping @MainActor () async -> Bool,
               makeTransport: @escaping @MainActor () throws -> any LiveVoiceTransport) {
        observeSafetyEvents()
        guard !disposed else { return }
        // Do not cancel a POST on end: a successful late response must be closed.
        Task { [self] in
            guard !ending, !disposed else { return }
            let allowed = await permission()
            guard !ending, !disposed else { return }
            guard allowed else { fail(LiveVoiceError.permissionDenied.localizedDescription); return }
            onUpdate?(.connecting)
            guard !ending, !disposed else { return }
            armTimeout(connectionTimeout) { $0.fail("The live voice connection timed out. Tap Start to try again.") }
            do {
                let peer = try makeTransport()
                transport = peer
                peer.onEvent = { [weak self] event in
                    guard let self, !self.disposed, !self.finalizing else { return }
                    self.onUpdate?(.transport(event))
                }
                // Handler registration precedes track/channel creation and offer.
                let offer = try await peer.makeOffer()
                guard !ending, !disposed else { return }
                let result = try await signaling.createLiveSession(sdp: offer, conversationId: conversationId)
                backendId = result.id
                guard !ending, !disposed else { closeBackend(); return }
                guard UUID(uuidString: result.id) != nil, !result.conversationId.isEmpty,
                      !result.session.id.isEmpty, result.transport.type == "webrtc",
                      !result.transport.sdp.isEmpty else { throw LiveVoiceError.invalidAnswer }
                onUpdate?(.created(result))
                guard !ending, !disposed else { return }
                try await peer.acceptAnswer(result.transport.sdp)
                // Only session.started, not SDP completion, makes this active.
            } catch {
                guard !ending, !disposed else { return }
                let message = (error as? LiveVoiceError)?.localizedDescription
                    ?? "Live voice could not connect. Please try again."
                fail(message)
            }
        }
    }

    func markStarted() {
        guard !ending, !disposed else { return }
        started = true
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    func end() {
        guard !ending, !disposed else { return }
        ending = true
        // Privacy is immediate. Only the data channel survives the close wait.
        transport?.stopMedia()
        removeObservers()
        timeoutTask?.cancel()
        if started, transport?.send(.close, eventId: UUID().uuidString) == true {
            // Alternate transports may deliver the close acknowledgment from
            // send itself. Do not replace an already-running history watchdog.
            guard !disposed, !finalizing else { return }
            armTimeout(closeTimeout) { $0.finalizeHistory() }
        } else {
            finalizeHistory()
        }
    }

    func remoteClosed() {
        guard !disposed, !finalizing else { return }
        providerClosed = true
        finalizeHistory()
    }

    /// A provider acknowledgment is not the worker's history commit. Release
    /// all RTC resources before waiting for the owner-scoped backend status.
    func finalizeHistory() {
        guard !disposed, !finalizing else { return }
        ending = true
        finalizing = true
        timeoutTask?.cancel()
        releaseTransport()
        onUpdate?(.finalizing)
        guard !disposed else { return }
        if !providerClosed { closeBackend() }
        guard let backendId, let expectedId = UUID(uuidString: backendId) else { dispose(); return }

        // Independent watchdog: even a non-cooperative adapter/request cannot
        // hold .ending indefinitely. Late results are ignored after disposal.
        armTimeout(finalizationTimeout) { $0.dispose() }
        let signaling = signaling
        let interval = finalizationPollInterval
        finalizationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let status = try await signaling.liveSessionStatus(id: backendId)
                    guard !Task.isCancelled, let self, !self.disposed else { return }
                    guard UUID(uuidString: status.id) == expectedId else { self.dispose(); return }
                    if status.isTerminal {
                        self.dispose(historyConfirmed: status.finalizationConfirmed,
                                     usageFinalized: status.usageFinalized)
                        return
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.dispose()
                    return
                }
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
            }
        }
    }

    func fail(_ message: String) {
        guard !disposed, !finalizing else { return }
        let notify = onUpdate
        dispose(notify: false)
        notify?(.failed(message))
    }

    /// Also used by model deinit. Safe and idempotent during any suspension.
    func dispose(historyConfirmed: Bool = false, usageFinalized: Bool = false, notify: Bool = true) {
        guard !disposed else { return }
        disposed = true
        ending = true
        timeoutTask?.cancel()
        timeoutTask = nil
        finalizationTask?.cancel()
        finalizationTask = nil
        releaseTransport()
        if !providerClosed { closeBackend() }
        if notify {
            onUpdate?(.finished(finalized: providerClosed || usageFinalized, historyConfirmed: historyConfirmed))
        }
        onUpdate = nil
    }

    private func releaseTransport() {
        transport?.stopMedia()
        transport?.onEvent = nil
        transport?.close()
        transport = nil
        removeObservers()
    }

    private func closeBackend() {
        guard let backendId, !backendCloseSent else { return }
        backendCloseSent = true
        // APIClient bounds the HTTP request to ten seconds. It owns no audio or
        // UI resources. A failed fallback never claims final usage was received.
        let signaling = signaling
        Task { try? await signaling.closeLiveSession(id: backendId) }
    }

    private func armTimeout(_ nanoseconds: UInt64, action: @escaping @MainActor (LiveVoiceAttempt) -> Void) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
            guard let self, !self.disposed else { return }
            action(self)
        }
    }

    private func observeSafetyEvents() {
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else {
            fail("Return to the app and tap Start to use live voice.")
            return
        }
        let center = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification, AVAudioSession.mediaServicesWereLostNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fail("Live voice stopped. Tap Start to reconnect.") }
            })
        }
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            MainActor.assumeIsolated { self?.fail("Audio was interrupted. Tap Start to reconnect.") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason == .oldDeviceUnavailable || reason == .noSuitableRouteForCategory else { return }
            MainActor.assumeIsolated { self?.fail("Your audio device disconnected. Tap Start to reconnect.") }
        })
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .unsatisfied else { return }
            Task { @MainActor [weak self] in self?.fail("The network disconnected. Tap Start to reconnect.") }
        }
        monitor.start(queue: DispatchQueue(label: "com.makemore.agent.live-network"))
        #endif
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        #if os(iOS)
        networkMonitor?.cancel()
        networkMonitor?.pathUpdateHandler = nil
        networkMonitor = nil
        #endif
    }
}