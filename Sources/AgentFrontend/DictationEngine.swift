import AVFoundation
import Speech
import SwiftUI
import AgentClient
#if os(iOS)
import UIKit
#endif

/// Main-queue permission handshake, independent of recognition-session tokens.
/// Injected callbacks make cancellation/duplicate delivery testable without OS IO.
final class DictationStartGate {
    enum Failure: Equatable { case microphoneDenied, speechDenied, inactive }
    typealias PermissionRequest = (@escaping (Bool) -> Void) -> Void
    private enum Stage { case microphone, speech }
    private var requestGeneration = 0
    private var stage: Stage?
    var isPending: Bool { stage != nil }

    func cancel() {
        requestGeneration &+= 1
        stage = nil
    }

    func start(requiresSpeech: Bool,
               requestMicrophone: PermissionRequest,
               requestSpeech: @escaping PermissionRequest,
               isActive: @escaping () -> Bool,
               onReady: @escaping () -> Void,
               onFailure: @escaping (Failure) -> Void) {
        guard !isPending else { return }
        requestGeneration &+= 1
        let generation = requestGeneration
        stage = .microphone
        let finish: (Failure?) -> Void = { [weak self] failure in
            guard let self, self.requestGeneration == generation, self.isPending else { return }
            self.stage = nil // Consume BEFORE calling out (including reentrant starts).
            if let failure { onFailure(failure) }
            else if !isActive() { onFailure(.inactive) }
            else { onReady() }
        }
        requestMicrophone { [weak self] granted in
            guard let self, self.requestGeneration == generation, self.stage == .microphone else { return }
            guard granted else { finish(.microphoneDenied); return }
            guard requiresSpeech else { finish(nil); return }
            self.stage = .speech
            requestSpeech { [weak self] granted in
                guard let self, self.requestGeneration == generation, self.stage == .speech else { return }
                finish(granted ? nil : .speechDenied)
            }
        }
    }
}

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

    enum Issue: Equatable {
        case microphoneDenied, speechDenied, simulator, disabled
        case recognizerUnavailable, onDeviceUnavailable, audioUnavailable, inactive, interrupted

        var message: String {
            switch self {
            case .microphoneDenied: return "Microphone access is denied. Allow it in Settings to use voice."
            case .speechDenied: return "Speech recognition access is denied or restricted. Check Settings to use voice."
            case .simulator: return "Voice input is unavailable in the simulator. Use a physical device."
            case .disabled: return "Voice input is disabled."
            case .recognizerUnavailable: return "Speech recognition is currently unavailable. Try again later."
            case .onDeviceUnavailable: return "On-device speech recognition is unavailable for this language."
            case .audioUnavailable: return "Voice input could not continue. Check your microphone and try again."
            case .inactive: return "Voice stopped because the app is not active. Tap to start again."
            case .interrupted: return "Voice stopped after an audio interruption. Tap to start again."
            }
        }

        var offersSettings: Bool { self == .microphoneDenied || self == .speechDenied }
    }

    enum Status: Equatable {
        case idle, starting, listening, transcribing, failed(Issue)
    }

    @Published private(set) var status: Status = .idle
    var isStarting: Bool { status == .starting }
    var issue: Issue? {
        if case .failed(let issue) = status { return issue }
        return nil
    }
    /// Synchronous teardown notification (timers/playback must not wait for a render).
    var onEnded: (() -> Void)?
    private let startGate = DictationStartGate()
    private var lifecycleObservers: [NSObjectProtocol] = []

    init() {
        #if os(iOS)
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                                                       object: nil, queue: .main) { [weak self] _ in
            // Permission sheets temporarily deactivate the app. Do not cancel
            // their handshake here; background always cancels, and the gate
            // checks active state only at the actual audio-start boundary.
            guard let self, !self.isStarting else { return }
            self.interrupt(.inactive)
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                       object: nil, queue: .main) { [weak self] _ in
            self?.interrupt(.inactive)
        })
        lifecycleObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                                       object: nil, queue: .main) { [weak self] note in
            guard let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.began.rawValue else { return }
            self?.interrupt(.interrupted)
        })
        #endif
    }

    deinit {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func interrupt(_ issue: Issue) {
        guard isStarting || isRecording || isTranscribing else { return }
        fail(issue)
    }

    private func fail(_ issue: Issue) {
        cancel()
        status = .failed(issue)
    }

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

    // MARK: - Continuous (hands-free) mode

    /// Which half of the conversation the mic is serving. Only meaningful
    /// in continuous mode; one-shot dictation stays `.listening` for its
    /// whole life.
    enum Phase {
        /// Mic off.
        case idle
        /// Transcribing the user into the composer.
        case listening
        /// The agent is talking. The main transcriber is torn down and the
        /// barge-in monitor has the buffers instead — nothing the mic hears
        /// during this phase reaches the composer.
        case agentSpeaking
    }

    @Published private(set) var phase: Phase = .idle

    /// Captured at `start()`. In continuous mode the audio engine and its
    /// tap stay up across turns — only the *consumer* of the buffers is
    /// swapped — so the loop never pays an engine restart per turn, and
    /// the audio session is configured once for both recording and
    /// playback rather than being fought over.
    ///
    /// Published because the composer looks different in the two modes:
    /// one-shot dictation hides the field behind a waveform, continuous
    /// leaves it visible so the transcript can be read as it lands.
    @Published private(set) var continuous = false

    /// Fires when the monitor hears the user talking over the agent.
    /// The composer stops playback and hands the mic back.
    var onBargeIn: (() -> Void)?

    /// Supplies the agent's recently-spoken text so the monitor can tell
    /// the user's voice from the agent's own audio leaking back into the
    /// mic. Wired to `VoiceController.recentSpokenText`.
    var agentSpokenText: (() -> String)?

    /// Fires while the user is audibly speaking during their own turn, so
    /// hands-free can tell "still talking" from "stopped".
    ///
    /// This has to come from the mic level, not from the transcript. The
    /// Whisper backend re-transcribes the *entire* utterance on every pass
    /// and runs on CPU, so passes start about a second apart and drift
    /// further as the utterance grows — well past any sane silence
    /// timeout. A countdown driven by transcript growth alone therefore
    /// completes mid-sentence and sends half a thought.
    ///
    /// Throttled to ``voiceActivityInterval``: the tap delivers a buffer
    /// roughly every 21ms and the consumer restarts a timer on each call.
    var onVoiceActivity: (() -> Void)?

    /// Normalised level at or above which the mic is hearing speech rather
    /// than room tone. `normalisedLevel` puts conversational speech around
    /// 0.3–0.6 and a quiet room below 0.15.
    private let voiceActivityThreshold: CGFloat = 0.2
    private let voiceActivityInterval: TimeInterval = 0.25
    private var lastVoiceActivityAt: TimeInterval = 0

    /// Barge-in monitor: a second recognizer that runs only during
    /// `.agentSpeaking` and whose transcripts never reach the composer.
    private var monitorRequest: SFSpeechAudioBufferRecognitionRequest?
    private var monitorTask: SFSpeechRecognitionTask?
    /// Latched for the duration of one agent turn so a run of partials
    /// can't fire barge-in repeatedly.
    private var bargeInFired = false
    /// Novel words required before a monitor partial counts as the user
    /// interrupting rather than the agent's own voice leaking back.
    private let bargeInNovelWordsRequired = 2

    /// The single input-node tap fans buffers out to whichever consumers
    /// are live. Installing a second tap on the bus throws, so everything
    /// that wants audio — the transcriber, the barge-in monitor, the level
    /// meter — has to share this one.
    private var mainConsumer: ((AVAudioPCMBuffer) -> Void)?
    private var monitorConsumer: ((AVAudioPCMBuffer) -> Void)?
    private var tapInstalled = false
    private var audioGeneration = 0
    private var ownsAudioSession = false

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
        unavailableReason(config: config) == nil
    }

    /// Read-only checks: never request permissions merely to render a control.
    func unavailableReason(config: ChatWidgetConfig, continuous: Bool = false) -> Issue? {
        guard config.enableVoice, config.effectiveSpeechInputPolicy != .disabled else { return .disabled }
        #if targetEnvironment(simulator)
        if case .system = config.dictationBackend { return .simulator }
        #endif
        #if os(iOS)
        if #available(iOS 17.0, *) {
            if AVAudioApplication.shared.recordPermission == .denied { return .microphoneDenied }
        } else {
            if AVAudioSession.sharedInstance().recordPermission == .denied { return .microphoneDenied }
        }
        #else
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphone == .denied || microphone == .restricted { return .microphoneDenied }
        #endif
        if Self.requiresSpeechPermission(backend: config.dictationBackend, continuous: continuous) {
            let speech = SFSpeechRecognizer.authorizationStatus()
            if speech == .denied || speech == .restricted { return .speechDenied }
        }
        switch config.dictationBackend {
        case .whisper:
            return nil
        case .system:
            if config.effectiveSpeechInputPolicy == .localOnly,
               recognizer?.supportsOnDeviceRecognition != true {
                return .onDeviceUnavailable
            }
            return recognizer?.isAvailable == true ? nil : .recognizerUnavailable
        }
    }

    static func requiresSpeechPermission(backend: DictationBackend, continuous: Bool) -> Bool {
        if case .system = backend { return true }
        // Whisper itself is local, but continuous mode's barge-in monitor
        // uses Apple's speech recognizer too (unavailable on the simulator).
        #if targetEnvironment(simulator)
        return false
        #else
        return continuous
        #endif
    }

    // MARK: - Session control

    /// - Parameter continuous: opts into hands-free mode — the engine and
    ///   its tap stay up across turns, the audio session is configured for
    ///   simultaneous playback, and ``beginAgentTurn()`` /
    ///   ``beginUserTurn()`` drive the listen ↔ speak cycle. One-shot
    ///   dictation (the default) tears everything down at `stop()`.
    func start(policy: SpeechInputPolicy,
               backend: DictationBackend = .system,
               continuous: Bool = false) {
        guard !isRecording, !isStarting else { return }
        guard policy != .disabled else { fail(.disabled); return }
        #if targetEnvironment(simulator)
        if case .system = backend { fail(.simulator); return }
        #endif
        cancel() // Also invalidates a detached Whisper final pass.
        self.policy = policy
        self.backend = backend
        self.continuous = continuous
        failures = 0
        status = .starting
        startGate.start(
            requiresSpeech: Self.requiresSpeechPermission(backend: backend, continuous: continuous),
            requestMicrophone: requestMicPermission,
            requestSpeech: { completion in
                SFSpeechRecognizer.requestAuthorization { status in
                    DispatchQueue.main.async { completion(status == .authorized) }
                }
            },
            isActive: {
                #if os(iOS)
                return UIApplication.shared.applicationState == .active
                #else
                return true
                #endif
            },
            onReady: { [weak self] in
                guard let self else { return }
                switch backend {
                case .whisper(let model): self.beginWhisperSession(model: model)
                case .system: self.beginSession()
                }
            },
            onFailure: { [weak self] failure in
                switch failure {
                case .microphoneDenied: self?.fail(.microphoneDenied)
                case .speechDenied: self?.fail(.speechDenied)
                case .inactive: self?.fail(.inactive)
                }
            }
        )
    }

    /// Ends the session, keeping the transcript. For the Whisper backend
    /// one final transcription lands through ``onTranscript`` shortly
    /// after this returns — callers whose state must not change after
    /// stopping (send, discard, dismiss) use ``cancel()`` instead.
    func stop() {
        startGate.cancel()
        if case .whisper = backend, let session = whisperSession, isRecording {
            whisperSession = nil
            teardownAudio()
            // After teardown so the final pass sees every buffer the tap
            // delivered. The session outlives the engine's reference
            // until its delivery completes; `onFinished` clears this.
            isTranscribing = true
            status = .transcribing
            session.finish()
            return
        }
        cancel()
    }

    /// Ends the session and guarantees nothing further is delivered.
    func cancel() {
        startGate.cancel()
        // Bump first so any callback that fires between cancel() and the
        // next runloop tick is filtered out by the token guard.
        sessionToken &+= 1
        whisperSession?.cancel()
        whisperSession = nil
        teardownAudio()
    }

    private func teardownAudio() {
        audioGeneration &+= 1
        let hadSession = isStarting || isRecording || isTranscribing
        let hadAudio = ownsAudioSession || tapInstalled || isRecording
        ownsAudioSession = false
        if audioEngine.isRunning { audioEngine.stop() }
        removeSharedTap()
        teardownMonitorRecognition()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
        isTranscribing = false
        status = .idle
        continuous = false
        phase = .idle
        audioLevel = 0
        // Release the session so the next playback can restore media-level
        // loudness and repair the route this recording leaves behind.
        if hadAudio {
            AudioSessionCoordinator.owner = .unclaimed
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
        if hadSession { onEnded?() }
    }

    // MARK: - Shared input tap

    /// Installs the one permitted tap on the input bus, if it isn't
    /// already there. The closure runs on a realtime audio thread and
    /// dispatches to whichever consumers are currently live, so switching
    /// between transcribing and monitoring never touches the tap itself —
    /// which is what lets the engine keep running across a whole
    /// conversation.
    ///
    /// Returns `false` for an input node that reports an unusable format
    /// (a node caught mid-reconfiguration hands back 0 Hz / 0 channels,
    /// and installing a tap with it throws).
    @discardableResult
    private func installSharedTap() -> Bool {
        guard !tapInstalled else { return true }
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            AgentLog.error("[Dictation] tap: invalid input format (sampleRate=\(format.sampleRate) channels=\(format.channelCount))")
            return false
        }
        let generation = audioGeneration
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.mainConsumer?(buffer)
            self.monitorConsumer?(buffer)
            // Same buffer, one extra pass — drives the waveform. Must hop
            // to main: this closure runs on a realtime audio thread.
            let level = DictationEngine.normalisedLevel(from: buffer)
            DispatchQueue.main.async {
                guard self.isRecording, self.audioGeneration == generation else { return }
                self.audioLevel = level
                self.noteLevelForVoiceActivity(level)
            }
        }
        tapInstalled = true
        return true
    }

    /// Reports speech to ``onVoiceActivity``, throttled, and only during
    /// the user's own turn — during the agent's, anything the mic picks up
    /// is either leak-back or a barge-in, and neither should look like the
    /// user still holding the floor.
    private func noteLevelForVoiceActivity(_ level: CGFloat) {
        guard continuous, phase == .listening, onVoiceActivity != nil else { return }
        guard level >= voiceActivityThreshold else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastVoiceActivityAt >= voiceActivityInterval else { return }
        lastVoiceActivityAt = now
        onVoiceActivity?()
    }

    private func removeSharedTap() {
        mainConsumer = nil
        monitorConsumer = nil
        guard tapInstalled else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    /// Configures the shared audio session. Continuous mode uses
    /// `.voiceChat` for its hardware echo cancellation: the mic stays live
    /// through agent playback so the barge-in monitor can hear an
    /// interrupt, and without AEC that monitor would transcribe the
    /// agent's own voice straight back. One-shot dictation keeps
    /// `.default`, whose voice-processing chain measurably transcribes
    /// better — the cost of `.voiceChat` is confined to the mode that
    /// actually needs it.
    ///
    /// Every call site must pass the same values for a given mode:
    /// reconfiguring mid-cycle tears the simulator's audio device down and
    /// hands back an invalid input format.
    ///
    /// `AVAudioSession` is iOS-only, so the option is taken as a `Bool`
    /// rather than a `SetActiveOptions` — the type can't appear in a
    /// signature that has to compile for macOS.
    private func configureAudioSession(notifyOthersOnDeactivation: Bool = true) throws {
        ownsAudioSession = true
        // Claim the session for the duration of a hands-free conversation so
        // playback doesn't switch the category out from under the live mic
        // between sentences.
        AudioSessionCoordinator.owner = continuous ? .continuousVoice : .unclaimed
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord,
                                     mode: continuous ? .voiceChat : .default,
                                     options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
        try audioSession.setActive(true,
                                   options: notifyOthersOnDeactivation ? .notifyOthersOnDeactivation : [])
        #endif
    }

    // MARK: - Internals

    private func beginSession() {
        do {
            try configureAudioSession()

            // Install the recognition request + tap *before* starting the
            // engine. AVAudioEngine asserts that at least one node
            // connection exists at start time, and merely accessing
            // `inputNode` isn't enough on some iOS versions.
            guard installRecognitionRequest() else {
                fail(.audioUnavailable)
                return
            }
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            phase = .listening
            status = .listening
        } catch {
            AgentLog.error("[Dictation] start failed: \(error)")
            fail(.audioUnavailable)
        }
    }

    // MARK: - Whisper backend

    private func beginWhisperSession(model: String) {
        do {
            try configureAudioSession()

            guard installWhisperConsumer(model: model) else { fail(.audioUnavailable); return }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            phase = .listening
            status = .listening
        } catch {
            AgentLog.error("[Whisper] start failed: \(error)")
            fail(.audioUnavailable)
        }
    }

    /// Builds a Whisper session and points the shared tap at it. Split out
    /// of ``beginWhisperSession`` so a continuous-mode turn recycle can
    /// swap in a fresh utterance session without restarting the engine.
    private func installWhisperConsumer(model: String) -> Bool {
        let session = WhisperDictationSession(model: model)
        // Capture the handler by value: if a new dictation session
        // starts while this one's final pass is still running, the
        // late delivery goes to the closure (and prefix) it was
        // started with, not the new session's.
        sessionToken &+= 1
        let token = sessionToken
        let handler = onTranscript
        session.onTranscript = { [weak self] text in
            guard let self, self.sessionToken == token else { return }
            handler?(text)
        }
        session.onFinished = { [weak self] in
            guard let self, self.sessionToken == token else { return }
            self.isTranscribing = false
            if !self.isRecording { self.status = .idle }
        }

        mainConsumer = { buffer in session.append(buffer) }
        guard installSharedTap() else {
            mainConsumer = nil
            return false
        }

        whisperSession = session
        session.begin()
        return true
    }

    private func requestMicPermission(_ completion: @escaping (Bool) -> Void) {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
        #else
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
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
        // Detach the previous request from the tap before ending it, so no
        // buffer lands on a request we're about to discard. The tap itself
        // stays installed — it is shared, and in continuous mode it
        // outlives any individual request.
        mainConsumer = nil
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

        // A mid-reconfiguration input node reports a 0 Hz / 0-channel
        // format. Installing a tap with it throws, and the recognizer
        // then fails to initialize — reject it here so the caller aborts
        // rather than recycling into a request that cannot possibly work.
        mainConsumer = { buffer in request.append(buffer) }
        guard installSharedTap() else {
            mainConsumer = nil
            recognitionRequest = nil
            return false
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
                        self.fail(.recognizerUnavailable)
                    } else {
                        AgentLog.debug(.input, "[Dictation] recognition error: \(error.localizedDescription) — recycling (\(self.failures)/\(self.maxConsecutiveFailures))")
                        self.recycleRecognitionRequest()
                    }
                }
            }
        }
        return true
    }

    /// Recycles only recognition, never audio after an interruption.
    private func recycleRecognitionRequest() {
        guard isRecording else {
            AgentLog.debug(.input, "[Dictation] recycle: not recording, skipping")
            return
        }
        if !audioEngine.isRunning {
            fail(.interrupted)
            return
        }
        if !installRecognitionRequest() { fail(.recognizerUnavailable) }
    }

    // MARK: - Continuous-mode turn control

    /// Hands the mic to the user: tears the barge-in monitor down and
    /// installs a fresh transcriber for the next utterance. The audio
    /// engine and its tap are untouched, so this costs a request swap
    /// rather than an engine restart.
    ///
    /// Called both when a turn is sent (the run is in flight but the user
    /// may keep talking) and when the agent finishes speaking.
    func beginUserTurn() {
        guard isRecording, continuous else { return }
        teardownMonitorRecognition()
        teardownMainTranscriber()
        phase = .listening

        switch backend {
        case .whisper(let model):
            guard installWhisperConsumer(model: model) else {
                AgentLog.error("[Dictation] continuous: whisper consumer install failed — ending session")
                fail(.audioUnavailable)
                return
            }
        case .system:
            guard installRecognitionRequest() else {
                AgentLog.error("[Dictation] continuous: request install failed — ending session")
                fail(.recognizerUnavailable)
                return
            }
        }
        AgentLog.debug(.input, "[Dictation] continuous: user turn")
    }

    /// Hands the mic to the barge-in monitor for the agent's turn. The
    /// main transcriber goes away, so nothing said (or leaked back) during
    /// playback can reach the composer.
    func beginAgentTurn() {
        guard isRecording, continuous else { return }
        // Idempotent: `isSpeaking` bounces true→false→true across the gaps
        // between sentence chunks, and reinstalling the monitor on each
        // bounce would restart it several times per reply.
        guard phase != .agentSpeaking else { return }
        teardownMainTranscriber()
        phase = .agentSpeaking
        installMonitorRecognition()
        AgentLog.debug(.input, "[Dictation] continuous: agent turn")
    }

    /// Ends the current utterance's transcriber without touching the
    /// engine, the tap, or the session. `cancel()` on the Whisper session
    /// rather than `finish()`: the text it would deliver has already been
    /// read out of the composer and sent, so a late final pass would only
    /// repopulate a field the user has moved past.
    private func teardownMainTranscriber() {
        sessionToken &+= 1
        mainConsumer = nil
        whisperSession?.cancel()
        whisperSession = nil
        isTranscribing = false
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    // MARK: - Barge-in monitor

    private func teardownMonitorRecognition() {
        monitorConsumer = nil
        monitorRequest?.endAudio()
        monitorRequest = nil
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// Runs a second recognizer through the agent's turn purely as a
    /// voice-activity detector. Its partials never reach the composer;
    /// each one is diffed against what the agent has just said, and a
    /// partial carrying ``bargeInNovelWordsRequired`` or more words the
    /// agent didn't say is the user interrupting.
    ///
    /// Apple's speech model is doing the work an RMS threshold can't:
    /// energy-based detection misfires in both directions here — the
    /// agent's own playback trips it, and a user talking under a loud
    /// agent sits below any fixed threshold.
    ///
    /// Always the system recognizer, whatever the transcription backend
    /// is: Whisper transcribes a buffered window on a timer, which is far
    /// too slow to catch an interrupt. Barge-in degrades to the stop
    /// button when the recognizer is unavailable — including on the
    /// simulator, where it reports healthy and then fails every task.
    private func installMonitorRecognition() {
        teardownMonitorRecognition()
        bargeInFired = false

        #if targetEnvironment(simulator)
        // Whisper still works here, but Apple's recognizer does not. The
        // user can always stop playback explicitly instead of barging in.
        return
        #else
        guard audioEngine.isRunning else {
            AgentLog.debug(.input, "[Dictation] monitor: engine not running — barge-in off this turn")
            return
        }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            AgentLog.debug(.input, "[Dictation] monitor: recognizer unavailable — barge-in off this turn")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if policy == .localOnly {
            // The monitor hears everything the mic does, so it is bound by
            // the same local-only guarantee as the transcriber. No
            // on-device model means no monitor — never a silent fallback
            // to server-side recognition.
            guard recognizer.supportsOnDeviceRecognition else {
                AgentLog.debug(.input, "[Dictation] monitor: on-device recognition unavailable under localOnly — barge-in off")
                return
            }
            request.requiresOnDeviceRecognition = true
        }
        monitorRequest = request
        monitorConsumer = { buffer in request.append(buffer) }

        monitorTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result = result {
                let transcript = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard self.monitorRequest === request else { return }
                    guard !self.bargeInFired else { return }
                    let agentText = self.agentSpokenText?() ?? ""
                    let novel = DictationEngine.novelWordCount(in: transcript, against: agentText)
                    guard novel >= self.bargeInNovelWordsRequired else {
                        if !transcript.isEmpty {
                            AgentLog.debug(.input, "[Dictation] monitor: novel=\(novel) — leak-back, ignored")
                        }
                        return
                    }
                    AgentLog.debug(.input, "[Dictation] monitor: novel=\(novel) — BARGE-IN")
                    self.bargeInFired = true
                    self.onBargeIn?()
                }
            }
            if error != nil {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard self.monitorRequest === request else { return }
                    // Recycle only while the agent is still talking —
                    // reinstalling regardless is how this became an
                    // unbounded spin last time.
                    guard self.isRecording, self.phase == .agentSpeaking else { return }
                    self.installMonitorRecognition()
                }
            }
        }
        #endif
    }

    /// Number of words in `transcript` absent from `agentText`. Both are
    /// lowercased and stripped to alphanumerics before tokenizing. Words
    /// of 2 characters or fewer don't count: "a", "I", "is" appear in
    /// almost any English transcription and would dominate the score.
    static func novelWordCount(in transcript: String, against agentText: String) -> Int {
        let agentTokens = Set(tokenize(agentText))
        return tokenize(transcript).reduce(into: 0) { count, token in
            if token.count > 2 && !agentTokens.contains(token) { count += 1 }
        }
    }

    private static func tokenize(_ text: String) -> [String] {
        let stripped = text.lowercased().map { ch -> Character in
            ch.isLetter || ch.isNumber || ch.isWhitespace ? ch : " "
        }
        return String(stripped).split(whereSeparator: { $0.isWhitespace }).map(String.init)
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
