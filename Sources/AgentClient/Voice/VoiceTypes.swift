import Foundation

/// Policy used to choose how assistant text is converted to speech.
public enum TTSProviderPolicy: Equatable {
    /// Backwards-compatible behavior: prefer the configured remote provider,
    /// except protected/private-only mode biases to local system TTS.
    case automatic
    /// Use only remote/provider-backed TTS. Blocked in private-only mode.
    case remote
    /// Use only system/on-device TTS; never sends assistant text to the network.
    case localOnly
    /// Do not create a voice provider.
    case disabled
}

/// Policy used to choose speech-recognition privacy behavior for mic input.
public enum SpeechInputPolicy: Equatable {
    /// Backwards-compatible behavior; protected/private-only mode biases local-only.
    case automatic
    /// Allow platform remote speech recognition when the OS chooses it.
    case remote
    /// Require on-device speech recognition. If unsupported, mic input is disabled.
    case localOnly
    /// Hide/disable mic input.
    case disabled
}

/// Which engine turns mic audio into text for dictation.
public enum DictationBackend: Equatable {
    /// Apple's system recognizer (`SFSpeechRecognizer`) — the same engine
    /// behind the keyboard mic button. Subject to `SpeechInputPolicy` for
    /// on-device vs Apple-server recognition.
    case system
    /// On-device OpenAI Whisper via WhisperKit. Nothing leaves the device;
    /// `SpeechInputPolicy.localOnly` is inherently satisfied. `model` is a
    /// WhisperKit model name from the `argmaxinc/whisperkit-coreml` repo,
    /// e.g. "openai_whisper-base.en" or "openai_whisper-small.en".
    /// Weights are downloaded on first use and cached on device.
    case whisper(model: String)

    /// Reasonable accuracy/size default for phone-class hardware.
    public static let defaultWhisperModel = "openai_whisper-base.en"
}

/// Tracks whether something is holding the shared `AVAudioSession` in a
/// configuration that playback must not overwrite.
///
/// Playback normally reconfigures the session to `.playback`/`.spokenAudio`
/// before every utterance — that is what gets TTS media-level loudness and
/// A2DP over Bluetooth, and it repairs the route a previous dictation left
/// behind. That is right whenever recording and playback take turns.
///
/// Hands-free conversation breaks that assumption: the mic stays open
/// *through* playback so the user can interrupt by talking over the agent,
/// which requires `.playAndRecord`/`.voiceChat` for the whole conversation.
/// Reasserting `.playback` between sentences would tear the live input node
/// down mid-turn. While a continuous session is running it claims ownership
/// here and playback leaves the category alone.
public enum AudioSessionOwner {
    /// No claim — playback configures the session as it sees fit.
    case unclaimed
    /// A hands-free conversation owns the session for its duration.
    case continuousVoice
}

public enum AudioSessionCoordinator {
    /// Only ever read and written from the main queue.
    public static var owner: AudioSessionOwner = .unclaimed
}

/// Host-visible voice output status.
public enum VoiceMode: Equatable {
    case remote
    case local
    case unavailable(reason: String)
    case disabled
}

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
