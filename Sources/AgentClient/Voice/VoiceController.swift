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
    @Published public private(set) var voiceMode: VoiceMode
    /// Rolling window of recently-spoken agent text. Consumed by the
    /// iOS InputView's barge-in monitor to filter AEC leak-back: any
    /// transcription the recognizer produces while the agent is talking
    /// that's a near-match of this buffer is treated as the agent's own
    /// voice bleeding through, not a real interrupt.
    /// Capped to ``recentSpokenTextMaxChars`` characters.
    @Published public private(set) var recentSpokenText: String = ""

    /// Maximum length of ``recentSpokenText`` before old content is
    /// dropped from the front. ~1500 chars covers a few sentences which
    /// is enough lookback for the monitor's word-overlap check.
    private let recentSpokenTextMaxChars: Int = 1500

    private let provider: TTSProvider?
    private var queue: [String] = []
    private var isDraining: Bool = false
    /// Set when the TTS provider fails with a non-transient error (e.g.
    /// HTTP 403). Prevents the drain loop from restarting on subsequent
    /// enqueue calls, which would otherwise flicker `isSpeaking`
    /// true→false on every chunker emission for the rest of the turn.
    /// Cleared by `reset()` at the start of the next assistant turn.
    private var turnFailed: Bool = false
    private var currentTask: Task<Void, Never>?
    private var currentEmotion: Emotion?
    private var chunker: SentenceChunker!

    public init(provider: TTSProvider?, enabled: Bool = true,
                voiceMode: VoiceMode? = nil,
                minChars: Int = 40, maxChars: Int = 240) {
        self.provider = provider
        let resolvedMode = voiceMode ?? (provider == nil ? VoiceMode.disabled : .local)
        let resolvedModeCanEnable: Bool
        switch resolvedMode {
        case .remote, .local: resolvedModeCanEnable = true
        case .unavailable, .disabled: resolvedModeCanEnable = false
        }
        self.voiceMode = resolvedMode
        self.isEnabled = enabled && provider != nil && resolvedModeCanEnable
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
        turnFailed = false
        currentTask?.cancel()
        currentTask = nil
        provider?.cancel()
        setSpeaking(false)
        // Wipe the leak-back filter buffer so the next turn starts fresh.
        recentSpokenText = ""
    }

    /// Clear emotion + buffer at the start of a new assistant turn.
    /// Does not stop in-flight playback — call ``stop()`` for that.
    public func reset() {
        currentEmotion = nil
        turnFailed = false
        chunker.reset()
        recentSpokenText = ""
    }

    /// Toggle speech on/off. Disabling stops any current playback.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled && provider != nil && Self.canEnable(voiceMode)
        if !enabled { stop() }
    }

    // MARK: - Internals

    private func enqueue(_ text: String) {
        guard !text.isEmpty, !turnFailed else { return }
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
            // Append to leak-back filter buffer *before* play starts so
            // the InputView monitor already has the text by the time the
            // first audio frame leaks into the mic.
            appendRecentSpoken(text)
            guard let provider = provider else {
                queue.removeAll()
                break
            }
            let opts = TTSSpeakOptions(emotion: currentEmotion)
            do {
                try Task.checkCancellation()
                try await provider.speak(text, options: opts)
            } catch is CancellationError {
                // Cooperative cancel — drop the rest of the queue and exit.
                queue.removeAll()
                break
            } catch {
                // Non-cancel error (e.g. TTS proxy 403): mark the turn as
                // failed so subsequent enqueue calls are no-ops. Without
                // this, each chunker emission restarts the drain loop,
                // flickers isSpeaking true→false, and causes the presence
                // orb and layout to jitter. The flag is cleared by reset()
                // at the start of the next assistant turn.
                #if DEBUG
                print("[VoiceController] speak failed: \(error)")
                #endif
                turnFailed = true
                voiceMode = .unavailable(reason: error.localizedDescription)
                isEnabled = false
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

    /// Append a freshly-queued sentence to the rolling agent-text
    /// buffer. Trims from the front when the cap is exceeded.
    private func appendRecentSpoken(_ text: String) {
        var joined = recentSpokenText
        if !joined.isEmpty { joined += " " }
        joined += text
        if joined.count > recentSpokenTextMaxChars {
            joined = String(joined.suffix(recentSpokenTextMaxChars))
        }
        recentSpokenText = joined
    }

    private static func canEnable(_ mode: VoiceMode) -> Bool {
        switch mode {
        case .remote, .local: return true
        case .unavailable, .disabled: return false
        }
    }
}
