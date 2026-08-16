import AVFoundation
import Speech
import SwiftUI
import AgentClient

/// The dictation state machine, extracted from `InputView` so every
/// surface that offers a mic — the composer and the edit-message card —
/// drives the same audio-session handling, recognizer lifecycle, session
/// tokens, and failure caps instead of keeping a private copy of them.
///
/// One utterance session per `start()`/`stop()` pair. Partial results are
/// cumulative for the session and delivered through ``onTranscript`` on
/// the main queue; the caller owns any prefix-prepending (text that was
/// in the field before the mic started).
///
/// Two transcription backends, selected by `ChatWidgetConfig.dictationBackend`:
/// Apple's `SFSpeechRecognizer` (`.system`) or on-device Whisper via
/// WhisperKit (`.whisper`). The audio capture, level metering, session
/// tokens and view-facing surface are identical for both.
///
/// `stop()` and `cancel()` differ only for the Whisper backend: Whisper's
/// final transcription lands *after* teardown, so `stop()` keeps that
/// late delivery (review-and-edit flows) while `cancel()` suppresses it
/// (discard, send, dismiss — anywhere a late transcript would clobber
/// state the user has already moved past).
///
/// All public methods must be called on the main queue. `@Published`
/// properties are only mutated there.
final class DictationEngine: ObservableObject {

    @Published private(set) var isRecording = false
    /// True between a Whisper-backend `stop()` and its final transcript
    /// landing (or failing). The window is real — the final pass takes
    /// ~1–2 s — and without visible state it reads as "stop didn't
    /// transcribe". Always false for the system backend, whose partials
    /// are complete at stop time.
    @Published private(set) var isTranscribing = false
    /// Normalised (0...1) mic level for the waveform. Computed from the
    /// same buffers the recognizer receives — one tap on the input node,
    /// a second one would throw.
    @Published private(set) var audioLevel: CGFloat = 0

    /// Cumulative transcript of the current utterance, on the main queue.
    /// Reassigned freely by callers before each `start()`.
    var onTranscript: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    /// Monotonic token so late callbacks from a cancelled/superseded
    /// recognition task cannot deliver into a newer session. The task's
    /// result block can fire on the main queue *after* `cancel()` returns.
    private var sessionToken = 0
    /// Consecutive recognizer failures. Transient errors recycle the
    /// request; a failure that repeats immediately is permanent and
    /// recycling into it is an unbounded spin, so give up at the cap.
    private var failures = 0
    private let maxConsecutiveFailures = 3
    /// Captured at `start()` so recycles honour the same policy.
    private var policy: SpeechInputPolicy = .automatic
    /// Captured at `start()`; decides which teardown path `stop()` takes.
    private var backend: DictationBackend = .system
    /// Live only while a `.whisper` session is recording (and briefly
    /// after `stop()`, until its final pass delivers).
    private var whisperSession: WhisperDictationSession?

    // MARK: - Availability

    /// Kick off any slow backend preparation (Whisper model download /
    /// load) ahead of the first mic tap. No-op for the system backend;
    /// idempotent, so call it freely from `onAppear`.
    static func preload(config: ChatWidgetConfig) {
        if case .whisper(let model) = config.dictationBackend {
            WhisperDictationSession.preload(model: model)
        }
    }

    /// Whether a mic affordance should render at all.
    func isAvailable(config: ChatWidgetConfig) -> Bool {
        guard config.enableVoice else { return false }
        guard config.effectiveSpeechInputPolicy != .disabled else { return false }
        // A mic the user has switched off in Settings is a mic that does
        // not exist for this app: showing the button would only lead to a
        // dead tap. `.undetermined` still shows it — the permission
        // prompt fires on first use and that is how the user grants it
        // in the first place.
        #if os(iOS) && !targetEnvironment(simulator)
        if #available(iOS 17.0, *) {
            guard AVAudioApplication.shared.recordPermission != .denied else { return false }
        } else {
            guard AVAudioSession.sharedInstance().recordPermission != .denied else { return false }
        }
        #endif
        switch config.dictationBackend {
        case .whisper:
            // Whisper needs no speech-recognition permission and no
            // recognizer service — only the mic. It is fully on-device,
            // so every non-disabled SpeechInputPolicy (localOnly
            // included) is inherently satisfied. Works on the simulator
            // too (CoreML on CPU — slow, but real).
            return true
        case .system:
            #if targetEnvironment(simulator)
            // The simulator's SFSpeechRecognizer reports available=true
            // and then fails every recognition task it is asked to
            // start. No pre-check catches this — every health signal the
            // API exposes says yes — so system dictation is
            // simulator-off wholesale. Test it on hardware.
            return false
            #else
            #if os(iOS)
            let speechAuth = SFSpeechRecognizer.authorizationStatus()
            guard speechAuth != .denied, speechAuth != .restricted else { return false }
            #endif
            switch config.effectiveSpeechInputPolicy {
            case .disabled: return false
            case .localOnly:
                return recognizer?.supportsOnDeviceRecognition == true
            case .automatic, .remote:
                return recognizer?.isAvailable == true
            }
            #endif
        }
    }

    // MARK: - Session control

    func start(policy: SpeechInputPolicy, backend: DictationBackend = .system) {
        guard !isRecording else { return }
        self.policy = policy
        self.backend = backend
        failures = 0
        // A previous session's pending final pass no longer owns the
        // "transcribing" state once a new recording begins.
        isTranscribing = false

        switch backend {
        case .whisper(let model):
            requestMicPermission { granted in
                guard granted else { return }
                DispatchQueue.main.async {
                    self.beginWhisperSession(model: model)
                }
            }
        case .system:
            guard let recognizer = recognizer, recognizer.isAvailable else { return }
            SFSpeechRecognizer.requestAuthorization { status in
                guard status == .authorized else { return }
                DispatchQueue.main.async {
                    self.beginSession()
                }
            }
        }
    }

    /// Ends the session, keeping the transcript. For the Whisper backend
    /// one final transcription lands through ``onTranscript`` shortly
    /// after this returns — callers whose state must not change after
    /// stopping (send, discard, dismiss) use ``cancel()`` instead.
    func stop() {
        if case .whisper = backend, let session = whisperSession, isRecording {
            whisperSession = nil
            teardownAudio()
            // After teardown so the final pass sees every buffer the tap
            // delivered. The session outlives the engine's reference
            // until its delivery completes; `onFinished` clears this.
            isTranscribing = true
            session.finish()
            return
        }
        cancel()
    }

    /// Ends the session and guarantees nothing further is delivered.
    func cancel() {
        // Bump first so any callback that fires between cancel() and the
        // next runloop tick is filtered out by the token guard.
        sessionToken &+= 1
        whisperSession?.cancel()
        whisperSession = nil
        isTranscribing = false
        teardownAudio()
    }

    private func teardownAudio() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
        audioLevel = 0
    }

    // MARK: - Internals

    private func beginSession() {
        do {
            #if os(iOS)
            // Must match the category/mode used by the recycle path —
            // reconfiguring the session on every recycle makes the
            // simulator's audio device tear down mid-cycle and hands
            // back an invalid input format.
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord,
                                         mode: .default,
                                         options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            #endif

            // Install the recognition request + tap *before* starting the
            // engine. AVAudioEngine asserts that at least one node
            // connection exists at start time, and merely accessing
            // `inputNode` isn't enough on some iOS versions.
            guard installRecognitionRequest() else {
                stop()
                return
            }
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            AgentLog.error("[Dictation] start failed: \(error)")
            stop()
        }
    }

    // MARK: - Whisper backend

    private func beginWhisperSession(model: String) {
        do {
            #if os(iOS)
            // Same category/mode as the system path — the two backends
            // must be interchangeable without audio-session surprises.
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord,
                                         mode: .default,
                                         options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            #endif

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            // Same invalid-format rejection as the system path — a
            // mid-reconfiguration input node hands back 0 Hz / 0 ch.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                AgentLog.error("[Whisper] invalid input format (sampleRate=\(format.sampleRate) channels=\(format.channelCount))")
                return
            }

            let session = WhisperDictationSession(model: model)
            // Capture the handler by value: if a new dictation session
            // starts while this one's final pass is still running, the
            // late delivery goes to the closure (and prefix) it was
            // started with, not the new session's.
            let handler = onTranscript
            session.onTranscript = { text in handler?(text) }
            session.onFinished = { [weak self] in
                self?.isTranscribing = false
            }

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                session.append(buffer)
                let level = DictationEngine.normalisedLevel(from: buffer)
                DispatchQueue.main.async {
                    self?.audioLevel = level
                }
            }

            whisperSession = session
            session.begin()
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            AgentLog.error("[Whisper] start failed: \(error)")
            cancel()
        }
    }

    private func requestMicPermission(_ completion: @escaping (Bool) -> Void) {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                completion(granted)
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                completion(granted)
            }
        }
        #else
        completion(true)
        #endif
    }

    /// Installs a fresh recognition request, tap, and recognition task.
    /// Returns `false` if the recognizer is unusable so callers can abort
    /// cleanly. Does *not* start the audio engine.
    @discardableResult
    private func installRecognitionRequest() -> Bool {
        guard let recognizer = recognizer else {
            AgentLog.error("[Dictation] install: no recognizer")
            return false
        }
        guard recognizer.isAvailable else {
            AgentLog.error("[Dictation] install: recognizer unavailable")
            return false
        }
        AgentLog.debug(.input, "[Dictation] install (engineRunning=\(audioEngine.isRunning))")
        // Clear any previous request/tap so we don't double-install.
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if policy == .localOnly {
            guard recognizer.supportsOnDeviceRecognition else {
                AgentLog.error("[Dictation] install: on-device recognition unavailable")
                return false
            }
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request
        // "Failed to initialize recognizer" has several distinct causes
        // indistinguishable from the error alone: a forced on-device
        // request with no local model, an unsupported locale, or the
        // simulator's speech stack simply not working. Log what we asked
        // for.
        AgentLog.debug(.input, "[Dictation] recognizer: policy=\(policy) onDeviceRequired=\(request.requiresOnDeviceRecognition) onDeviceSupported=\(recognizer.supportsOnDeviceRecognition) locale=\(recognizer.locale.identifier) available=\(recognizer.isAvailable)")

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // A mid-reconfiguration input node reports a 0 Hz / 0-channel
        // format. Installing a tap with it throws, and the recognizer
        // then fails to initialize — reject it here so the caller aborts
        // rather than recycling into a request that cannot possibly work.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            AgentLog.error("[Dictation] install: invalid input format (sampleRate=\(format.sampleRate) channels=\(format.channelCount))")
            recognitionRequest = nil
            return false
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            // Same buffer, one extra pass — drives the waveform. Must hop
            // to main: this closure runs on a realtime audio thread.
            let level = DictationEngine.normalisedLevel(from: buffer)
            DispatchQueue.main.async {
                self?.audioLevel = level
            }
        }

        sessionToken &+= 1
        let token = sessionToken
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result = result {
                DispatchQueue.main.async {
                    guard let self = self, self.sessionToken == token else { return }
                    // A result means the pipeline is healthy again.
                    self.failures = 0
                    let transcribed = result.bestTranscription.formattedString
                    // The recognizer fires an empty first partial the
                    // moment recognition starts. Delivering it makes
                    // callers join their prefix to nothing — which is how
                    // a stray trailing space appeared in the field before
                    // the user had said a word. An empty transcript
                    // carries no information; don't deliver it.
                    guard !transcribed.isEmpty else { return }
                    self.onTranscript?(transcribed)
                }
            }
            if let error = error {
                DispatchQueue.main.async {
                    guard let self = self, self.sessionToken == token else { return }
                    guard self.isRecording else { return }
                    self.failures += 1
                    // Don't tear the whole mic down on a transient
                    // recognizer error — recycle and keep going.
                    if self.failures >= self.maxConsecutiveFailures {
                        AgentLog.error("[Dictation] recognition error: \(error.localizedDescription) — giving up after \(self.failures) attempts")
                        self.stop()
                    } else {
                        AgentLog.debug(.input, "[Dictation] recognition error: \(error.localizedDescription) — recycling (\(self.failures)/\(self.maxConsecutiveFailures))")
                        self.recycleRecognitionRequest()
                    }
                }
            }
        }
        return true
    }

    /// Cycles to a fresh recognition request. Restarts the engine if it
    /// got stopped by an audio session interruption (e.g. a phone call).
    private func recycleRecognitionRequest() {
        guard isRecording else {
            AgentLog.debug(.input, "[Dictation] recycle: not recording, skipping")
            return
        }
        if !audioEngine.isRunning {
            AgentLog.debug(.input, "[Dictation] recycle: engine stopped, restarting")
            #if os(iOS)
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord,
                                        mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
                try session.setActive(true, options: [])
            } catch {
                AgentLog.error("[Dictation] recycle: session reactivate failed: \(error)")
            }
            #endif
            // Install request first so the engine has a tap before start().
            guard installRecognitionRequest() else {
                AgentLog.error("[Dictation] recycle: install failed before engine start")
                return
            }
            do {
                audioEngine.prepare()
                try audioEngine.start()
                AgentLog.debug(.input, "[Dictation] recycle: engine restarted ok")
            } catch {
                AgentLog.error("[Dictation] recycle: engine start failed: \(error)")
            }
            return
        }
        installRecognitionRequest()
    }

    // MARK: - Level metering

    /// RMS of `buffer`, mapped through a dB curve into 0...1 for the
    /// waveform. Raw RMS is uselessly small for speech at conversational
    /// volume, so the linear value is converted to dBFS and the quietest
    /// `floorDB` of range is discarded.
    static func normalisedLevel(from buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var sumOfSquares: Float = 0
        for i in 0..<count {
            let sample = channel[i]
            sumOfSquares += sample * sample
        }
        let rms = sqrt(sumOfSquares / Float(count))
        guard rms > 0 else { return 0 }

        let floorDB: Float = -50
        let db = 20 * log10(rms)
        guard db > floorDB else { return 0 }
        return CGFloat(min(1, (db - floorDB) / -floorDB))
    }
}
