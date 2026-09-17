import Foundation

public struct LiveSessionResponse: Decodable, Equatable, Sendable {
    /// Internal backend UUID, not the opaque provider session ID.
    public let id: String
    public let conversationId: String
    public let session: Session
    public let transport: Transport

    public struct Session: Decodable, Equatable, Sendable {
        public let id: String
        public init(id: String) { self.id = id }
    }

    public struct Transport: Decodable, Equatable, Sendable {
        public let type: String
        public let sdp: String
        public init(type: String = "webrtc", sdp: String) {
            self.type = type
            self.sdp = sdp
        }
    }

    public init(id: String, conversationId: String, session: Session, transport: Transport) {
        self.id = id
        self.conversationId = conversationId
        self.session = session
        self.transport = transport
    }
}

/// Owner-scoped backend status, not a provider data-channel acknowledgment.
public struct LiveSessionStatus: Decodable, Equatable, Sendable {
    public let id: String
    public let state: String
    public let usageFinalized: Bool

    public init(id: String, state: String, usageFinalized: Bool) {
        self.id = id
        self.state = state
        self.usageFinalized = usageFinalized
    }

    public var isTerminal: Bool { ["closed", "incomplete", "failed"].contains(state) }
    public var finalizationConfirmed: Bool { state == "closed" && usageFinalized }
}

@MainActor
public protocol LiveVoiceSignaling {
    func createLiveSession(sdp: String, conversationId: String?) async throws -> LiveSessionResponse
    func closeLiveSession(id: String) async throws
    func liveSessionStatus(id: String) async throws -> LiveSessionStatus
}

public extension LiveVoiceSignaling {
    /// Preserve existing adapters without mistaking unsupported polling for a
    /// successful history commit. Such adapters surface the incomplete warning.
    func liveSessionStatus(id: String) async throws -> LiveSessionStatus {
        throw LiveVoiceError.finalizationUnavailable
    }
}

/// The complete frontend command allowlist. No audio buffers or tool execution.
public enum LiveVoiceCommand: String, Sendable {
    case close = "session.close"
    case mute = "session.input_audio.mute"
    case unmute = "session.input_audio.unmute"
}

public enum LiveVoiceTransportEvent: Sendable {
    case message(Data)
    case levels(input: Double, output: Double)
    case disconnected
}

/// Implementations must be single-use, stop media synchronously, and suppress
/// callbacks after close. All callbacks are delivered on the main actor.
@MainActor
public protocol LiveVoiceTransport: AnyObject {
    var onEvent: ((LiveVoiceTransportEvent) -> Void)? { get set }
    func makeOffer() async throws -> String
    func acceptAnswer(_ sdp: String) async throws
    func setMicrophoneEnabled(_ enabled: Bool)
    @discardableResult func send(_ command: LiveVoiceCommand, eventId: String) -> Bool
    /// Stop capture AND output, but leave the data channel available to finalize.
    func stopMedia()
    func close()
}

/// Raw fragments in arrival order. Intervals may overlap, even across speakers.
public struct LiveVoiceCaption: Identifiable, Equatable, Sendable {
    public enum Speaker: String, Sendable { case user, assistant }
    public let id: UUID
    public let speaker: Speaker
    public let delta: String
    public let startMilliseconds: Double?
    public let endMilliseconds: Double?
}

public enum LiveVoiceError: Error, LocalizedError {
    case unavailable, permissionDenied, connectionFailed, invalidAnswer, finalizationUnavailable
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Live voice is not available on this device."
        case .permissionDenied: return "Microphone access is required. You can allow it in Settings."
        case .connectionFailed: return "The live voice connection could not be established."
        case .invalidAnswer: return "The voice service returned an invalid connection."
        case .finalizationUnavailable: return "Conversation history finalization could not be confirmed."
        }
    }
}