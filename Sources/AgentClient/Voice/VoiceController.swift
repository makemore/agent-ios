import Foundation
import Combine

/// Orchestrates streaming TTS for an assistant turn.
///
/// Responsibilities:
///   1. Buffer assistant deltas through a ``SentenceChunker``.
///   2. Pipe each emitted sentence into the configured ``TTSProvider``,
///      enqueued so utterances play in order.
///   3. Publish ``isSpeaking`` so SwiftUI can react.
///   4. Allow ``stop()`` (user interrupt) and ``reset()`` (new turn).
///
/// The controller is provider-agnostic — pass any object conforming to
/// ``TTSProvider``.
@MainActor
public final class VoiceController: ObservableObject {
    @Published public private(set) var isSpeaking: Bool = false
    @Published public var isEnabled: Bool

    private let provider: TTSProvider
    private var queue: [String] = []
    private var isDraining: Bool = false
    private var currentTask: Task<Void, Never>?
    private var currentEmotion: Emotion?
    private var chunker: SentenceChunker!

    public init(provider: TTSProvider, enabled: Bool = true,
                minChars: Int = 40, maxChars: Int = 240) {
        self.provider = provider
        self.isEnabled = enabled
        self.chunker = SentenceChunker(minChars: minChars, maxChars: maxChars) { [weak self] text in
            self?.enqueue(text)
        }
    }

    // MARK: - Public API

    /// Push a delta from ``assistant.delta``.
    public func pushDelta(_ delta: String, emotion: Emotion? = nil) {
        guard isEnabled, !delta.isEmpty else { return }
        if let emotion = emotion { currentEmotion = emotion }
        chunker.push(delta)
    }

    /// Signal the assistant turn is complete. Flushes the chunker so any
    /// trailing text gets spoken. Pass ``finalText`` to play the
    /// authoritative content when no deltas were received.
    public func finishTurn(finalText: String? = nil, emotion: Emotion? = nil) {
        guard isEnabled else { return }
        if let emotion = emotion { currentEmotion = emotion }
        if let finalText = finalText, queue.isEmpty, !isSpeaking, !isDraining {
            chunker.reset()
            enqueue(SentenceChunker.sanitizeForSpeech(finalText))
        } else {
            chunker.flush()
        }
    }

    /// Stop in-flight playback and clear pending chunks.
    public func stop() {
        queue.removeAll()
        chunker.reset()
        currentTask?.cancel()
        currentTask = nil
        provider.cancel()
        setSpeaking(false)
    }

    /// Clear emotion + buffer at the start of a new assistant turn.
    /// Does not stop in-flight playback — call ``stop()`` for that.
    public func reset() {
        currentEmotion = nil
        chunker.reset()
    }

    /// Toggle speech on/off. Disabling stops any current playback.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { stop() }
    }

    // MARK: - Internals

    private func enqueue(_ text: String) {
        guard !text.isEmpty else { return }
        queue.append(text)
        if !isDraining { drain() }
    }

    private func drain() {
        isDraining = true
        currentTask = Task { [weak self] in
            await self?.runDrainLoop()
        }
    }

    private func runDrainLoop() async {
        while !queue.isEmpty {
            let text = queue.removeFirst()
            setSpeaking(true)
            let opts = TTSSpeakOptions(emotion: currentEmotion)
            do {
                try Task.checkCancellation()
                try await provider.speak(text, options: opts)
            } catch is CancellationError {
                // Cooperative cancel — drop the rest of the queue and exit.
                queue.removeAll()
                break
            } catch {
                // Non-cancel error: drop the queue so the user isn't bombarded
                // by stale audio after recovery, but keep the controller
                // usable for the next turn.
                #if DEBUG
                print("[VoiceController] speak failed: \(error)")
                #endif
                queue.removeAll()
                break
            }
        }
        setSpeaking(false)
        isDraining = false
        currentTask = nil
    }

    private func setSpeaking(_ value: Bool) {
        if isSpeaking != value { isSpeaking = value }
    }
}
