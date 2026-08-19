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

    /// Fires once per assistant turn, when the agent has genuinely
    /// finished talking.
    ///
    /// ``isSpeaking`` cannot answer that question. The drain loop lowers
    /// it whenever the queue runs dry, which during a streaming reply
    /// happens at every gap between sentence chunks — so a consumer
    /// watching for its falling edge sees several "finished"s per turn.
    /// Hands-free mode hands the mic back on this signal instead, which
    /// waits for ``finishTurn`` *and* an empty queue.
    ///
    /// Also fires on ``stop()``: an interrupted turn is still over.
    public let agentTurnDidEnd = PassthroughSubject<Void, Never>()

    /// Set by ``finishTurn`` — no more text is coming for this turn, so
    /// the next time the queue empties it is the end and not a gap.
    private var turnClosed: Bool = false

    /// Whether replies should be spoken as they stream, without anyone
    /// asking. Off by default: playback is otherwise started only by an
    /// explicit act — a message's speaker button, or a host injecting a
    /// scripted turn — and switching that on for every reply is a much
    /// bigger behaviour change than any one feature should make on its
    /// own. Hands-free conversation turns it on for the duration of the
    /// conversation, because a spoken reply is the whole point of it.
    @Published public var autoSpeakReplies: Bool = false

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

    /// Latches when the TTS backend proves unavailable (e.g. the voice
    /// token endpoint 404s because voice isn't configured on this
    /// deployment).
    ///
    /// Process-wide rather than per-instance because the controller is a
    /// `@StateObject` on `ChatWidgetView`, and that view is rebuilt whenever
    /// its identity changes — a new conversation, a config change. Each
    /// rebuild produced a fresh controller that started enabled and hit the
    /// dead endpoint again, so a backend without voice was re-probed on
    /// essentially every turn. One failure is enough; stop asking until the
    /// app restarts.
    private static var providerUnavailableThisSession = false
    private static var unavailableReason: String?

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
        self.voiceMode = Self.providerUnavailableThisSession ? .unavailable(reason: Self.unavailableReason ?? "Voice unavailable")
                                                             : resolvedMode
        self.isEnabled = enabled
            && provider != nil
            && resolvedModeCanEnable
            && !Self.providerUnavailableThisSession
        self.chunker = SentenceChunker(minChars: minChars, maxChars: maxChars) { [weak self] text in
            self?.enqueue(text)
        }
    }

    // MARK: - Public API

    /// Push a delta from ``assistant.delta``.
    public func pushDelta(_ delta: String, emotion: Emotion? = nil) {
        guard isEnabled, !delta.isEmpty else { return }
        if let emotion = emotion { currentEmotion = emotion }
        turnClosed = false
        chunker.push(delta)
    }

    /// Signal the assistant turn is complete. Flushes the chunker so any
    /// trailing text gets spoken. Pass ``finalText`` to play the
    /// authoritative content when no deltas were received.
    public func finishTurn(finalText: String? = nil, emotion: Emotion? = nil) {
        guard isEnabled else { return }
        if let emotion = emotion { currentEmotion = emotion }
        turnClosed = true
        if let finalText = finalText, queue.isEmpty, !isSpeaking, !isDraining {
            chunker.reset()
            enqueue(SentenceChunker.sanitizeForSpeech(finalText))
        } else {
            chunker.flush()
        }
        // A turn that produced no speakable text at all (empty reply, TTS
        // failed earlier in the turn, chunker had nothing buffered) never
        // enters the drain loop, so the end-of-turn signal has to come
        // from here or a hands-free caller would wait forever.
        if queue.isEmpty, !isDraining {
            endTurn()
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
        // An interrupted turn is over as far as any listener is concerned,
        // whether or not `finishTurn` ever ran. Closing it here also means
        // the drain loop — which may still be unwinding from the cancel —
        // finds the latch already spent and doesn't fire a second time.
        turnClosed = true
        endTurn()
    }

    /// Clear emotion + buffer at the start of a new assistant turn.
    /// Does not stop in-flight playback — call ``stop()`` for that.
    public func reset() {
        currentEmotion = nil
        turnFailed = false
        turnClosed = false
        chunker.reset()
        recentSpokenText = ""
    }

    /// Toggle speech on/off. Disabling stops any current playback.
    public func setEnabled(_ enabled: Bool) {
        // An explicit user tap clears the session latch — if they're turning
        // voice back on they're asking us to try again, perhaps because the
        // backend has since been fixed.
        if enabled {
            Self.providerUnavailableThisSession = false
            Self.unavailableReason = nil
            if case .unavailable = voiceMode, provider != nil {
                voiceMode = .local
            }
        }
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
                AgentLog.error("[VoiceController] speak failed: \(error)")
                #endif
                turnFailed = true
                // Latch for the whole process, not just this instance —
                // otherwise the next rebuilt controller retries the same
                // dead endpoint on the next turn.
                Self.providerUnavailableThisSession = true
                Self.unavailableReason = error.localizedDescription
                voiceMode = .unavailable(reason: error.localizedDescription)
                isEnabled = false
                queue.removeAll()
                break
            }
        }
        setSpeaking(false)
        isDraining = false
        currentTask = nil
        // Only a drained queue on a *closed* turn is the end of it. An
        // empty queue mid-stream is just the gap before the chunker emits
        // the next sentence.
        if turnClosed { endTurn() }
    }

    private func setSpeaking(_ value: Bool) {
        if isSpeaking != value { isSpeaking = value }
    }

    /// Announces the end of the turn, at most once per turn.
    private func endTurn() {
        guard turnClosed else { return }
        turnClosed = false
        agentTurnDidEnd.send()
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
