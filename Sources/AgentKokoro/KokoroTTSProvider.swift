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

/// Timing of one ``KokoroTTSProvider/speak(_:options:)`` that Kokoro spoke.
/// Content-free: safe to log or report.
public struct KokoroSpeechMetrics: Equatable, Sendable {
    /// Milliseconds spent loading the model or a language's G2P for this
    /// utterance (0 when it was already loaded).
    public var loadMs: Double
    /// Milliseconds from `speak()` to the first audio buffer scheduled.
    public var firstAudioMs: Double
    /// Model runs (chunks) for this utterance.
    public var chunkCount: Int
    /// Seconds of audio produced.
    public var audioSeconds: Double
    /// Seconds spent in G2P and the model.
    public var synthSeconds: Double

    /// Audio seconds per synthesis second (> 1 is faster than real time).
    public var realTimeFactor: Double { synthSeconds > 0 ? audioSeconds / synthSeconds : 0 }

    public init(loadMs: Double, firstAudioMs: Double, chunkCount: Int, audioSeconds: Double, synthSeconds: Double) {
        self.loadMs = loadMs
        self.firstAudioMs = firstAudioMs
        self.chunkCount = chunkCount
        self.audioSeconds = audioSeconds
        self.synthSeconds = synthSeconds
    }
}

/// On-device neural TTS with Kokoro-82M v1.0 on ONNX Runtime.
///
/// Plugs into ``VoiceController`` like any other ``TTSProvider``: each
/// sentence chunk the controller hands over is turned into phonemes by our
/// G2P, synthesised on a background queue and streamed to the speaker as
/// soon as its first piece is ready, so chunks play in order and `stop()`
/// cuts audio and generation immediately. Chunks queued behind the one
/// playing are synthesised ahead (``prefetch(_:options:)``) so there is no
/// pause between them. Text never leaves the device.
///
/// The model is not bundled: the first ``speak(_:options:)`` without it
/// starts a one-time download through ``KokoroModelManager`` (when
/// `autoDownload` is on) and that turn is spoken by the fallback voice.
/// If the engine fails, the turn also falls back — to
/// ``AVSpeechTTSProvider`` by default — and stays on it until the next
/// turn, so a reply never switches voices halfway through.
public final class KokoroTTSProvider: TTSProvider, @unchecked Sendable {
    public let name = KokoroTTS.engineId

    /// Voice used when ``TTSSpeakOptions/voiceId`` does not name a Kokoro voice.
    public let voice: KokoroVoice
    /// Speaking rate; 1.0 is Kokoro's natural pace.
    public let speed: Float
    public let modelManager: KokoroModelManager
    /// Whether speaking without the model starts its download.
    public let autoDownload: Bool

    /// Called on the main thread whenever an utterance falls back.
    public var onFallback: ((KokoroFallbackReason) -> Void)?
    /// Called on the main thread after each utterance Kokoro spoke.
    public var onSpeechMetrics: ((KokoroSpeechMetrics) -> Void)?

    private let fallback: TTSProvider?
    private let engineHost: KokoroEngineHost
    private let output: KokoroAudioOutput

    // Lock-protected.
    private let lock = NSLock()
    private var currentJob: SpeechJob?
    private var prefetched: [SynthesisTask] = []
    private var turnUsesFallback = false
    /// One automatic download attempt per turn, so a failing network (or
    /// cellular-only with ``KokoroConfiguration/allowsCellularDownload`` off)
    /// is not retried on every chunk.
    private var autoDownloadTried = false

    /// - Parameters:
    ///   - configuration: Voice and speed (``KokoroConfiguration/voice``,
    ///     ``KokoroConfiguration/speed``).
    ///   - modelManager: Where the model is downloaded and cached.
    ///   - fallback: Speaks when Kokoro cannot. Defaults to the system voice;
    ///     pass `nil` to surface failures to ``VoiceController`` instead.
    ///   - autoDownload: Start the model download on first use.
    public convenience init(configuration: KokoroConfiguration = KokoroConfiguration(),
                            modelManager: KokoroModelManager = .shared,
                            fallback: TTSProvider? = AVSpeechTTSProvider(),
                            autoDownload: Bool = true) {
        self.init(voice: KokoroVoice(id: configuration.voice) ?? .defaultVoice, speed: configuration.speed,
                  modelManager: modelManager, fallback: fallback, autoDownload: autoDownload,
                  engineHost: modelManager.engineHost, output: AVAudioEngineOutput())
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

        let voice = resolveVoice(options)
        guard modelManager.isDownloaded(voice: voice.id) else {
            if modelManager.currentState == .downloading {
                return try await speakWithFallback(trimmed, options: options, reason: .modelDownloading)
            }
            let shouldFetch = autoDownload && withLock { () -> Bool in
                defer { autoDownloadTried = true }
                return !autoDownloadTried
            }
            if shouldFetch { modelManager.prefetch(voice: voice.id) }
            return try await speakWithFallback(trimmed, options: options, reason: .modelNotDownloaded)
        }

        let task = takePrefetched(trimmed, voice: voice) ?? schedule(trimmed, voice: voice)
        let job = SpeechJob(task: task, output: output, startedAt: DispatchTime.now())
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
        reportMetrics(task: task, job: job)
    }

    /// Starts synthesising a chunk that is queued behind the one playing,
    /// so it is ready the moment ``speak(_:options:)`` asks for it.
    public func prefetch(_ text: String, options: TTSSpeakOptions) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = resolveVoice(options)
        guard !trimmed.isEmpty, Self.hasSpeakableContent(trimmed),
              !Self.containsUnsupportedScript(trimmed),
              modelManager.isDownloaded(voice: voice.id),
              !withLock({ turnUsesFallback }) else { return }
        let task = schedule(trimmed, voice: voice)
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
        KokoroVoice.descriptors()
    }

    /// Clears per-turn state and, when the voice is downloaded, loads the
    /// model in the background so the turn's first chunk does not pay for it.
    public func prepareForNewTurn() {
        let stale = withLock { () -> [SynthesisTask] in
            turnUsesFallback = false
            autoDownloadTried = false
            defer { prefetched = [] }
            return prefetched
        }
        stale.forEach { $0.cancel() }
        if let files = modelManager.assetFiles(voice: voice.id) {
            let host = engineHost, revision = modelManager.revision
            host.queue.async { _ = try? host.engine(for: files, revision: revision) }
        }
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
        let files = modelManager.assetFiles(voice: voice.id)
        let revision = modelManager.revision
        let speed = self.speed
        let host = engineHost
        host.queue.async {
            guard !task.isCancelled else {
                task.complete(CancellationError())
                return
            }
            let engine: KokoroSynthesisEngine
            do {
                guard let files else { throw KokoroEngineError.loadFailed }
                let (loaded, loadMs) = try host.engine(for: files, revision: revision)
                engine = loaded
                task.loadMs = loadMs
                if loadMs > 0 { AgentLog.debug(.voice, "[Kokoro] model loaded in \(Int(loadMs)) ms") }
            } catch {
                task.complete(SpeakFailure(reason: .engineLoadFailed))
                return
            }
            task.start(sampleRate: engine.sampleRate)
            do {
                task.stats = try engine.synthesize(text, voice: voice, speed: speed) { samples in
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
        task.attach { samples in
            job.markFirstAudio()
            output.enqueue(samples)
        }
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

    private func reportMetrics(task: SynthesisTask, job: SpeechJob) {
        guard let firstAudio = job.firstAudioMs, let stats = task.stats else { return }
        let metrics = KokoroSpeechMetrics(
            loadMs: task.loadMs, firstAudioMs: firstAudio, chunkCount: stats.chunkCount,
            audioSeconds: Double(stats.audioSamples) / 24_000, synthSeconds: stats.synthSeconds)
        AgentLog.debug(.voice, String(format: "[Kokoro] first audio %.0f ms (load %.0f ms), %d chunks, %.2f s audio in %.2f s",
                                      metrics.firstAudioMs, metrics.loadMs, metrics.chunkCount,
                                      metrics.audioSeconds, metrics.synthSeconds))
        guard let onSpeechMetrics else { return }
        DispatchQueue.main.async { onSpeechMetrics(metrics) }
    }

    private func notifyFallback(_ reason: KokoroFallbackReason) {
        guard let onFallback else { return }
        DispatchQueue.main.async { onFallback(reason) }
    }

    // MARK: - Helpers

    static func hasSpeakableContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// The English G2P cannot read these scripts (it would drop them or
    /// guess letter by letter); the system voice can.
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
    private let startedAt: DispatchTime
    private var firstAudio: DispatchTime?

    init(task: SynthesisTask, output: KokoroAudioOutput, startedAt: DispatchTime) {
        self.task = task
        self.output = output
        self.startedAt = startedAt
    }

    /// Records the moment the first buffer is handed to the speaker.
    func markFirstAudio() {
        lock.lock()
        if firstAudio == nil { firstAudio = DispatchTime.now() }
        lock.unlock()
    }

    /// Milliseconds from `speak()` to the first buffer scheduled.
    var firstAudioMs: Double? {
        lock.lock(); defer { lock.unlock() }
        guard let firstAudio else { return nil }
        return Double(firstAudio.uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1e6
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
    /// Set on the worker before ``complete(_:)``; read after it.
    var loadMs: Double = 0
    var stats: KokoroSynthesisStats?

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
