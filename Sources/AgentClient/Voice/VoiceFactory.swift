import Foundation

/// Factory for building a default ``TTSProvider`` from the widget config
/// + ``APIClient``.
///
/// Resolution order:
///   1. ElevenLabs proxy when the ``apiPaths.voiceToken`` path is set.
///   2. ``AVSpeechTTSProvider`` (always available on Apple platforms).
///
/// Returns ``nil`` only when the caller has explicitly cleared every path.
public enum VoiceFactory {
    public static func makeDefaultProvider(
        config: ChatWidgetConfig,
        apiClient: APIClient,
        voiceId: String? = nil,
        modelId: String? = nil
    ) -> TTSProvider? {
        if config.apiPaths.voiceToken != nil {
            return ElevenLabsTTSProvider(
                apiClient: apiClient,
                voiceId: voiceId,
                modelId: modelId
            )
        }
        return AVSpeechTTSProvider(voiceIdentifier: voiceId)
    }

    /// Build a configured ``VoiceController`` ready to wire into a
    /// ``ChatViewModel``. ``enableTTS`` is mirrored into the controller
    /// so the widget's existing toggle drives playback on/off.
    @MainActor
    public static func makeController(
        config: ChatWidgetConfig,
        apiClient: APIClient,
        voiceId: String? = nil,
        modelId: String? = nil
    ) -> VoiceController? {
        guard let provider = makeDefaultProvider(
            config: config, apiClient: apiClient,
            voiceId: voiceId, modelId: modelId
        ) else { return nil }
        return VoiceController(provider: provider, enabled: config.enableTTS)
    }
}
