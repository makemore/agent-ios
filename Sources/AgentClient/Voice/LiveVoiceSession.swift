import Combine
import Foundation

/// A single full-duplex GPT-Live conversation, explicitly started by a user tap.
/// No DictationEngine, TTS, audio proxy, or frontend tool execution is involved.
@MainActor
public final class LiveVoiceSession: ObservableObject {
    public enum State: Equatable {
        case idle, requestingPermission, connecting, active, ending, ended, failed(String)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var isMuted = false
    /// Provider acknowledgment is independent from the immediate local mute.
    @Published public private(set) var acknowledgedMuted: Bool?
    @Published public private(set) var inputLevel: Double = 0
    @Published public private(set) var outputLevel: Double = 0
    @Published public private(set) var captions: [LiveVoiceCaption] = []
    @Published public private(set) var conversationId: String?
    @Published public private(set) var usageSeconds: Double?
    /// Usage acknowledgment alone does not confirm server history persistence.
    @Published public private(set) var finalUsageConfirmed = false
    /// The backend did not confirm a fully finalized history commit. Hosts must
    /// not silently dismiss this warning just because final usage was received.
    @Published public private(set) var finalizationIncomplete = false

    public var isListening: Bool { state == .active && !isMuted }
    /// Only measured inbound RTC audio, never transcript arrival or a timer.
    public var isSpeaking: Bool { state == .active && outputLevel > 0.015 }
    public var inputTranscript: String { captions.filter { $0.speaker == .user }.map(\.delta).joined() }
    public var outputTranscript: String { captions.filter { $0.speaker == .assistant }.map(\.delta).joined() }

    private let signaling: any LiveVoiceSignaling
    private let permission: @MainActor () async -> Bool
    private let makeTransport: @MainActor () throws -> any LiveVoiceTransport
    private let connectionTimeout: UInt64
    private let closeTimeout: UInt64
    private let finalizationTimeout: UInt64
    private let finalizationPollInterval: UInt64
    private var attempt: LiveVoiceAttempt?
    private var generation = UUID()
    private var pendingMuteId: String?
    private var providerSessionId: String?

    public convenience init(apiClient: APIClient, conversationId: String? = nil) {
        self.init(signaling: apiClient, conversationId: conversationId,
                  permission: { await LiveVoicePlatform.requestPermission() },
                  makeTransport: { try LiveVoicePlatform.makeTransport() })
    }

    /// Injection boundary for deterministic tests and alternate native adapters.
    public init(signaling: any LiveVoiceSignaling, conversationId: String? = nil,
                permission: @escaping @MainActor () async -> Bool,
                makeTransport: @escaping @MainActor () throws -> any LiveVoiceTransport,
                connectionTimeoutNanoseconds: UInt64 = 40_000_000_000,
                closeTimeoutNanoseconds: UInt64 = 8_000_000_000,
                finalizationTimeoutNanoseconds: UInt64 = 12_000_000_000,
                finalizationPollIntervalNanoseconds: UInt64 = 500_000_000) {
        self.signaling = signaling
        self.conversationId = conversationId
        self.permission = permission
        self.makeTransport = makeTransport
        connectionTimeout = connectionTimeoutNanoseconds
        closeTimeout = closeTimeoutNanoseconds
        finalizationTimeout = finalizationTimeoutNanoseconds
        finalizationPollInterval = finalizationPollIntervalNanoseconds
    }

    deinit {
        let owner = attempt
        if Thread.isMainThread {
            MainActor.assumeIsolated { owner?.dispose(notify: false) }
        } else {
            Task { @MainActor in owner?.dispose(notify: false) }
        }
    }

    /// Synchronous intent; state publishes async progress. Never call on appear.
    public func start() {
        switch state {
        case .idle, .ended, .failed: break
        default: return
        }
        attempt?.dispose(notify: false)
        generation = UUID()
        let token = generation
        isMuted = false
        acknowledgedMuted = nil
        pendingMuteId = nil
        providerSessionId = nil
        captions = []
        usageSeconds = nil
        finalUsageConfirmed = false
        finalizationIncomplete = false
        resetLevels()
        state = .requestingPermission
        let owner = LiveVoiceAttempt(signaling: signaling, closeTimeout: closeTimeout,
                                     finalizationTimeout: finalizationTimeout,
                                     finalizationPollInterval: finalizationPollInterval)
        attempt = owner
        owner.onUpdate = { [weak self] update in
            guard let self, self.generation == token else { return }
            self.receive(update)
        }
        owner.begin(conversationId: conversationId, connectionTimeout: connectionTimeout,
                    permission: permission, makeTransport: makeTransport)
    }

    /// Local track changes immediately; an acknowledgment never re-enables it.
    public func setMuted(_ muted: Bool) {
        guard state == .active, muted != isMuted else { return }
        isMuted = muted
        if muted { inputLevel = 0 }
        attempt?.transport?.setMicrophoneEnabled(!muted)
        acknowledgedMuted = nil
        let eventId = UUID().uuidString
        pendingMuteId = eventId
        if attempt?.transport?.send(muted ? .mute : .unmute, eventId: eventId) != true {
            attempt?.fail("The microphone command could not be delivered. Tap Start to reconnect.")
        }
    }

    /// Returns immediately after stopping capture/output. `.ending` lasts only
    /// for bounded data-channel close and server-history finalization waits.
    public func end() {
        switch state {
        case .idle: state = .ended; return
        case .ended, .failed, .ending: return
        default: break
        }
        state = .ending
        isMuted = true
        resetLevels()
        attempt?.end()
    }

    private func receive(_ update: LiveVoiceAttempt.Update) {
        switch update {
        case .connecting:
            guard state == .requestingPermission else { return }
            state = .connecting
        case .created(let result):
            guard state == .connecting else { return }
            conversationId = result.conversationId
            providerSessionId = result.session.id
        case .transport(let event):
            switch event {
            case .message(let data): receiveMessage(data)
            case .levels(let input, let output):
                guard state == .active else { return }
                inputLevel = isMuted ? 0 : normalized(input)
                outputLevel = normalized(output)
            case .disconnected:
                if state == .ending { attempt?.finalizeHistory() }
                else { attempt?.fail("Live voice disconnected. Tap Start to reconnect.") }
            }
        case .finalizing:
            isMuted = true
            pendingMuteId = nil
            resetLevels()
            state = .ending
        case .finished(let finalized, let historyConfirmed):
            finalUsageConfirmed = finalized
            finalizationIncomplete = !historyConfirmed && providerSessionId != nil
            isMuted = true
            resetLevels()
            state = .ended
        case .failed(let message):
            finalizationIncomplete = providerSessionId != nil && !finalUsageConfirmed
            isMuted = true
            resetLevels()
            state = .failed(message)
        }
    }

    private func receiveMessage(_ data: Data) {
        guard [.connecting, .active, .ending].contains(state), data.count <= 262_144,
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        switch type {
        case "session.started":
            guard state == .connecting, providerSessionId != nil else { return }
            if let session = event["session"] as? [String: Any], let id = session["id"] as? String,
               id != providerSessionId { return }
            attempt?.markStarted()
            state = .active
        case "session.closed":
            readUsage(event)
            attempt?.remoteClosed()
        case "session.input_transcript.delta", "session.output_transcript.delta":
            guard let delta = event["delta"] as? String else { return }
            captions.append(LiveVoiceCaption(id: UUID(), speaker: type == "session.input_transcript.delta" ? .user : .assistant,
                                            delta: delta, startMilliseconds: event["start_ms"] as? Double,
                                            endMilliseconds: event["end_ms"] as? Double))
        case "session.usage.updated": readUsage(event)
        case "session.input_audio.muted", "session.input_audio.unmuted":
            guard state == .active, let id = event["client_event_id"] as? String, id == pendingMuteId,
                  (type == "session.input_audio.muted") == isMuted else { return }
            acknowledgedMuted = type == "session.input_audio.muted"
            pendingMuteId = nil
        case "error":
            // Fail closed without displaying provider payloads (may contain
            // private context). No data-channel command can execute a tool.
            attempt?.fail("The voice service reported an error. Tap Start to reconnect.")
        default: break
        }
    }

    private func readUsage(_ event: [String: Any]) {
        if let usage = event["usage"] as? [String: Any], let seconds = usage["seconds"] as? Double,
           seconds.isFinite, seconds >= 0 { usageSeconds = seconds }
    }

    private func normalized(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
    private func resetLevels() { inputLevel = 0; outputLevel = 0 }
}

@MainActor
enum LiveVoicePlatform {
    static func requestPermission() async -> Bool {
        #if os(iOS) && canImport(WebRTC)
        return await NativeLiveVoiceTransport.requestPermission()
        #else
        return false
        #endif
    }

    static func makeTransport() throws -> any LiveVoiceTransport {
        #if os(iOS) && canImport(WebRTC)
        return NativeLiveVoiceTransport()
        #else
        throw LiveVoiceError.unavailable
        #endif
    }
}