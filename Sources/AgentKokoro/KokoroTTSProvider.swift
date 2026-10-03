import Foundation
import AVFoundation
import AgentClient

/// Why a Kokoro utterance was spoken by the fallback (system) voice
/// instead. Content-free by construction: safe to log or report.
public enum KokoroFallbackReason: String, Sendable {
    /// The model is not on the device yet (a download may have started).
    case modelNotDownloaded = "model-not-downloaded"
    /// The model is being downloaded.
    case modelDownloading = "model-downloading"
    /// The installed model could not be loaded.
    case engineLoadFailed = "engine-load-failed"
    /// The engine failed to synthesise a chunk.
    case synthesisFailed = "synthesis-failed"
    /// Audio output could not be started.
    case audioOutputFailed = "audio-output-failed"
    /// The chunk is in a script the English voices cannot read (e.g. CJK).
    case unsupportedText = "unsupported-text"
    /// An earlier chunk of this turn fell back; the rest of the turn stays
    /// on the same voice rather than switching mid-reply.
    case earlierChunkFellBack = "earlier-chunk-fell-back"
}

/// Errors ``KokoroTTSProvider`` surfaces only when it has no fallback.
public enum KokoroTTSError: Error, LocalizedError {
    case unavailable(KokoroFallbackReason)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(reason): return "On-device Kokoro voice unavailable (\(reason.rawValue))"
        }
    }
}

/// On-device neural TTS with Kokoro-82M.
///
/// Plugs into ``VoiceController`` like any other ``TTSProvider``: each
/// sentence chunk the controller hands over is synthesised on a background
/// queue and streamed to the speaker as soon as its first sentence is
/// ready, so chunks play in order and `stop()` cuts audio and generation
/// immediately. Chunks queued behind the one playing are synthesised ahead
/// (``prefetch(_:options:)``) so there is no pause between them. Text
/// never leaves the device.
///
/// The model is not bundled: the first ``speak(_:options:)`` without it
/// starts a one-time download through ``KokoroModelManager`` (when
/// `autoDownload` is on) and that turn is spoken by the fallback voice.
/// If the engine fails, the turn also falls back — to
/// ``AVSpeechTTSProvider`` by default — and stays on it until the next
/// turn, so a reply never switches voices halfway through.
public final class KokoroTTSProvider: TTSProvider, @unchecked Sendable {
    public let name = "kokoro"

    /// Voice used when ``TTSSpeakOptions/voiceId`` does not name a Kokoro voice.
    public let voice: KokoroVoice
    /// Speaking rate; 1.0 is Kokoro's natural pace.
    public let speed: Float
    public let modelManager: KokoroModelManager
    /// Whether speaking without the model starts its download.
    public let autoDownload: Bool

    /// Called on the main thread whenever an utterance falls back.
    public var onFallback: ((KokoroFallbackReason) -> Void)?

    private let fallback: TTSProvider?
    private let engineHost: KokoroEngineHost
    private let output: KokoroAudioOutput

    // Lock-protected.
    private let lock = NSLock()
    private var currentJob: SpeechJob?
    private var prefetched: [SynthesisTask] = []
    private var turnUsesFallback = false

    /// - Parameters:
    ///   - voice: Default Kokoro voice (``KokoroVoice/defaultVoice``, `af_heart`).
    ///   - speed: Speaking rate, 0.5–2.0.
    ///   - modelManager: Where the model is downloaded and cached.
    ///   - fallback: Speaks when Kokoro cannot. Defaults to the system voice;
    ///     pass `nil` to surface failures to ``VoiceController`` instead.
    ///   - autoDownload: Start the model download on first use.
    public convenience init(voice: KokoroVoice = .defaultVoice,
                            speed: Float = 1.0,
                            modelManager: KokoroModelManager = .shared,
                            fallback: TTSProvider? = AVSpeechTTSProvider(),
                            autoDownload: Bool = true) {
        self.init(voice: voice, speed: speed, modelManager: modelManager, fallback: fallback,
                  autoDownload: autoDownload, engineHost: .shared, output: AVAudioEngineOutput())
    }

    /// Test seam: a private engine host around `engineLoader`.
    convenience init(voice: KokoroVoice, speed: Float, modelManager: KokoroModelManager, fallback: TTSProvider?,
                     autoDownload: Bool, engineLoader: KokoroEngineLoading, output: KokoroAudioOutput) {
        self.init(voice: voice, speed: speed, modelManager: modelManager, fallback: fallback,
                  autoDownload: autoDownload, engineHost: KokoroEngineHost(loader: engineLoader), output: output)
    }

    init(voice: KokoroVoice, speed: Float, modelManager: KokoroModelManager, fallback: TTSProvider?,
         autoDownload: Bool, engineHost: KokoroEngineHost, output: KokoroAudioOutput) {
        self.voice = voice
        self.speed = min(max(speed, 0.5), 2.0)
        self.modelManager = modelManager
        self.fallback = fallback
        self.autoDownload = autoDownload
        self.engineHost = engineHost
        self.output = output
    }

    // MARK: - TTSProvider

    public func speak(_ text: String, options: TTSSpeakOptions) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try Task.checkCancellation()
        // A chunk may arrive after the host has opened live voice.
        let owner = await MainActor.run { AudioSessionCoordinator.owner }
        guard owner != .liveVoice else { throw CancellationError() }

        if withLock({ turnUsesFallback }) {
            return try await speakWithFallback(trimmed, options: options, reason: .earlierChunkFellBack)
        }
        guard Self.hasSpeakableContent(trimmed) else {
            return // punctuation or symbols only: nothing to say
        }
        if Self.containsUnsupportedScript(trimmed) {
            return try await speakWithFallback(trimmed, options: options, reason: .unsupportedText)
        }

        switch modelManager.currentState {
        case .ready:
            break
        case .downloading:
            return try await speakWithFallback(trimmed, options: options, reason: .modelDownloading)
        case .notDownloaded, .failed:
            if autoDownload { modelManager.startDownloadIfNeeded() }
            return try await speakWithFallback(trimmed, options: options, reason: .modelNotDownloaded)
        }

        let voice = resolveVoice(options)
        let task = takePrefetched(trimmed, voice: voice) ?? schedule(trimmed, voice: voice)
        let job = SpeechJob(task: task, output: output)
        withLock { currentJob = job }
        defer { withLock { if currentJob === job { currentJob = nil } } }

        do {
            try await withTaskCancellationHandler {
                try await play(task, job: job)
            } onCancel: {
                job.cancel()
            }
        } catch let failure as SpeakFailure {
            if job.isCancelled { throw CancellationError() }
            // Stay on one voice for the rest of the turn.
            let stale = withLock { () -> [SynthesisTask] in
                turnUsesFallback = true
                defer { prefetched = [] }
                return prefetched
            }
            stale.forEach { $0.cancel() }
            AgentLog.error("[Kokoro] falling back to the system voice: \(failure.reason.rawValue)")
            // If part of the chunk was already heard, don't repeat it —
            // let what was synthesised finish, so the next chunk's
            // fallback voice doesn't talk over it.
            if task.hasDelivered {
                notifyFallback(failure.reason)
                try await output.finish()
                return
            }
            return try await speakWithFallback(trimmed, options: options, reason: failure.reason, logged: true)
        }
        if job.isCancelled { throw CancellationError() }
    }

    /// Starts synthesising a chunk that is queued behind the one playing,
    /// so it is ready the moment ``speak(_:options:)`` asks for it.
    public func prefetch(_ text: String, options: TTSSpeakOptions) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Self.hasSpeakableContent(trimmed),
              !Self.containsUnsupportedScript(trimmed),
              modelManager.isInstalled,
              !withLock({ turnUsesFallback }) else { return }
        let task = schedule(trimmed, voice: resolveVoice(options))
        withLock { prefetched.append(task) }
    }

    public func cancel() {
        let (job, stale) = withLock { () -> (SpeechJob?, [SynthesisTask]) in
            turnUsesFallback = false
            defer { prefetched = [] }
            return (currentJob, prefetched)
        }
        stale.forEach { $0.cancel() }
        job?.cancel()
        fallback?.cancel()
    }

    public func listVoices() async throws -> [VoiceDescriptor] {
        KokoroVoice.descriptors
    }

    public func prepareForNewTurn() {
        let stale = withLock { () -> [SynthesisTask] in
            turnUsesFallback = false
            defer { prefetched = [] }
            return prefetched
        }
        stale.forEach { $0.cancel() }
    }

    // MARK: - Synthesis

    struct SpeakFailure: Error {
        let reason: KokoroFallbackReason
    }

    private func resolveVoice(_ options: TTSSpeakOptions) -> KokoroVoice {
        options.voiceId.flatMap(KokoroVoice.init(id:)) ?? voice
    }

    /// The prefetched task for this chunk, if there is one. Prefetches
    /// queued before it were for chunks that will never be asked for.
    private func takePrefetched(_ text: String, voice: KokoroVoice) -> SynthesisTask? {
        let (match, skipped) = withLock { () -> (SynthesisTask?, [SynthesisTask]) in
            guard let index = prefetched.firstIndex(where: { $0.text == text && $0.voice == voice }) else {
                return (nil, [])
            }
            let skipped = Array(prefetched[..<index])
            let match = prefetched[index]
            prefetched.removeFirst(index + 1)
            return (match, skipped)
        }
        skipped.forEach { $0.cancel() }
        return match
    }

    /// Queues synthesis of `text` on the worker.
    private func schedule(_ text: String, voice: KokoroVoice) -> SynthesisTask {
        let task = SynthesisTask(text: text, voice: voice)
        let key = KokoroEngineHost.Key(directory: modelManager.modelDirectory, accent: voice.accent,
                                       revision: modelManager.revision)
        let speed = self.speed
        let host = engineHost
        host.queue.async {
            guard !task.isCancelled else {
                task.complete(CancellationError())
                return
            }
            let engine: KokoroSynthesisEngine
            do {
                engine = try host.engine(for: key)
            } catch {
                task.complete(SpeakFailure(reason: .engineLoadFailed))
                return
            }
            task.start(sampleRate: engine.sampleRate)
            do {
                try engine.synthesize(text, speakerId: voice.speakerId, speed: speed) { samples in
                    task.append(samples)
                }
            } catch {
                task.complete(task.isCancelled ? CancellationError() : SpeakFailure(reason: .synthesisFailed))
                return
            }
            if task.isCancelled {
                task.complete(CancellationError())
            } else {
                task.complete(task.hasProduced ? nil : SpeakFailure(reason: .synthesisFailed))
            }
        }
        return task
    }

    /// Streams a synthesis task to the speaker and waits for it to play.
    private func play(_ task: SynthesisTask, job: SpeechJob) async throws {
        let sampleRate = try await task.awaitSampleRate()
        if job.isCancelled { throw CancellationError() }

        await MainActor.run { Self.configurePlaybackSession() }
        if job.isCancelled { throw CancellationError() }
        do {
            try output.begin(sampleRate: sampleRate)
        } catch {
            task.cancel()
            throw SpeakFailure(reason: .audioOutputFailed)
        }
        // Audio produced so far plays at once; the rest follows as each
        // sentence is synthesised.
        let output = self.output
        task.attach { samples in output.enqueue(samples) }
        try await task.awaitCompletion()
        if job.isCancelled { throw CancellationError() }
        try await output.finish()
    }

    // MARK: - Fallback

    private func speakWithFallback(_ text: String, options: TTSSpeakOptions,
                                   reason: KokoroFallbackReason, logged: Bool = false) async throws {
        withLock { turnUsesFallback = true }
        if !logged {
            switch reason {
            case .modelNotDownloaded, .modelDownloading, .earlierChunkFellBack:
                AgentLog.debug(.voice, "[Kokoro] system voice for this chunk: \(reason.rawValue)")
            default:
                AgentLog.error("[Kokoro] falling back to the system voice: \(reason.rawValue)")
            }
        }
        notifyFallback(reason)
        guard let fallback else { throw KokoroTTSError.unavailable(reason) }
        // A Kokoro voice id means nothing to the fallback engine.
        var fallbackOptions = options
        fallbackOptions.voiceId = nil
        try await fallback.speak(text, options: fallbackOptions)
    }

    private func notifyFallback(_ reason: KokoroFallbackReason) {
        guard let onFallback else { return }
        DispatchQueue.main.async { onFallback(reason) }
    }

    // MARK: - Helpers

    static func hasSpeakableContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// The English voices have no lexicon for these scripts; espeak would
    /// read them as letter names at best.
    static func containsUnsupportedScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, // Hiragana, Katakana
                 0x3400...0x4DBF, // CJK Extension A
                 0x4E00...0x9FFF, // CJK Unified Ideographs
                 0xAC00...0xD7AF, // Hangul
                 0xF900...0xFAFF: // CJK Compatibility
                return true
            default:
                return false
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// Mirrors ``ElevenLabsTTSProvider``: `.playback`/`.spokenAudio` for
    /// media-level loudness and A2DP, but only while nothing else (a
    /// hands-free conversation) has claimed the session. See
    /// ``AudioSessionCoordinator``.
    @MainActor
    private static func configurePlaybackSession() {
        #if os(iOS)
        guard AudioSessionCoordinator.owner == .unclaimed else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playback || session.mode != .spokenAudio {
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            }
            try session.setActive(true, options: [])
        } catch {
            AgentLog.error("[Kokoro] AVAudioSession setup failed: \(type(of: error))")
        }
        #endif
    }
}

/// The utterance currently being spoken, so `cancel()` can reach it.
final class SpeechJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let task: SynthesisTask
    private let output: KokoroAudioOutput

    init(task: SynthesisTask, output: KokoroAudioOutput) {
        self.task = task
        self.output = output
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        let wasCancelled = cancelled
        cancelled = true
        lock.unlock()
        guard !wasCancelled else { return }
        task.cancel()
        output.stop()
    }
}

/// One chunk's synthesis, which may start before anyone listens to it
/// (a prefetch). Audio produced before ``attach(_:)`` is buffered, then
/// handed over in order; later audio goes straight to the sink.
final class SynthesisTask: @unchecked Sendable {
    let text: String
    let voice: KokoroVoice

    private let lock = NSLock()
    private var sampleRate: Int?
    private var buffered: [[Float]] = []
    private var sink: (([Float]) -> Void)?
    private var produced = false
    private var delivered = false
    private var finished = false
    private var failure: Error?
    private var cancelled = false
    private var rateWaiters: [CheckedContinuation<Int, Error>] = []
    private var completionWaiters: [CheckedContinuation<Void, Error>] = []

    init(text: String, voice: KokoroVoice) {
        self.text = text
        self.voice = voice
    }

    var isCancelled: Bool { locked { cancelled } }
    /// Whether the engine produced any audio.
    var hasProduced: Bool { locked { produced } }
    /// Whether any audio reached the speaker.
    var hasDelivered: Bool { locked { delivered } }

    // Producer (worker) side.

    func start(sampleRate rate: Int) {
        let waiters: [CheckedContinuation<Int, Error>] = locked {
            sampleRate = rate
            defer { rateWaiters = [] }
            return rateWaiters
        }
        waiters.forEach { $0.resume(returning: rate) }
    }

    /// Returns `false` once cancelled, which stops the engine.
    func append(_ samples: [Float]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        guard !samples.isEmpty else { return true }
        produced = true
        if let sink {
            // Called under the lock so buffered and live audio can't interleave.
            delivered = true
            sink(samples)
        } else {
            buffered.append(samples)
        }
        return true
    }

    func complete(_ error: Error?) {
        let (rateWaiters, completionWaiters, outcome) = locked { () -> ([CheckedContinuation<Int, Error>], [CheckedContinuation<Void, Error>], Error?) in
            if !finished {
                finished = true
                failure = cancelled ? CancellationError() : error
            }
            defer { self.rateWaiters = []; self.completionWaiters = [] }
            return (self.rateWaiters, self.completionWaiters, failure)
        }
        let rateError = outcome ?? KokoroEngineError.synthesisFailed
        rateWaiters.forEach { $0.resume(throwing: rateError) }
        completionWaiters.forEach { cont in
            if let outcome { cont.resume(throwing: outcome) } else { cont.resume() }
        }
    }

    func cancel() {
        locked { cancelled = true; buffered = []; sink = nil }
        complete(CancellationError())
    }

    // Consumer side.

    func awaitSampleRate() async throws -> Int {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            lock.lock()
            if let sampleRate {
                lock.unlock()
                cont.resume(returning: sampleRate)
            } else if finished {
                let error = failure ?? KokoroEngineError.synthesisFailed
                lock.unlock()
                cont.resume(throwing: error)
            } else {
                rateWaiters.append(cont)
                lock.unlock()
            }
        }
    }

    func attach(_ newSink: @escaping ([Float]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return }
        for samples in buffered {
            delivered = true
            newSink(samples)
        }
        buffered = []
        sink = newSink
    }

    func awaitCompletion() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if finished {
                let error = failure
                lock.unlock()
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            } else {
                completionWaiters.append(cont)
                lock.unlock()
            }
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
