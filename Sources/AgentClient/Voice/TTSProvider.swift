import Foundation

/// Modular TTS surface — implement this to plug a new voice backend
/// into ``VoiceController``. Mirrors the JS ``TTSProvider`` shape so the
/// platforms behave identically.
///
/// Implementations are expected to be safe to call from the main actor
/// (``VoiceController`` always invokes them from ``@MainActor`` context).
public protocol TTSProvider: AnyObject {
    /// Stable identifier for logging / config selection ("elevenlabs",
    /// "av-speech", ...).
    var name: String { get }

    /// Speak ``text``. Awaitable — returns when playback ends, throws
    /// ``CancellationError`` on cooperative cancellation.
    func speak(_ text: String, options: TTSSpeakOptions) async throws

    /// Stop any in-flight or queued utterance immediately.
    func cancel()

    /// List the voices the provider exposes. Returns ``[]`` when the
    /// provider is local (e.g. AVSpeech) and the host should consult
    /// system APIs directly.
    func listVoices() async throws -> [VoiceDescriptor]
}

public extension TTSProvider {
    /// Convenience for callers that don't need overrides.
    func speak(_ text: String) async throws {
        try await speak(text, options: TTSSpeakOptions())
    }
}
