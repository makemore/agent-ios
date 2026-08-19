import AVFoundation
import Foundation
import WhisperKit
import AgentClient

/// One dictation utterance transcribed on-device by WhisperKit.
///
/// Owned by ``DictationEngine`` when the host config selects the
/// `.whisper` backend. The engine keeps ownership of the audio session,
/// the `AVAudioEngine` tap, and level metering — this class only receives
/// the tap's buffers via ``append(_:)``, resamples them to Whisper's
/// 16 kHz mono format, and turns the accumulated audio into text.
///
/// Whisper has no streaming decoder, so "partials" are emulated: a loop
/// re-transcribes the whole accumulated buffer roughly once a second and
/// delivers the result through ``onTranscript``. Each pass replaces the
/// previous text (cumulative-transcript semantics, matching what
/// `SFSpeechRecognizer` partials give the views). ``finish()`` runs one
/// last full pass so the tail of speech recorded after the final loop
/// tick isn't lost; ``cancel()`` discards everything and guarantees no
/// further delivery.
///
/// `append(_:)` is called on the realtime audio thread; everything else
/// must be called on the main queue. Transcripts are delivered on the
/// main queue.
final class WhisperDictationSession {

    /// Cumulative transcript callback, main queue. Set before ``begin()``.
    var onTranscript: ((String) -> Void)?
    /// Fired once on the main queue when ``finish()``'s final pass is
    /// done — after the delivery if there was one, and on every abort
    /// path if there wasn't. Lets the owner clear "transcribing…" UI.
    var onFinished: (() -> Void)?

    private let model: String

    /// Accumulated 16 kHz mono samples. Locked: written by the audio
    /// thread, snapshotted by transcription tasks.
    private var samples: [Float] = []
    private let samplesLock = NSLock()

    /// Created lazily from the first buffer's format, then reused —
    /// a converter carries resampler state between buffers. Audio-thread
    /// only.
    private var converter: AVAudioConverter?

    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private var partialLoop: Task<Void, Never>?
    /// Set by ``cancel()``. Read/written on the main queue only;
    /// ``deliver(_:)`` hops to main before checking it, which is what
    /// makes a post-cancel delivery impossible.
    private var cancelled = false

    /// Don't bother Whisper with less than half a second of audio — the
    /// model hallucinates filler ("Thank you.") on near-empty input.
    private static let minSampleCount = 8_000

    init(model: String) {
        self.model = model
    }

    // MARK: - Shared pipeline cache

    /// Model loading takes seconds (plus a download on first ever use),
    /// so pipelines are shared across sessions and kept for the app's
    /// lifetime. Keyed by model name.
    private static var pipelines: [String: Task<WhisperKit, Error>] = [:]
    private static let pipelinesLock = NSLock()

    /// Kick off model load/download without starting a session, so the
    /// first tap of the mic isn't cold. Safe to call repeatedly.
    static func preload(model: String) {
        _ = pipeline(for: model)
    }

    private static func pipeline(for model: String) -> Task<WhisperKit, Error> {
        pipelinesLock.lock()
        defer { pipelinesLock.unlock() }
        if let existing = pipelines[model] { return existing }
        AgentLog.debug(.input, "[Whisper] loading model \(model)")
        let task = Task {
            try await WhisperKit(WhisperKitConfig(model: model))
        }
        pipelines[model] = task
        return task
    }

    /// A failed load (e.g. first-run download with no network) is evicted
    /// so the next session retries instead of failing forever.
    private static func evictPipeline(for model: String) {
        pipelinesLock.lock()
        pipelines[model] = nil
        pipelinesLock.unlock()
    }

    // MARK: - Session lifecycle

    /// Starts the partial-transcription loop. Audio can begin arriving
    /// via ``append(_:)`` immediately — even before the model has
    /// loaded, nothing is dropped; transcription just starts late.
    func begin() {
        Self.preload(model: model)
        partialLoop = Task { [weak self] in
            guard let self else { return }
            let whisper: WhisperKit
            do {
                whisper = try await Self.pipeline(for: self.model).value
            } catch {
                AgentLog.error("[Whisper] model load failed: \(error)")
                Self.evictPipeline(for: self.model)
                return
            }
            AgentLog.debug(.input, "[Whisper] model ready, partial loop running")
            var lastCount = 0
            var lastText = ""
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                let snapshot = self.snapshotSamples()
                // Skip if no new audio landed since the last pass, or
                // there isn't enough yet to transcribe sensibly.
                guard snapshot.count != lastCount,
                      snapshot.count >= Self.minSampleCount else { continue }
                lastCount = snapshot.count
                let text = await Self.transcribe(snapshot, with: whisper)
                AgentLog.debug(.input, "[Whisper] partial pass: samples=\(snapshot.count) text=\(text.map { "\"\($0.prefix(60))\"" } ?? "nil")")
                guard let text, !text.isEmpty, text != lastText else { continue }
                lastText = text
                self.deliver(text)
            }
            AgentLog.debug(.input, "[Whisper] partial loop exited")
        }
    }

    /// Debug: set once so the first buffer and first failure each log
    /// exactly once instead of spamming from the audio thread.
    private var loggedFirstBuffer = false
    private var loggedConversionFailure = false

    /// Called on the realtime audio thread with each tap buffer.
    func append(_ buffer: AVAudioPCMBuffer) {
        if converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: Self.targetFormat)
        }
        if !loggedFirstBuffer {
            loggedFirstBuffer = true
            if converter == nil {
                AgentLog.error("[Whisper] audio converter creation failed for \(buffer.format.sampleRate)Hz/\(buffer.format.channelCount)ch")
            } else {
                AgentLog.debug(.input, "[Whisper] first buffer: \(buffer.format.sampleRate)Hz/\(buffer.format.channelCount)ch")
            }
        }
        guard let converter else { return }
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil,
              out.frameLength > 0, let channel = out.floatChannelData else {
            if !loggedConversionFailure {
                loggedConversionFailure = true
                AgentLog.error("[Whisper] sample conversion failed: status=\(status.rawValue) error=\(String(describing: conversionError))")
            }
            return
        }
        let converted = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        samplesLock.lock()
        samples.append(contentsOf: converted)
        samplesLock.unlock()
    }

    /// Ends the session keeping the transcript: stops the partial loop,
    /// then runs one final full-buffer pass so speech after the last
    /// loop tick still lands. The result arrives through ``onTranscript``
    /// asynchronously — callers that don't want it must use ``cancel()``.
    func finish() {
        AgentLog.debug(.input, "[Whisper] finish() entered: samples=\(snapshotSamples().count)")
        let loop = partialLoop
        partialLoop = nil
        loop?.cancel()
        Task {
            // Every exit path — delivered, aborted, or failed — must
            // release the owner's "transcribing…" state.
            defer {
                DispatchQueue.main.async { self.onFinished?() }
            }
            // Wait out any in-flight partial pass so the final delivery
            // can't be overwritten by a stale shorter transcript.
            _ = await loop?.value
            let alreadyCancelled = await MainActor.run { self.cancelled }
            guard !alreadyCancelled else { return }
            let snapshot = self.snapshotSamples()
            guard snapshot.count >= Self.minSampleCount else {
                AgentLog.debug(.input, "[Whisper] finish: only \(snapshot.count) samples, nothing to transcribe")
                return
            }
            guard let whisper = try? await Self.pipeline(for: self.model).value else {
                AgentLog.error("[Whisper] finish: model pipeline unavailable")
                return
            }
            let text = await Self.transcribe(snapshot, with: whisper)
            AgentLog.debug(.input, "[Whisper] finish: samples=\(snapshot.count) text=\(text.map { "\"\($0.prefix(80))\"" } ?? "nil")")
            guard let text, !text.isEmpty else { return }
            self.deliver(text)
        }
    }

    /// Ends the session discarding everything. After this returns (on
    /// the main queue) no transcript will be delivered.
    func cancel() {
        AgentLog.debug(.input, "[Whisper] cancel() — discarding session")
        cancelled = true
        onTranscript = nil
        partialLoop?.cancel()
        partialLoop = nil
    }

    // MARK: - Internals

    private func snapshotSamples() -> [Float] {
        samplesLock.lock()
        defer { samplesLock.unlock() }
        return samples
    }

    private func deliver(_ text: String) {
        DispatchQueue.main.async {
            guard !self.cancelled, let handler = self.onTranscript else {
                AgentLog.debug(.input, "[Whisper] delivery dropped (cancelled or no handler)")
                return
            }
            AgentLog.debug(.input, "[Whisper] delivering \(text.count) chars")
            handler(text)
        }
    }

    /// Non-speech events Whisper narrates instead of transcribing —
    /// `[BLANK_AUDIO]` above all, but also `[SILENCE]`, `(music)`,
    /// `[INAUDIBLE]` and friends.
    ///
    /// These are annotations from its training transcripts, not special
    /// tokens, so `skipSpecialTokens` leaves them alone and they arrive as
    /// ordinary text. In dictation that is never what the user meant to
    /// say: it belongs in a subtitle file, not in the message they are
    /// about to send. Hands-free makes it worse, because there the mic
    /// idles between turns with nothing but room tone to transcribe, and
    /// anything left in the field gets sent on the user's behalf.
    ///
    /// Only bracketed forms are stripped. Whisper reserves brackets and
    /// parentheses for these annotations, so dictated speech doesn't
    /// collide with them, and the vocabulary is enumerated rather than
    /// "anything in brackets" so genuinely dictated parentheses survive.
    private static let nonSpeechAnnotation: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"[\[\(]\s*(blank[\s_]*audio|silence|silent|no[\s_]*speech|inaudible|unintelligible|music|applause|laughter|laughs|laughing|coughs|coughing|sighs|clears throat|noise|static|beep|beeping|typing|clicking|breathing|footsteps|wind|sound\s*effects?|foreign(\s+language)?|speaking\s+in\s+foreign\s+language)\s*[\]\)][.,!?]?"#,
        options: [.caseInsensitive])

    /// Removes those annotations and tidies the whitespace they leave
    /// behind. A transcript that was nothing else comes back empty, which
    /// callers already treat as "nothing was said".
    static func stripNonSpeechAnnotations(_ text: String) -> String {
        guard let regex = nonSpeechAnnotation, !text.isEmpty else { return text }
        let cleaned = regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: " ")
        return cleaned
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func transcribe(_ audio: [Float], with whisper: WhisperKit) async -> String? {
        do {
            var options = DecodingOptions()
            options.task = .transcribe
            options.skipSpecialTokens = true
            options.withoutTimestamps = true
            options.temperature = 0
            let results = try await whisper.transcribe(audioArray: audio, decodeOptions: options)
            let joined = results.map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stripNonSpeechAnnotations(joined)
        } catch is CancellationError {
            // Expected: stop()/cancel() interrupts the in-flight partial
            // pass. Not an error, and the final pass follows it.
            return nil
        } catch {
            AgentLog.error("[Whisper] transcription failed: \(error)")
            return nil
        }
    }
}
