import Foundation
import AgentClient

/// Entry points for using Kokoro as the library's on-device voice.
public enum KokoroTTS {
    /// Engine id, the same on iOS, Android and the web widget. Also
    /// ``KokoroTTSProvider/name``.
    public static let engineId = "kokoro"

    /// The manager ``register(configuration:modelManager:autoDownload:)``
    /// installed (``KokoroModelManager/shared`` until then). Call
    /// `prepare()` / `prefetch()` on it to download ahead of the first reply.
    public private(set) static var modelManager: KokoroModelManager = .shared

    /// Makes Kokoro the voice ``VoiceFactory`` uses whenever it resolves
    /// on-device speech — ``TTSProviderPolicy/localOnly``, Protected AI
    /// Mode, or ``TTSProviderPolicy/automatic`` without a voice proxy —
    /// so the bundled chat widget picks it up with no other changes.
    /// Opt-in: nothing changes until a host calls this. Call once at
    /// launch, before building any chat UI.
    ///
    /// Policy is untouched: `.disabled` still creates no voice, and
    /// `.remote`/`.automatic` with a voice proxy still use the proxy.
    /// ``ChatWidgetConfig/voiceId`` selects the voice when it is a Kokoro
    /// id (`"bf_emma"`); anything else gets ``KokoroConfiguration/voice``.
    ///
    /// - Parameters:
    ///   - configuration: Base URL, default voice, speed, cache.
    ///   - modelManager: Use this manager instead of one built from
    ///     `configuration` (it keeps its own configuration for downloads).
    ///   - autoDownload: Start the one-time model download on first use.
    public static func register(configuration: KokoroConfiguration = KokoroConfiguration(),
                                modelManager: KokoroModelManager? = nil,
                                autoDownload: Bool = true) {
        let manager = modelManager
            ?? (configuration == KokoroModelManager.shared.configuration ? .shared : KokoroModelManager(configuration: configuration))
        self.modelManager = manager
        VoiceFactory.onDeviceProviderFactory = { voiceId in
            makeProvider(voiceId: voiceId, configuration: configuration, modelManager: manager,
                         autoDownload: autoDownload)
        }
    }

    /// Restores the system voice as the on-device provider.
    public static func unregister() {
        VoiceFactory.onDeviceProviderFactory = nil
        modelManager = .shared
    }

    /// Builds a provider for `voiceId` (a Kokoro voice id), falling back to
    /// the configured voice for nil or unknown ids.
    public static func makeProvider(voiceId: String?,
                                    configuration: KokoroConfiguration = KokoroConfiguration(),
                                    modelManager: KokoroModelManager = .shared,
                                    autoDownload: Bool = true) -> KokoroTTSProvider {
        var config = configuration
        if let voiceId, KokoroVoice(id: voiceId) != nil { config.voice = voiceId }
        return KokoroTTSProvider(configuration: config, modelManager: modelManager, autoDownload: autoDownload)
    }

    /// The voices Kokoro offers (built in; ``KokoroModelManager/voices()``
    /// reads the same list from the asset set).
    public static var voices: [KokoroVoice] { KokoroVoice.all }
}
