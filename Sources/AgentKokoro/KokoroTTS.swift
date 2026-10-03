import Foundation
import AgentClient

/// Entry points for using Kokoro as the library's on-device voice.
public enum KokoroTTS {
    /// Makes Kokoro the voice ``VoiceFactory`` uses whenever it resolves
    /// on-device speech — ``TTSProviderPolicy/localOnly``, Protected AI
    /// Mode, or ``TTSProviderPolicy/automatic`` without a voice proxy —
    /// so the bundled chat widget picks it up with no other changes.
    /// Call once at launch, before building any chat UI.
    ///
    /// Policy is untouched: `.disabled` still creates no voice, and
    /// `.remote`/`.automatic` with a voice proxy still use the proxy.
    /// ``ChatWidgetConfig/voiceId`` selects the voice when it is a Kokoro
    /// id (`"bf_emma"`); anything else gets `defaultVoice`.
    ///
    /// - Parameters:
    ///   - defaultVoice: Voice when the config names none.
    ///   - speed: Speaking rate, 0.5–2.0.
    ///   - modelManager: Download/cache location and progress.
    ///   - autoDownload: Start the one-time model download on first use.
    public static func register(defaultVoice: KokoroVoice = .defaultVoice,
                                speed: Float = 1.0,
                                modelManager: KokoroModelManager = .shared,
                                autoDownload: Bool = true) {
        VoiceFactory.onDeviceProviderFactory = { voiceId in
            makeProvider(voiceId: voiceId, defaultVoice: defaultVoice, speed: speed,
                         modelManager: modelManager, autoDownload: autoDownload)
        }
    }

    /// Restores the system voice as the on-device provider.
    public static func unregister() {
        VoiceFactory.onDeviceProviderFactory = nil
    }

    /// Builds a provider for `voiceId` (a Kokoro voice id), falling back to
    /// `defaultVoice` for nil or unknown ids.
    public static func makeProvider(voiceId: String?,
                                    defaultVoice: KokoroVoice = .defaultVoice,
                                    speed: Float = 1.0,
                                    modelManager: KokoroModelManager = .shared,
                                    autoDownload: Bool = true) -> KokoroTTSProvider {
        let voice = voiceId.flatMap(KokoroVoice.init(id:)) ?? defaultVoice
        return KokoroTTSProvider(voice: voice, speed: speed, modelManager: modelManager,
                                 autoDownload: autoDownload)
    }

    /// The voices Kokoro offers, in Kokoro's order.
    public static var voices: [KokoroVoice] { KokoroVoice.all }
}
