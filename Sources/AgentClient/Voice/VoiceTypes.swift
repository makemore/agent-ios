import Foundation

/// Affective metadata attached to an assistant message or delta.
///
/// Mirrors ``agent_runtime_core.interfaces.Emotion`` on the Python side.
/// Voice providers map ``name``/``intensity`` onto their own controls
/// (ElevenLabs voice settings, AVSpeech rate/pitch, etc.).
public struct Emotion: Equatable {
    /// Provider-neutral label, e.g. ``"happy"``, ``"sad"``, ``"excited"``.
    public let name: String
    /// 0.0 - 1.0 strength hint. Defaults to 0.5 when not supplied by the agent.
    public let intensity: Double
    /// Free-form provider-specific extras (e.g. SSML, style ids).
    public let metadata: [String: Any]

    public init(name: String, intensity: Double = 0.5, metadata: [String: Any] = [:]) {
        self.name = name
        self.intensity = max(0.0, min(1.0, intensity))
        self.metadata = metadata
    }

    /// Build from the dict carried in the SSE payload's ``emotion`` key.
    public static func from(_ payload: Any?) -> Emotion? {
        guard let dict = payload as? [String: Any], let name = dict["name"] as? String, !name.isEmpty else {
            return nil
        }
        let intensity = (dict["intensity"] as? Double) ?? Double(dict["intensity"] as? Int ?? 0)
        let metadata = (dict["metadata"] as? [String: Any]) ?? [:]
        return Emotion(name: name, intensity: intensity > 0 ? intensity : 0.5, metadata: metadata)
    }

    public static func == (lhs: Emotion, rhs: Emotion) -> Bool {
        // Metadata is intentionally excluded from equality (heterogeneous values).
        return lhs.name == rhs.name && lhs.intensity == rhs.intensity
    }
}

/// Descriptor for a voice that the configured provider can speak in.
public struct VoiceDescriptor: Identifiable, Codable, Equatable {
    public let id: String
    public let name: String
    public let labels: [String: String]?

    public init(id: String, name: String, labels: [String: String]? = nil) {
        self.id = id
        self.name = name
        self.labels = labels
    }
}

/// Short-lived bearer + URL pair returned by the Django voice token mint.
public struct VoiceToken: Equatable {
    public let token: String
    public let ttsUrl: String
    public let expiresAt: Date

    public init(token: String, ttsUrl: String, expiresAt: Date) {
        self.token = token
        self.ttsUrl = ttsUrl
        self.expiresAt = expiresAt
    }
}

/// Per-utterance overrides passed into ``TTSProvider.speak``.
public struct TTSSpeakOptions {
    public var voiceId: String?
    public var modelId: String?
    public var voiceSettings: [String: Any]?
    public var emotion: Emotion?

    public init(
        voiceId: String? = nil,
        modelId: String? = nil,
        voiceSettings: [String: Any]? = nil,
        emotion: Emotion? = nil
    ) {
        self.voiceId = voiceId
        self.modelId = modelId
        self.voiceSettings = voiceSettings
        self.emotion = emotion
    }
}
