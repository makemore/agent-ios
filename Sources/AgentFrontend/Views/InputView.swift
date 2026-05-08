import SwiftUI
import AVFoundation
import AgentClient
import Speech
#if canImport(UIKit)
import UIKit
#endif

/// Message input view with text field and send button
public struct InputView: View {
    let config: ChatWidgetConfig
    let isLoading: Bool
    /// Live mirror of ``VoiceController.isSpeaking`` from the parent's
    /// ``@StateObject``. Passed in (rather than observed locally) so SwiftUI
    /// re-evaluates this view when the TTS state flips, which drives the
    /// hands-free loop and barge-in monitor.
    let isAgentSpeaking: Bool
    /// Reference used only to call ``stop()`` on barge-in. Optional because
    /// some callers don't wire a controller (text-only mode).
    let voiceController: VoiceController?
    let onSend: (String, [FileAttachment]) -> Void
    let onCancel: () -> Void

    public init(config: ChatWidgetConfig,
                isLoading: Bool,
                isAgentSpeaking: Bool = false,
                voiceController: VoiceController? = nil,
                onSend: @escaping (String, [FileAttachment]) -> Void,
                onCancel: @escaping () -> Void) {
        self.config = config
        self.isLoading = isLoading
        self.isAgentSpeaking = isAgentSpeaking
        self.voiceController = voiceController
        self.onSend = onSend
        self.onCancel = onCancel
    }

    @State private var inputText: String = ""
    @State private var attachedFiles: [FileAttachment] = []
    @State private var showFilePicker: Bool = false
    @State private var isRecording: Bool = false
    @State private var speechRecognizer = SFSpeechRecognizer()
    @State private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var recognitionTask: SFSpeechRecognitionTask?
    @State private var audioEngine = AVAudioEngine()
    /// Monotonic token so late callbacks from a cancelled/superseded
    /// recognition task cannot repopulate `inputText` after a send/stop.
    /// `SFSpeechRecognitionTask`'s result block can deliver a final
    /// transcription on the main queue *after* `cancel()` returns, which
    /// is the race that caused the input field to refill after submit.
    @State private var recordingSession: Int = 0

    // ----- Auto-send (hands-free) -----
    /// User toggle. Persists across launches. When on:
    ///  • a 3 s silence after the last partial auto-submits the text
    ///  • after the agent reply, the mic re-engages automatically
    ///  • barge-in interrupts the agent if the user starts speaking
    /// Defaults to ``true`` so a fresh install lands in hands-free mode.
    @AppStorage("voice.autoSend") private var autoSendEnabled: Bool = true
    /// Tracks whether the most recent send originated from the mic, so
    /// the hands-free loop only re-engages mic-initiated conversations.
    @State private var lastSendWasMic: Bool = false
    /// Countdown task that fires ``sendMessage`` after silence.
    @State private var silenceTimer: Task<Void, Never>?
    /// Drives the ring animation around the mic button (1.0 → 0.0).
    @State private var countdownProgress: Double = 0
    /// Length of the silence window before auto-send fires.
    private let silenceTimeoutSeconds: Double = 3.0
    // MARK: Barge-in (recognizer-based)
    //
    // We don't try to detect barge-in from raw audio energy — RMS-based
    // detection misfires under both common conditions (no hardware AEC
    // on simulator → constant false positive from agent leak-back; on
    // device the user's voice often sits below a fixed threshold when
    // the agent is loud). Instead we run a *monitor* SFSpeechRecognizer
    // through the agent's turn, separate from the main recognition
    // request, and treat any partial transcription that contains words
    // *not* in the agent's recently-spoken text as a barge-in signal.
    // This piggy-backs on Apple's tuned speech model and uses the
    // agent's own text as a leak-back filter.

    /// Active monitor recognition request, installed while the agent
    /// is speaking. Separate from ``recognitionRequest`` so we can keep
    /// the main partial-to-``inputText`` writer torn down until the
    /// agent stops, while still listening for an interrupt.
    @State private var monitorRequest: SFSpeechAudioBufferRecognitionRequest?
    @State private var monitorTask: SFSpeechRecognitionTask?
    /// Latched true once ``triggerBargeIn`` fires for the current agent
    /// turn; reset whenever ``installMonitorRecognition`` runs again.
    /// Prevents repeated ``voiceController.stop()`` calls from successive
    /// monitor partials.
    @State private var bargeInFired: Bool = false
    /// Number of *novel* words (not in the agent's recently-spoken text)
    /// required in a single monitor partial to count as a barge-in.
    /// At least two filters out single-word leak-backs that the
    /// recognizer sometimes mis-segments and gives us as a 1-word
    /// transcription.
    private let bargeInNovelWordsRequired: Int = 2
    
    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            // Attached files preview
            if !attachedFiles.isEmpty {
                attachedFilesView
            }
            
            // Input row — center alignment keeps icons visually on the text
            // baseline of the pill even though the TextField's padding makes
            // the pill taller than the icons. Matches iMessage/WhatsApp behaviour.
            HStack(alignment: .center, spacing: 8) {
                // File attachment button
                if config.enableFiles {
                    Button(action: { showFilePicker = true }) {
                        Image(systemName: "paperclip")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Voice input button (with countdown ring when auto-send armed)
                if config.enableVoice {
                    Button(action: { toggleRecording() }) {
                        ZStack {
                            if autoSendEnabled && isRecording && countdownProgress > 0 {
                                Circle()
                                    .trim(from: 0, to: countdownProgress)
                                    .stroke(Color.red, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .frame(width: 26, height: 26)
                                    .animation(.linear(duration: 0.1), value: countdownProgress)
                            }
                            Image(systemName: isRecording ? "mic.fill" : "mic")
                                .font(.title3)
                                .foregroundColor(isRecording ? .red : .secondary)
                        }
                    }
                }

                // Auto-send (hands-free) toggle — only meaningful with mic + TTS
                if config.enableVoice {
                    Button(action: { toggleAutoSend() }) {
                        Image(systemName: autoSendEnabled
                              ? "arrow.triangle.2.circlepath.circle.fill"
                              : "arrow.triangle.2.circlepath.circle")
                            .font(.title3)
                            .foregroundColor(autoSendEnabled ? config.primaryColor : .secondary)
                    }
                    .accessibilityLabel(autoSendEnabled
                                        ? "Disable hands-free auto-send"
                                        : "Enable hands-free auto-send")
                }
                
                // Text input
                TextField(config.placeholder, text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(PlatformColors.systemGray6)
                    .cornerRadius(20)
                
                // Send / Cancel-run / Stop-agent button. Three states:
                //  • run in flight (isLoading)        → cancel the run
                //  • agent is speaking (TTS playback) → stop the agent
                //                                        (user-initiated
                //                                        barge-in)
                //  • otherwise                        → send the message
                if isLoading {
                    Button(action: onCancel) {
                        Image(systemName: "stop.fill")
                            .font(.title3)
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color(hex: "#a85d5d"))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Cancel run")
                } else if isAgentSpeaking {
                    Button(action: userStopAgent) {
                        Image(systemName: "stop.fill")
                            .font(.title3)
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color(hex: "#a85d5d"))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Stop speaking")
                } else {
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up")
                            .font(.title3)
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(canSend ? config.primaryColor : Color.gray)
                            .clipShape(Circle())
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(PlatformColors.systemBackground)
        .sheet(isPresented: $showFilePicker) {
            FilePickerView { files in
                attachedFiles.append(contentsOf: files)
            }
        }
        // Hands-free loop: when the agent finishes speaking after a
        // mic-initiated turn, re-engage the mic for the next utterance.
        // Single-arg ``onChange`` form for iOS 16 compatibility.
        .onChange(of: isAgentSpeaking) { speaking in
            handleAgentSpeakingChanged(speaking)
        }
        // Fallback when TTS is disabled: trigger the loop on run completion.
        .onChange(of: isLoading) { loading in
            handleLoadingChanged(loading)
        }
        .onDisappear {
            cancelSilenceTimer()
            if isRecording { stopRecording() }
        }
    }
    
    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedFiles.isEmpty
    }
    
    private func sendMessage() {
        guard canSend else { return }
        // Latch the input source so the hands-free loop knows this
        // turn originated from the mic.
        lastSendWasMic = isRecording
        cancelSilenceTimer()

        let textToSend = inputText
        let filesToSend = attachedFiles
        // Clear the field *before* recycling the recognition request so
        // late callbacks from the previous request (filtered by the
        // session token bumped inside ``startNewRecognitionRequest``)
        // can't repopulate the input.
        inputText = ""
        attachedFiles = []

        if isRecording {
            // Continuous voice mode: keep the engine running, just
            // recycle the recognition request so the next utterance
            // starts fresh. The mic stays "on" through the whole turn.
            print("[InputView] sendMessage: recycling recognition request post-submit")
            startNewRecognitionRequest()
        } else {
            // Text-only path — dismiss keyboard.
            #if canImport(UIKit)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #endif
        }

        onSend(textToSend, filesToSend)
    }
    
    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    /// Starts the always-on mic session. The audio engine stays running
    /// across submits and through agent playback; only the recognition
    /// request itself is cycled (paused while agent speaks, refreshed
    /// after each submit). Tap once on the mic to enable; tap again to
    /// fully tear down.
    private func startRecording() {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else { return }

        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else { return }

            DispatchQueue.main.async {
                do {
                    #if os(iOS)
                    // Use ``.voiceChat`` for hardware AEC: the mic is now
                    // live throughout agent playback, so without echo
                    // cancellation the recognizer would happily transcribe
                    // the agent's own voice back into the input field.
                    let audioSession = AVAudioSession.sharedInstance()
                    try audioSession.setCategory(.playAndRecord,
                                                 mode: .voiceChat,
                                                 options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
                    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                    #endif

                    // Install the recognition request + tap *before*
                    // starting the engine. AVAudioEngine asserts that
                    // at least one node connection exists at start time,
                    // and merely accessing ``inputNode`` isn't enough on
                    // some iOS versions / the simulator.
                    if !installRecognitionRequest() {
                        stopRecording()
                        return
                    }

                    audioEngine.prepare()
                    try audioEngine.start()
                    isRecording = true
                } catch {
                    #if DEBUG
                    print("[InputView] startRecording failed: \(error)")
                    #endif
                    stopRecording()
                }
            }
        }
    }

    /// Tears down the current ``recognitionRequest``/``recognitionTask``
    /// and removes the mic tap, but leaves ``audioEngine`` running. Used
    /// before installing a new tap (recognition or barge-in) and before
    /// fully stopping the mic.
    private func teardownRecognition() {
        print("[InputView] teardownRecognition (engineRunning=\(audioEngine.isRunning))")
        recordingSession &+= 1
        cancelSilenceTimer()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    /// Installs a fresh recognition request, tap, and recognition task.
    /// Returns ``false`` if the recognizer is unavailable so callers can
    /// abort cleanly. Does *not* start the audio engine — that's the
    /// caller's responsibility (``startRecording`` does it once).
    @discardableResult
    private func installRecognitionRequest() -> Bool {
        guard let recognizer = speechRecognizer else {
            print("[InputView] installRecognitionRequest: no recognizer")
            return false
        }
        guard recognizer.isAvailable else {
            print("[InputView] installRecognitionRequest: recognizer unavailable")
            return false
        }
        print("[InputView] installRecognitionRequest: installing (engineRunning=\(audioEngine.isRunning))")
        // Clear any previous request/tap so we don't double-install.
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        recordingSession &+= 1
        let session = recordingSession
        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            if let result = result {
                DispatchQueue.main.async {
                    guard self.recordingSession == session else { return }
                    let newText = result.bestTranscription.formattedString
                    let changed = newText != self.inputText
                    self.inputText = newText
                    // Reset the silence countdown only once we actually
                    // have some recognized text, and only on changes. This
                    // way the mic can sit idle indefinitely between turns
                    // and the 3 s window starts when the user actually
                    // begins speaking.
                    let hasContent = !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    if self.autoSendEnabled && changed && hasContent {
                        self.restartSilenceTimer()
                    }
                }
            }
            if let error = error {
                #if DEBUG
                print("[InputView] recognition error: \(error.localizedDescription) — recycling request")
                #endif
                DispatchQueue.main.async {
                    guard self.recordingSession == session else { return }
                    // Don't tear the whole mic down on a transient
                    // recognizer error; recycle the request and keep
                    // the always-on mic alive.
                    if self.isRecording { self.startNewRecognitionRequest() }
                }
            }
        }
        return true
    }

    /// Cycles to a fresh recognition request. Restarts the engine if it
    /// got stopped by an audio session interruption (e.g. TTS playback
    /// taking the route or a phone call). Used after every submit and
    /// when the agent finishes speaking.
    private func startNewRecognitionRequest() {
        guard isRecording else {
            print("[InputView] startNewRecognitionRequest: not recording, skipping")
            return
        }
        if !audioEngine.isRunning {
            print("[InputView] startNewRecognitionRequest: engine stopped, restarting")
            #if os(iOS)
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord,
                                        mode: .voiceChat,
                                        options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
                try session.setActive(true, options: [])
            } catch {
                print("[InputView] startNewRecognitionRequest: session reactivate failed: \(error)")
            }
            #endif
            // Install request first so the engine has a tap before start().
            if !installRecognitionRequest() {
                print("[InputView] startNewRecognitionRequest: install failed before engine start")
                return
            }
            do {
                audioEngine.prepare()
                try audioEngine.start()
                print("[InputView] startNewRecognitionRequest: engine restarted ok")
            } catch {
                print("[InputView] startNewRecognitionRequest: engine start failed: \(error)")
            }
            return
        }
        installRecognitionRequest()
    }

    private func stopRecording() {
        // Bump first so any callback that fires between cancel() and the
        // next runloop tick is filtered out by the `session` guard.
        recordingSession &+= 1
        cancelSilenceTimer()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        // Also tear down the barge-in monitor in case we were stopped
        // mid-agent-turn (e.g. user disabled the mic while the agent
        // was still speaking).
        monitorRequest?.endAudio()
        monitorRequest = nil
        monitorTask?.cancel()
        monitorTask = nil
        isRecording = false
    }

    // MARK: - Auto-send (hands-free)

    /// User-facing toggle. Tearing down all transient state when switched
    /// off avoids surprising "ghost" auto-sends moments after the user
    /// disables the feature mid-recording.
    private func toggleAutoSend() {
        autoSendEnabled.toggle()
        if !autoSendEnabled {
            cancelSilenceTimer()
            lastSendWasMic = false
        }
    }

    /// Cancels any running silence timer and resets the visual ring.
    private func cancelSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = nil
        countdownProgress = 0
    }

    /// Starts (or restarts) a ``silenceTimeoutSeconds`` countdown that
    /// fires ``sendMessage`` when it expires. Restarted on every fresh
    /// partial transcription so the user can pause briefly without it
    /// firing prematurely.
    private func restartSilenceTimer() {
        silenceTimer?.cancel()
        countdownProgress = 1.0
        let token = recordingSession
        silenceTimer = Task { @MainActor in
            // Tick every 100 ms so the ring drains smoothly.
            let tickSeconds: Double = 0.1
            let totalTicks = Int(silenceTimeoutSeconds / tickSeconds)
            for tick in 0..<totalTicks {
                try? await Task.sleep(nanoseconds: UInt64(tickSeconds * 1_000_000_000))
                if Task.isCancelled { return }
                // Recording session changed (user tapped mic, sent
                // manually, etc.) — abandon this timer silently.
                if recordingSession != token { return }
                countdownProgress = 1.0 - (Double(tick + 1) / Double(totalTicks))
            }
            if Task.isCancelled || recordingSession != token { return }
            if canSend {
                sendMessage()
            } else {
                // Empty transcript after silence — just stop the mic.
                stopRecording()
            }
        }
    }

    // MARK: - Always-on mic transitions

    /// Called when the agent's TTS playback transitions.
    ///   speaking == true  → swap the main recognition for a *monitor*
    ///                       recognition that watches for the user
    ///                       starting to speak (Apple's speech model
    ///                       acting as a VAD), filtered against the
    ///                       agent's own recently-spoken text to ignore
    ///                       AEC leak-back.
    ///   speaking == false → tear down the monitor and swap back to the
    ///                       main recognition so the user's next
    ///                       utterance is transcribed into the input.
    private func handleAgentSpeakingChanged(_ speaking: Bool) {
        print("[InputView] isAgentSpeaking → \(speaking) (autoSend=\(autoSendEnabled) lastSendWasMic=\(lastSendWasMic) isLoading=\(isLoading) isRecording=\(isRecording))")
        guard isRecording else { return }
        if speaking {
            installMonitorRecognition()
        } else {
            teardownMonitorRecognition()
            startNewRecognitionRequest()
        }
    }

    /// Safety net when TTS is disabled or never produced audio: ensures
    /// the recognition request is fresh once the run completes so
    /// stale callbacks from the previous turn can't leak through.
    private func handleLoadingChanged(_ loading: Bool) {
        print("[InputView] isLoading → \(loading) (autoSend=\(autoSendEnabled) lastSendWasMic=\(lastSendWasMic) isAgentSpeaking=\(isAgentSpeaking) isRecording=\(isRecording))")
        guard !loading, isRecording, !isAgentSpeaking else { return }
        // Recycle in case ``isAgentSpeaking`` never flipped (e.g. TTS
        // disabled or errored) so we don't get stuck on a stale request.
        startNewRecognitionRequest()
    }

    // MARK: - Barge-in (interrupt the agent)

    /// Tears down the active monitor recognition (if any). Safe to call
    /// when no monitor is installed.
    private func teardownMonitorRecognition() {
        monitorRequest?.endAudio()
        monitorRequest = nil
        monitorTask?.cancel()
        monitorTask = nil
    }

    /// Replaces the main recognition request with a *monitor*
    /// SFSpeechRecognizer that runs through the agent's turn. Partials
    /// are not written to ``inputText``; instead each partial's words
    /// are diffed against ``voiceController.recentSpokenText`` and any
    /// transcription containing ``bargeInNovelWordsRequired`` or more
    /// novel words triggers barge-in. Uses Apple's tuned speech model
    /// as the voice-activity detector instead of an RMS threshold.
    private func installMonitorRecognition() {
        // Tear down the main recognition request first; it would fight
        // the monitor request for the recognizer otherwise.
        teardownRecognition()
        teardownMonitorRecognition()
        bargeInFired = false

        guard audioEngine.isRunning else {
            print("[InputView] installMonitorRecognition: engine NOT running — barge-in disabled")
            return
        }
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            print("[InputView] installMonitorRecognition: recognizer unavailable — barge-in disabled")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        monitorRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        print("[InputView] installMonitorRecognition: installed (sampleRate=\(format.sampleRate) channels=\(format.channelCount))")

        monitorTask = recognizer.recognitionTask(with: request) { result, error in
            if let result = result {
                let transcript = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    // Ignore stale callbacks after teardown.
                    guard self.monitorRequest === request else { return }
                    guard !self.bargeInFired else { return }
                    let agentText = self.voiceController?.recentSpokenText ?? ""
                    let novelCount = Self.novelWordCount(in: transcript, against: agentText)
                    if novelCount >= self.bargeInNovelWordsRequired {
                        print("[InputView] monitor: novel=\(novelCount) transcript=\"\(transcript)\" → BARGE-IN")
                        self.triggerBargeIn()
                    } else if !transcript.isEmpty {
                        print("[InputView] monitor: novel=\(novelCount) transcript=\"\(transcript)\" (leak-back, ignored)")
                    }
                }
            }
            if let error = error {
                print("[InputView] monitor recognition error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    guard self.monitorRequest === request else { return }
                    // If the agent is still speaking, recycle the
                    // monitor so we keep listening for an interrupt.
                    if self.isRecording && self.isAgentSpeaking {
                        self.installMonitorRecognition()
                    }
                }
            }
        }
    }

    /// Cuts off TTS mid-sentence and swaps the monitor for a normal
    /// recognition request so the user's continued speech gets
    /// transcribed into ``inputText``.
    private func triggerBargeIn() {
        guard !bargeInFired else { return }
        bargeInFired = true
        print("[InputView] barge-in TRIGGERED — calling voiceController.stop()")
        voiceController?.stop()
        // ``stop()`` flips ``isSpeaking`` synchronously, so the
        // ``.onChange(of: isAgentSpeaking)`` handler will swap to a
        // fresh main recognition request. Belt-and-braces in case the
        // observer hasn't fired yet:
        if !isAgentSpeaking && isRecording {
            startNewRecognitionRequest()
        }
    }

    /// Manual user-initiated stop (tap-to-interrupt button). Same as
    /// ``triggerBargeIn`` but always fires regardless of latch.
    private func userStopAgent() {
        print("[InputView] user tapped stop")
        bargeInFired = true
        voiceController?.stop()
        if isRecording {
            startNewRecognitionRequest()
        }
    }

    /// Number of words in ``transcript`` that don't appear in
    /// ``agentText``. Both inputs are lowercased and stripped of
    /// non-alphanumeric chars before tokenizing on whitespace. Words of
    /// 2 chars or fewer are excluded from the novelty count: short
    /// words ("a", "i", "is") are extremely common in any English
    /// transcription and dominate spurious matches.
    static func novelWordCount(in transcript: String, against agentText: String) -> Int {
        let agentTokens = Set(tokenize(agentText))
        let userTokens = tokenize(transcript)
        var novel = 0
        for token in userTokens where token.count > 2 && !agentTokens.contains(token) {
            novel += 1
        }
        return novel
    }

    private static func tokenize(_ text: String) -> [String] {
        let lowered = text.lowercased()
        let stripped = lowered.map { ch -> Character in
            ch.isLetter || ch.isNumber || ch.isWhitespace ? ch : " "
        }
        return String(stripped).split(whereSeparator: { $0.isWhitespace }).map { String($0) }
    }
    
    @ViewBuilder
    private var attachedFilesView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachedFiles) { file in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.fill")
                            .font(.caption)
                        Text(file.name)
                            .font(.caption)
                            .lineLimit(1)
                        Button(action: { removeFile(file) }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(PlatformColors.systemGray5)
                    .cornerRadius(12)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
    
    private func removeFile(_ file: FileAttachment) {
        attachedFiles.removeAll { $0.id == file.id }
    }
}

/// Simple file picker placeholder
struct FilePickerView: View {
    let onSelect: ([FileAttachment]) -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                Text("File picker not implemented")
                    .foregroundColor(.secondary)
                Text("Use DocumentPicker for production")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .navigationTitle("Select Files")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

