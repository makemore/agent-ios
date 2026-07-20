import Foundation

/// Result of applying ``ChatWidgetConfig.ttsProviderPolicy``.
public struct VoiceProviderResolution {
    public let provider: TTSProvider?
    public let mode: VoiceMode

    public init(provider: TTSProvider?, mode: VoiceMode) {
        self.provider = provider
        self.mode = mode
    }
}

/// Factory for building a default ``TTSProvider`` from the widget config.
public enum VoiceFactory {
    public static func resolveProvider(
        config: ChatWidgetConfig,
        apiClient: APIClient?,
        voiceId: String? = nil,
        modelId: String? = nil
    ) -> VoiceProviderResolution {
        if config.ttsProviderPolicy == .disabled {
            return VoiceProviderResolution(provider: nil, mode: .disabled)
        }

        if config.privateOnly && config.ttsProviderPolicy == .remote {
            return VoiceProviderResolution(
                provider: nil,
                mode: .unavailable(reason: "Remote voice is disabled in Protected AI Mode")
            )
        }

        switch config.effectiveTTSProviderPolicy {
        case .localOnly:
            return VoiceProviderResolution(
                provider: AVSpeechTTSProvider(voiceIdentifier: voiceId),
                mode: .local
            )
        case .remote:
            guard let apiClient, config.apiPaths.voiceToken != nil else {
                return VoiceProviderResolution(
                    provider: nil,
                    mode: .unavailable(reason: "Remote voice endpoint is not configured")
                )
            }
            return VoiceProviderResolution(
                provider: ElevenLabsTTSProvider(apiClient: apiClient, voiceId: voiceId, modelId: modelId),
                mode: .remote
            )
        case .automatic:
            if let apiClient, config.apiPaths.voiceToken != nil {
                return VoiceProviderResolution(
                    provider: ElevenLabsTTSProvider(apiClient: apiClient, voiceId: voiceId, modelId: modelId),
                    mode: .remote
                )
            }
            return VoiceProviderResolution(
                provider: AVSpeechTTSProvider(voiceIdentifier: voiceId),
                mode: .local
            )
        case .disabled:
            return VoiceProviderResolution(provider: nil, mode: .disabled)
        }
    }

    public static func makeDefaultProvider(
        config: ChatWidgetConfig,
        apiClient: APIClient?,
        voiceId: String? = nil,
        modelId: String? = nil
    ) -> TTSProvider? {
        resolveProvider(config: config, apiClient: apiClient, voiceId: voiceId, modelId: modelId).provider
    }

    /// Build a configured ``VoiceController`` ready to wire into a
    /// ``ChatViewModel``. ``enableTTS`` is mirrored into the controller
    /// so the widget's existing toggle drives playback on/off.
    @MainActor
    public static func makeController(
        config: ChatWidgetConfig,
        apiClient: APIClient?,
        voiceId: String? = nil,
        modelId: String? = nil
    ) -> VoiceController {
        let resolved = resolveProvider(config: config, apiClient: apiClient, voiceId: voiceId, modelId: modelId)
        return VoiceController(provider: resolved.provider, enabled: config.enableTTS, voiceMode: resolved.mode)
    }
}
