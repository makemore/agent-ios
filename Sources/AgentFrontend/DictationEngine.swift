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
/// All public methods must be called on the main queue. `@Published`
/// properties are only mutated there.
final class DictationEngine: ObservableObject {

    @Published private(set) var isRecording = false
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

    // MARK: - Availability

    /// Whether a mic affordance should render at all.
    func isAvailable(config: ChatWidgetConfig) -> Bool {
        #if targetEnvironment(simulator)
        // The simulator's SFSpeechRecognizer reports available=true and
        // then fails every recognition task it is asked to start. No
        // pre-check catches this — every health signal the API exposes
        // says yes — so dictation is simulator-off wholesale. Test it on
        // hardware.
        return false
        #else
        guard config.enableVoice else { return false }
        // A mic the user has switched off in Settings is a mic that does
        // not exist for this app: showing the button would only lead to a
        // dead tap. `.undetermined` still shows it — the permission
        // prompt fires on first use and that is how the user grants it
        // in the first place.
        #if os(iOS)
        if #available(iOS 17.0, *) {
            guard AVAudioApplication.shared.recordPermission != .denied else { return false }
        } else {
            guard AVAudioSession.sharedInstance().recordPermission != .denied else { return false }
        }
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

    // MARK: - Session control

    func start(policy: SpeechInputPolicy) {
        guard !isRecording else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else { return }
        self.policy = policy
        failures = 0

        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { return }
            DispatchQueue.main.async {
                self.beginSession()
            }
        }
    }

    func stop() {
        // Bump first so any callback that fires between cancel() and the
        // next runloop tick is filtered out by the token guard.
        sessionToken &+= 1
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
                    self.onTranscript?(result.bestTranscription.formattedString)
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
