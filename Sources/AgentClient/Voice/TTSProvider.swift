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

    /// A new assistant turn is starting (``VoiceController/reset()``).
    ///
    /// Providers that make per-turn decisions — e.g. an on-device engine
    /// that fell back to the system voice and should stay on it for the
    /// rest of the turn rather than switch voices mid-reply — clear that
    /// state here. Optional: the default does nothing.
    func prepareForNewTurn()

    /// A chunk was queued and will be passed to ``speak(_:options:)``
    /// (with the same text) once the chunks ahead of it have played.
    /// ``VoiceController`` announces every chunk this way, in order, as it
    /// is queued. Providers that synthesise locally can start on it now so
    /// it is ready without a pause. Optional: the default does nothing.
    func prefetch(_ text: String, options: TTSSpeakOptions)
}

public extension TTSProvider {
    func prepareForNewTurn() {}
    func prefetch(_ text: String, options: TTSSpeakOptions) {}

    /// Convenience for callers that don't need overrides.
    func speak(_ text: String) async throws {
        try await speak(text, options: TTSSpeakOptions())
    }
}
