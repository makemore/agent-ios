import SwiftUI
import AVFoundation
import Combine
import AgentClient
import Speech
#if canImport(UIKit)
import UIKit
#endif

/// Message input view with text field and send button
public struct InputView: View {
    let config: ChatWidgetConfig
    let isLoading: Bool
    /// Live mirror of ``VoiceController.isSpeaking``. No longer drives any
    /// composer behaviour — playback control lives on the message rows and
    /// the composer stays fully usable while a message plays. Retained so
    /// existing call sites keep compiling.
    let isAgentSpeaking: Bool
    /// Reference used only to call ``stop()`` on barge-in. Optional because
    /// some callers don't wire a controller (text-only mode).
    let voiceController: VoiceController?
    let onSend: (String, [FileAttachment]) -> Void
    let onCancel: () -> Void
    /// Invoked when the user taps the model pill in the anthropic
    /// composer. Optional so existing call sites (and the classic
    /// composer, which doesn't render a pill) keep working unchanged.
    /// Bundled hosts wire this to present `ModelOptionsSheet`.
    let onModelPillTap: (() -> Void)?
    /// Optional dynamic label for the model pill. When non-nil this
    /// wins over `config.appearance.modelPillLabel`, letting hosts
    /// reflect the actively-selected model (e.g. "Claude Opus 4.7")
    /// as the user picks one in `ModelOptionsSheet`. When `nil` the
    /// static appearance label is used — preserving the existing
    /// behaviour for hosts that don't wire the picker.
    let modelPillLabelOverride: String?
    /// Optional view model used by `AddToChatSheet` to bind its
    /// behaviour toggles (response style, tool access, research, web
    /// search) and to surface recent conversations. Optional so
    /// `InputView` retains its "headless" usage in previews and hosts
    /// that don't pipe a `ChatViewModel` through. When `nil` the sheet
    /// falls back to local stub state.
    let viewModel: ChatViewModel?

    /// End-of-turn signal from the voice controller, resolved once at init
    /// rather than per body pass: `.onReceive` re-subscribes whenever the
    /// publisher instance changes, and this one carries the event that
    /// hands the mic back — not somewhere to be casually churning
    /// subscriptions. Falls back to a publisher that never fires for hosts
    /// with no voice controller wired.
    private let agentTurnDidEnd: AnyPublisher<Void, Never>

    public init(config: ChatWidgetConfig,
                isLoading: Bool,
                isAgentSpeaking: Bool = false,
                voiceController: VoiceController? = nil,
                onSend: @escaping (String, [FileAttachment]) -> Void,
                onCancel: @escaping () -> Void,
                onModelPillTap: (() -> Void)? = nil,
                modelPillLabelOverride: String? = nil,
                viewModel: ChatViewModel? = nil) {
        self.config = config
        self.isLoading = isLoading
        self.isAgentSpeaking = isAgentSpeaking
        self.voiceController = voiceController
        self.onSend = onSend
        self.onCancel = onCancel
        self.onModelPillTap = onModelPillTap
        self.modelPillLabelOverride = modelPillLabelOverride
        self.viewModel = viewModel
        self.agentTurnDidEnd = voiceController?.agentTurnDidEnd.eraseToAnyPublisher()
            ?? Empty<Void, Never>(completeImmediately: false).eraseToAnyPublisher()
    }

    @State private var inputText: String = ""
    @State private var attachedFiles: [FileAttachment] = []
    /// Drives the composer's sheet presentation. `.addToChat` shows
    /// the "Add to Chat" panel from the `+` button; `.filePicker` is
    /// chained when the user picks "Add files" inside that panel.
    /// SwiftUI can only present one sheet per view at a time so the
    /// two are routed through a single `.sheet(item:)` modifier.
    @State private var activeSheet: ActiveSheet? = nil
    /// Latched on when the user taps "Add files" inside the AddToChat
    /// sheet so the picker is presented in the AddToChat sheet's
    /// `onDismiss` callback (sequential sheets otherwise race).
    @State private var pendingFilePicker: Bool = false

    private enum ActiveSheet: Identifiable {
        case addToChat
        case filePicker
        var id: Int { hashValue }
    }
    /// Bumped on every send and applied as the text field's `.id()`.
    /// A vertical-axis `TextField` does not recompute its height when the
    /// binding is cleared programmatically during an active editing
    /// session — the field keeps the multi-line height it had at send
    /// time. Changing identity tears the field down and rebuilds it at
    /// its one-line intrinsic size. Costs nothing otherwise: the field is
    /// empty at that moment, and the text path has already resigned first
    /// responder.
    @State private var composerGeneration: Int = 0
    /// Shared dictation state machine (audio session, recognizer
    /// lifecycle, failure caps, level metering). The same engine type
    /// backs the edit-message card, so mic behaviour cannot drift
    /// between the two surfaces.
    @StateObject private var dictation = DictationEngine()

    /// What the field held when the mic started. The transcript closure
    /// captures its own copy for appending; this one exists so the ✕
    /// cancel affordance can throw the dictated text away and put the
    /// field back exactly as it was.
    @State private var dictationPrefix: String = ""

    /// Hands-free continuous conversation. When on, the mic doesn't stop
    /// at the end of an utterance: a pause auto-sends, the reply is spoken
    /// aloud, and the mic comes back for the next turn — a spoken
    /// back-and-forth with no tapping. Persisted, and off by default: a
    /// fresh install should not land in a mode that sends on its own.
    @AppStorage("voice.autoSend") private var autoSendEnabled: Bool = false

    /// Counts down 1 → 0 over ``silenceTimeoutSeconds`` of quiet, drawn as
    /// a ring around the mic. Restarted by every transcript change, so it
    /// only reaches zero once the user has genuinely stopped talking.
    @State private var silenceTimer: Task<Void, Never>?
    @State private var countdownProgress: Double = 0
    private let silenceTimeoutSeconds: Double = 3.0

    /// Whether S'Ai reads its replies out loud. Off by default — typing a
    /// message and having it answered silently is what most people expect
    /// — and persisted once chosen. Switching hands-free on turns it on,
    /// since a spoken reply is the whole point of a spoken conversation;
    /// switching hands-free off leaves it alone, because by then it is the
    /// user's setting and not the mode's.
    @AppStorage("voice.speakReplies") private var speakRepliesEnabled: Bool = false

    /// True for the whole of an agent speaking turn, unlike
    /// ``isAgentSpeaking`` which drops at every gap between sentence
    /// chunks. Binding the speak-aloud button straight to `isSpeaking`
    /// would flicker it between speaker and stop several times per reply.
    /// Raised on the rising edge, cleared by
    /// ``VoiceController/agentTurnDidEnd``.
    @State private var agentIsSpeakingTurn = false

    private var isRecording: Bool { dictation.isRecording }

    /// Whether the *current* mic session is hands-free. Read from the
    /// engine rather than from ``autoSendEnabled`` so toggling the setting
    /// mid-utterance can't restyle a session that's already running.
    private var isContinuous: Bool { dictation.continuous }

    /// True while the agent holds the turn in continuous mode — the mic is
    /// still live (feeding the barge-in monitor) but nothing it hears
    /// reaches the composer.
    private var agentHasTurn: Bool { dictation.phase == .agentSpeaking }

    /// Whether the composer is in its one-shot dictation presentation:
    /// text field hidden behind a live waveform, stop and send in place of
    /// mic and send.
    ///
    /// Hands-free mode deliberately does *not* do this. There the field
    /// stays visible with the transcript landing in it as you speak, and
    /// the recording state reads from the mic itself — red, with the
    /// silence countdown around it — because in a conversation you want to
    /// see the words that are about to be sent on your behalf.
    private var showsWaveform: Bool { isRecording && !isContinuous }
    /// Whether the composer is in its expanded two-row layout: text field
    /// full-width on top, controls on their own row underneath (the
    /// ChatGPT arrangement). Entered when the text wraps past one line;
    /// left when the text would fit a single row again.
    ///
    /// The decision to leave is deliberately NOT based on the field's
    /// current rendered height: in two-row mode the field is wider, so
    /// text that overflowed the narrow single-row width can render as one
    /// line at full width — height-based reversion would bounce the
    /// layout between modes on every keystroke at the boundary. Instead
    /// the single-row field width is captured at the moment of expansion
    /// and reversion asks "would the text fit THAT width?".
    @State private var isMultiline = false
    /// Field width captured while still in single-row layout — the width
    /// reversion is judged against. See ``isMultiline``.
    @State private var narrowFieldWidth: CGFloat = 0

    /// Height above which the field has visibly wrapped to two lines —
    /// the observed-wrap fallback in the field's geometry reader.
    private var multilineHeightThreshold: CGFloat {
        #if canImport(UIKit)
        return UIFont.preferredFont(forTextStyle: .body).lineHeight * 1.5
        #else
        return 33
        #endif
    }

    /// Width the text would occupy laid out on one line.
    private func singleLineTextWidth(_ text: String) -> CGFloat {
        #if canImport(UIKit)
        return (text as NSString).size(
            withAttributes: [.font: UIFont.preferredFont(forTextStyle: .body)]
        ).width
        #else
        return 0
        #endif
    }

    /// Curve for composer growth — see the `.animation` modifiers in
    /// `body`. A near-critically-damped spring: an ease-out of the same
    /// length reads slightly abrupt at the end of the motion.
    private static let growthAnimation = Animation.spring(response: 0.3, dampingFraction: 0.9)

    /// True for the single UI pass in which `isMultiline` flips. The
    /// TextField reads it in a `.transaction` modifier to opt out of
    /// animating that pass: animating the field's width makes the text
    /// wrap at every intermediate width, and a focused vertical-axis
    /// field keeps that wrapped two-line layout after the width settles
    /// (device-verified: h=57 at w=343 with 271 pt of text, until the
    /// next user edit re-laid it out). Snapping the field straight to
    /// its final width lays the text out exactly once, while the
    /// buttons and container still animate around it.
    @State private var fieldSkipsAnimation = false

    /// Height the field most recently rendered at (from its geometry
    /// reader). Known-correct by definition — it is what is on screen.
    @State private var lastRenderedFieldHeight: CGFloat = 0
    /// While non-nil, the field's height is forced to this value. Set
    /// across a restructure: a focused vertical-axis field answers its
    /// FIRST height query at a new width from its old text layout
    /// (device-verified: 57 pt at a width where the text is one line),
    /// and letting that answer render is the bounce. Pinning the field
    /// to its last real height keeps the bogus answer off screen; the
    /// pin is released one pass later, when re-measures are reliable —
    /// for typing-driven flips the released height equals the pinned
    /// one, so nothing moves.
    @State private var pinnedFieldHeight: CGFloat?

    /// Text as it stood when the current pin was set. The pin is
    /// released only when a DIFFERENT text arrives: a text change is
    /// the one event that makes the field re-measure correctly.
    /// (Releasing after a timer or an extra layout pass re-exposes the
    /// bogus height — device-verified: 57 pt rendered on release, fixed
    /// only by the next keystroke.)
    @State private var pinnedText = ""

    /// Flips `isMultiline` with the field's animation suppressed and its
    /// height pinned — every flip site must go through here. The pin
    /// stays until the next text change (see `pinnedText`); for a
    /// boundary flip the pinned height IS the correct height, so a
    /// held pin looks right indefinitely.
    private func setMultiline(_ value: Bool, reason: String, forText text: String) {
        guard value != isMultiline else { return }
        AgentLog.debug(.input, "[Layout] isMultiline \(isMultiline) -> \(value) (\(reason)) pinning h=\(Int(lastRenderedFieldHeight))")
        fieldSkipsAnimation = true
        if lastRenderedFieldHeight > 0 {
            pinnedFieldHeight = lastRenderedFieldHeight
            pinnedText = text
        }
        isMultiline = value
        DispatchQueue.main.async {
            fieldSkipsAnimation = false
        }
    }

    /// Records the single-row field width the multiline decision measures
    /// against. Only while single-row — the two-row field is full-card
    /// width, which is not the width that decides anything.
    private func handleFieldWidthChange(_ width: CGFloat) {
        guard !showsWaveform, !isMultiline, width > 0 else { return }
        if width != narrowFieldWidth {
            AgentLog.debug(.input, "[Layout] narrowFieldWidth: \(Int(narrowFieldWidth)) -> \(Int(width))")
        }
        narrowFieldWidth = width
    }

    /// One ruler for both directions: the text needs two rows iff it
    /// contains a newline or won't fit the single-row width. Expansion
    /// and reversion previously used different measurements — expansion
    /// keyed off the field's rendered height, reversion off computed text
    /// width — and borderline text wrapped by one ruler but fit by the
    /// other, so the composer expanded and then collapsed again on the
    /// next keystroke. Rendered height is also an animated value, which
    /// made the decision timing-sensitive; text width is not.
    private func handleInputTextChangeForLayout(_ text: String, source: String = "onChange") {
        // `showsWaveform`, not `isRecording`: hands-free keeps the field on
        // screen, so its layout has to keep tracking the transcript as it
        // grows. Only the waveform presentation — where the field is
        // hidden and height-clamped — has nothing to measure.
        guard !showsWaveform, narrowFieldWidth > 0 else {
            AgentLog.debug(.input, "[Layout] eval(\(source)) skipped: waveform=\(showsWaveform) narrow=\(Int(narrowFieldWidth))")
            return
        }
        // Release a held pin on the first NEW text after the flip that
        // set it — this text change is what makes the field re-measure
        // correctly. Before the flip logic, so a flip triggered by this
        // same text can re-pin.
        if pinnedFieldHeight != nil, text != pinnedText {
            AgentLog.debug(.input, "[Layout] releasing pin (\(source), text changed)")
            withAnimation(Self.growthAnimation) {
                pinnedFieldHeight = nil
            }
        }
        if text.isEmpty {
            setMultiline(false, reason: "\(source):empty", forText: text)
            return
        }
        // The field never wraps on trailing whitespace, so trailing
        // spaces must not count toward the wrap decision either —
        // otherwise spaces trigger a restructure the field visually
        // has no reason for.
        let wrapText = text.hasSuffix(" ")
            ? String(text[..<(text.lastIndex(where: { $0 != " " }).map(text.index(after:)) ?? text.startIndex)])
            : text
        #if canImport(UIKit)
        let textWidth = singleLineTextWidth(wrapText)
        // Hysteresis: expand only once the text genuinely exceeds the
        // single-row width; collapse only once it is comfortably back
        // under. The band between the two keeps borderline text stable.
        let needsTwoRows: Bool
        if text.contains("\n") {
            needsTwoRows = true
        } else if isMultiline {
            needsTwoRows = textWidth >= narrowFieldWidth - 4
        } else {
            needsTwoRows = textWidth > narrowFieldWidth
        }
        AgentLog.debug(.input, "[Layout] eval(\(source)): chars=\(text.count) textWidth=\(Int(textWidth)) narrow=\(Int(narrowFieldWidth)) newline=\(text.contains("\n")) needsTwoRows=\(needsTwoRows) isMultiline=\(isMultiline)")
        #else
        // No cheap text measurement off UIKit: expand on explicit
        // newlines only.
        let needsTwoRows = text.contains("\n")
        #endif
        setMultiline(needsTwoRows, reason: source, forText: text)
    }

    /// Binding used by the composer's text field. Writes are dropped
    /// while dictating: the transcript owns the field for the duration,
    /// so the keyboard stays on screen but typing into it does nothing.
    /// Dictation itself assigns ``inputText`` directly and so is
    /// unaffected.
    private var composerTextBinding: Binding<String> {
        Binding(
            get: { inputText },
            set: { newValue in
                guard !isRecording else { return }
                inputText = newValue
                // Synchronously, not via onChange: the layout decision
                // must land in the SAME transaction as the text so the
                // field animates straight to its final shape. onChange
                // fires a pass later — the field first renders wrapped
                // at the narrow width, then restructures, which is the
                // two-step growth this composer kept exhibiting.
                handleInputTextChangeForLayout(newValue, source: "typing")
            }
        )
    }


    public var body: some View {
        // The composer and the keyboard-presentation path had no breadcrumb,
        // so any stall here was attributed to whatever ran last — usually
        // `MessageListView body`, which is misleading.
        let _ = HangDiagnostics.mark("InputView body (recording=\(isRecording))")
        return Group {
            switch config.appearance.composerStyle {
            case .classic:    classicComposer
            case .anthropic:  anthropicComposer
            }
        }
        // The box grows (and shrinks) smoothly, whatever caused it —
        // typing past a line, a transcript chunk landing, or the
        // one-row ↔ two-row restructure. Both decisions come from the
        // same text-width measurement in `handleInputTextChangeForLayout`
        // and change together in the same update, so the two keys animate
        // as one motion.
        .animation(Self.growthAnimation, value: inputText)
        .animation(Self.growthAnimation, value: isMultiline)
        .sheet(item: $activeSheet, onDismiss: {
            // If "Add files" was tapped inside the AddToChat sheet,
            // hand off to the file picker once SwiftUI has fully
            // dismissed the first sheet. Without the brief delay iOS
            // swallows the second presentation.
            if pendingFilePicker {
                pendingFilePicker = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    activeSheet = .filePicker
                }
            }
        }) { sheet in
            switch sheet {
            case .addToChat:
                AddToChatSheet(
                    config: config,
                    viewModel: viewModel,
                    onAddFiles: {
                        pendingFilePicker = true
                        activeSheet = nil
                    },
                    onCaptureImage: { image in
                        if let attachment = makeAttachment(from: image) {
                            attachedFiles.append(attachment)
                        }
                    }
                )
            case .filePicker:
                FilePickerView { files in
                    attachedFiles.append(contentsOf: files)
                }
            }
        }
        .onAppear {
            // Whisper's model load (and first-run download) takes long
            // enough that starting it at mic-tap time would mean seconds
            // of silent waveform. Warm it as soon as the composer exists.
            DictationEngine.preload(config: config)
            // The controller starts every mount with speech off, so the
            // user's persisted choice has to be pushed back into it or it
            // would silently reset itself on every remount.
            voiceController?.autoSpeakReplies = speakRepliesEnabled
        }
        .onDisappear {
            cancelSilenceTimer()
            dictation.cancel()
        }
        // The hands-free loop: the agent taking the turn, and giving it
        // back. `isLoading` is only a fallback for a turn that never spoke.
        .onChange(of: isAgentSpeaking) { speaking in
            handleAgentSpeakingChanged(speaking)
        }
        .onChange(of: isLoading) { loading in
            handleLoadingChanged(loading)
        }
        .onReceive(agentTurnDidEnd) { _ in
            handleAgentTurnEnded()
        }
    }
    
    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedFiles.isEmpty
    }

    private var effectiveSpeechInputPolicy: SpeechInputPolicy {
        config.effectiveSpeechInputPolicy
    }

    /// Evaluated on every body pass by design: `isAvailable` is false for
    /// a beat after launch while the recognizer connects to the speech
    /// service, and re-checking is what makes the mic appear once it
    /// comes up. (A one-shot cache in onAppear froze that early false and
    /// the mic never showed.) Timed so that if this lookup is ever the
    /// thing making the composer slow, it reports itself as a number
    /// instead of staying a theory.
    private var speechInputAvailable: Bool {
        HangDiagnostics.measure("speechInputAvailable") {
            dictation.isAvailable(config: config)
        }
    }

    #if canImport(UIKit)
    /// Convert a `UIImage` captured by the camera tile into a
    /// `FileAttachment` so it flows through the same upload pipeline as
    /// files picked from the document browser. JPEG @ 0.9 quality is a
    /// sensible default for chat-attached photos and keeps payloads
    /// manageable without visible quality loss.
    private func makeAttachment(from image: UIImage) -> FileAttachment? {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        let name = "camera-\(Int(Date().timeIntervalSince1970)).jpg"
        return FileAttachment(name: name, size: data.count, type: "image/jpeg", data: data)
    }
    #else
    private func makeAttachment(from image: Any) -> FileAttachment? { nil }
    #endif
    
    private func sendMessage() {
        guard canSend else { return }

        let textToSend = inputText
        let filesToSend = attachedFiles
        // Clear the field *before* stopping the engine so a late
        // transcript callback (filtered by the engine's session token)
        // can't repopulate the input.
        inputText = ""
        attachedFiles = []
        // Collapse the field back to one line — see `composerGeneration`.
        composerGeneration += 1

        cancelSilenceTimer()

        if dictation.isRecording && isContinuous {
            // Hands-free: the mic stays on across the whole conversation.
            // Start a fresh utterance rather than ending the session — the
            // user may keep talking while the reply is still coming.
            // The next turn starts from an empty field, so it has no
            // prefix to append to.
            dictationPrefix = ""
            dictation.beginUserTurn()
        } else if dictation.isRecording {
            // One-shot dictation: sending ends the mic session. cancel(),
            // not stop(): the message is already on its way, so a late
            // final transcript (Whisper) must not repopulate the cleared
            // field.
            dictation.cancel()
        } else {
            #if canImport(UIKit)
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            #endif
        }

        onSend(textToSend, filesToSend)
    }

    /// Ends dictation and keeps whatever has been transcribed in the
    /// composer so the user can edit it before sending. The counterpart
    /// to ``sendMessage`` while recording.
    ///
    /// Deliberately leaves the keyboard up: the whole point of `stop` is
    /// to review and edit the transcript, so dismissing it here would just
    /// mean tapping the field again.
    private func stopDictation() {
        dictation.stop()
    }

    /// Discards the recording: stops the mic and restores the field to
    /// what it held before dictation started, throwing the transcript
    /// away. The counterpart to ``stopDictation``, which keeps it.
    private func cancelDictation() {
        dictation.cancel()
        inputText = dictationPrefix
    }

    /// Shown in the mic's slot between stopping a Whisper dictation and
    /// its final transcript landing (~1–2 s). Without it the composer
    /// looks finished-and-empty while the transcription is still coming.
    private var transcribingIndicator: some View {
        ProgressView()
            .frame(width: 36, height: 36)
            .accessibilityLabel("Transcribing")
    }

    /// Leading ✕ shown while dictating, immediately left of the waveform.
    @ViewBuilder
    private func dictationCancelButton(secondary: Color, fill: Color) -> some View {
        Button(action: cancelDictation) {
            Image(systemName: "xmark")
                .font(.title3)
                .foregroundColor(secondary)
                .frame(width: 36, height: 36)
                .background(fill)
                .clipShape(Circle())
        }
        .accessibilityLabel("Cancel dictation")
        .accessibilityHint("Discards the recording and restores the previous text.")
    }

    private func toggleRecording() {
        if dictation.isRecording {
            cancelSilenceTimer()
            // Leaving the conversation leaves speaking exactly as the user
            // set it. It is their preference now, not the mode's.
            dictation.stop()
        } else {
            // If a message is being read aloud, starting the mic supersedes
            // it. (Only at the start of a session: within a hands-free
            // conversation the mic is handed back and forth by
            // `DictationEngine`, which never stops playback to do it.)
            voiceController?.stop()
            // Snapshot existing text so dictation appends to it. Both a
            // captured copy and view state — the transcript closure picks
            // between them by mode; see the comment there.
            let prefix = inputText
            dictationPrefix = prefix
            let handsFree = continuousAvailable && autoSendEnabled
            dictation.onTranscript = { transcribed in
                // One-shot dictation captures the prefix by value, so a
                // send can't resurrect a stale one. Hands-free can't do
                // that: its turns run back to back on a single mic
                // session, and a captured prefix would re-prepend whatever
                // was in the field when the conversation started to every
                // turn after the first. It reads the state instead, which
                // `sendMessage` clears at each turn boundary.
                let base = handsFree ? dictationPrefix : prefix
                let separator = base.isEmpty ? "" : " "
                var newText = base + separator + transcribed
                // Whitespace-only compositions (e.g. an empty partial
                // against a bare separator) render as an empty field that
                // still suppresses the placeholder — normalise them to
                // genuinely empty.
                if newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    newText = ""
                }
                // Second of the two restart signals (the other is mic
                // level): the transcription is still catching up, so don't
                // send yet even if the user has already gone quiet.
                //
                // Growth, not mere inequality — Whisper re-transcribes the
                // whole utterance every pass, so a settled transcript can
                // come back reworded around the tail, and treating that as
                // progress would hold the countdown open indefinitely.
                let grew = newText.count > inputText.count
                inputText = newText
                // Same transaction as the text write — see
                // `composerTextBinding`.
                handleInputTextChangeForLayout(newText, source: "dictation")
                if handsFree, grew {
                    restartSilenceTimer()
                }
            }
            if handsFree {
                dictation.agentSpokenText = { [weak voiceController] in
                    voiceController?.recentSpokenText ?? ""
                }
                // Real-time "still talking" signal. Paired with the
                // transcript-growth restart below, the countdown only
                // completes once the user has gone quiet *and* the
                // transcription has stopped catching up — either alone
                // sends too early.
                dictation.onVoiceActivity = {
                    restartSilenceTimer()
                }
                dictation.onBargeIn = { [weak voiceController] in
                    // Stopping the controller ends the agent's turn, which
                    // publishes `agentTurnDidEnd` and hands the mic back
                    // through the same path a normal turn ending takes.
                    voiceController?.stop()
                }
                // A spoken conversation needs spoken replies — without
                // them the loop has no agent turn to wait through. Set the
                // stored preference too, so the speak-aloud button shows
                // the state the mode just put it in.
                speakRepliesEnabled = true
                voiceController?.setEnabled(true)
                voiceController?.autoSpeakReplies = true
            }
            dictation.start(policy: effectiveSpeechInputPolicy,
                            backend: config.dictationBackend,
                            continuous: handsFree)
        }
    }

    // MARK: - Hands-free conversation

    /// Whether the hands-free affordance should exist at all: the host has
    /// opted in, and there is both a mic to listen with and a voice to
    /// reply in. Without TTS the loop has no agent turn to wait through.
    private var continuousAvailable: Bool {
        config.enableContinuousVoice && config.enableTTS && speechInputAvailable
    }

    private func toggleAutoSend() {
        autoSendEnabled.toggle()
        if autoSendEnabled {
            // Switching the mode on switches speaking on with it: a
            // conversation you can't hear isn't one. Switching the mode
            // off again deliberately leaves it alone — by then it is the
            // user's setting, and silently reversing it would be the kind
            // of tidying-up that loses someone's choice.
            speakRepliesEnabled = true
            voiceController?.setEnabled(true)
            voiceController?.autoSpeakReplies = true
        } else {
            // Must not leave a countdown running that would send on its
            // own a moment after the mode was switched off.
            cancelSilenceTimer()
            if isRecording, isContinuous {
                voiceController?.stop()
                dictation.stop()
            }
        }
    }

    /// Restarts the silence window. Ticks at 100ms so the ring drains
    /// smoothly rather than jumping; auto-sends at zero.
    private func restartSilenceTimer() {
        silenceTimer?.cancel()
        countdownProgress = 1
        silenceTimer = Task { @MainActor in
            let tickSeconds = 0.1
            let totalTicks = Int(silenceTimeoutSeconds / tickSeconds)
            for tick in 0..<totalTicks {
                try? await Task.sleep(nanoseconds: UInt64(tickSeconds * 1_000_000_000))
                if Task.isCancelled { return }
                countdownProgress = 1 - (Double(tick + 1) / Double(totalTicks))
            }
            if Task.isCancelled { return }
            countdownProgress = 0
            if canSend {
                sendMessage()
            } else {
                // Silence with nothing transcribed — the mic is on but the
                // user isn't talking. Leave it listening; the clock only
                // restarts when they say something.
                AgentLog.debug(.input, "[Dictation] silence elapsed with nothing to send")
            }
        }
    }

    private func cancelSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = nil
        countdownProgress = 0
    }

    /// The agent started talking. Raises the speaking latch — which the
    /// speak-aloud button reads, in every mode — and in hands-free also
    /// hands the mic to the barge-in monitor.
    ///
    /// Only the rising edge matters: `isSpeaking` falls at every gap
    /// between sentence chunks, so the end of the turn comes from
    /// ``VoiceController/agentTurnDidEnd`` instead.
    private func handleAgentSpeakingChanged(_ speaking: Bool) {
        guard speaking else { return }
        agentIsSpeakingTurn = true
        guard isRecording, isContinuous else { return }
        cancelSilenceTimer()
        dictation.beginAgentTurn()
    }

    /// The agent's turn is genuinely over: drop the latch, and in
    /// hands-free hand the mic back.
    private func handleAgentTurnEnded() {
        agentIsSpeakingTurn = false
        guard isRecording, isContinuous, agentHasTurn else { return }
        dictation.beginUserTurn()
    }

    /// Safety net for a turn that never spoke: TTS off, the provider
    /// errored, or the reply was empty. Without it the mic would sit in
    /// the agent's phase with nothing coming to release it.
    private func handleLoadingChanged(_ loading: Bool) {
        guard !loading, isRecording, isContinuous, agentHasTurn, !isAgentSpeaking else { return }
        AgentLog.debug(.input, "[Dictation] run ended without speech — reclaiming mic")
        dictation.beginUserTurn()
    }

    /// Stops playback on an explicit tap. The mic comes back through
    /// ``handleAgentTurnEnded``, same as an interrupt or a natural end.
    private func userStopAgent() {
        voiceController?.stop()
    }
    
    // MARK: - Composer layouts
    //
    // Two flavours selected by `config.appearance.composerStyle`. Both are
    // single-row: attach, input, mic, send on one line. Tapping the mic
    // swaps the text field for a live waveform with stop and send beside
    // it — stop keeps the transcript in the composer for editing, send
    // submits it. Dictation never speaks back; the only playback is the
    // per-message speaker button in `MessageView`.

    @ViewBuilder
    private var classicComposer: some View {
        VStack(spacing: 0) {
            Divider()

            if !attachedFiles.isEmpty {
                attachedFilesView
            }

            HStack(alignment: .center, spacing: 8) {
                if showsWaveform {
                    dictationCancelButton(secondary: .secondary,
                                          fill: PlatformColors.systemGray6)
                }
                if !showsWaveform, speakAloudAvailable {
                    speakRepliesButton(tint: .secondary)
                }
                if !showsWaveform, config.enableFiles {
                    Button(action: { activeSheet = .addToChat }) {
                        Image(systemName: "paperclip")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }

                ZStack(alignment: .leading) {
                    TextField(config.placeholder, text: composerTextBinding, axis: .vertical)
                        .id(composerGeneration)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .opacity(showsWaveform ? 0 : 1)
                        .allowsHitTesting(!isRecording)
                        // Zero opacity still occupies layout, and a
                        // vertical-axis field grows with its content — so a
                        // long transcript would push the composer taller
                        // behind the waveform. Clamp it while hidden.
                        .frame(height: showsWaveform ? RecordingWaveformView.preferredHeight : nil)

                    if showsWaveform {
                        RecordingWaveformView(level: dictation.audioLevel, color: config.primaryColor)
                    }
                }
                .padding(10)
                .background(PlatformColors.systemGray6)
                .cornerRadius(20)

                if showsWaveform {
                    dictationTrailingControls(accent: config.primaryColor,
                                              secondary: .secondary,
                                              fill: PlatformColors.systemGray6)
                } else {
                    if continuousAvailable {
                        autoSendToggle(tint: .secondary)
                    }
                    if dictation.isTranscribing {
                        transcribingIndicator
                    } else if speechInputAvailable {
                        micButton(tint: .secondary)
                    }

                    rightActionButton
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(PlatformColors.systemBackground)
    }

    /// Adaptive composer card. One row while the text fits one line —
    /// attach, field, mic, send. Once the text wraps, the field takes the
    /// full card width and the controls drop to their own row underneath
    /// (the ChatGPT arrangement), collapsing back when the text shortens.
    ///
    /// Structured so the text field NEVER changes structural identity
    /// across the transition — it stays the same child of the same HStack
    /// and only its siblings come and go. Moving it between containers
    /// would unmount it mid-edit, which resigns first responder and
    /// collapses the keyboard.
    @ViewBuilder
    private var anthropicComposer: some View {
        // One-shot dictation always presents as a single row: the field is
        // hidden behind the waveform, so there is no wrapped text to make
        // room for. Hands-free keeps the field, and so keeps both rows.
        let twoRow = isMultiline && !showsWaveform
        VStack(spacing: 8) {
            if !attachedFiles.isEmpty {
                attachedFilesView
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    if showsWaveform {
                        dictationCancelButton(secondary: config.appearance.textSecondary,
                                              fill: config.appearance.surfaceElevated)
                    }
                    if !twoRow, !showsWaveform, speakAloudAvailable {
                        speakRepliesButton(tint: config.appearance.textSecondary)
                    }
                    if !twoRow, !showsWaveform, config.enableFiles {
                        circularIconButton(systemName: "plus") {
                            activeSheet = .addToChat
                        }
                        .accessibilityLabel("Add to chat")
                    }
                    // Override (dynamic selection from the model picker) wins
                    // over the static appearance label so the pill always
                    // reflects the model the next turn will actually use. Gated
                    // on `showModelSelector` (off by default) — the pill is the
                    // only entry point to `ModelOptionsSheet`, so hiding it fully
                    // suppresses the model selector for hosts that don't opt in.
                    if !twoRow, !showsWaveform,
                       config.showModelSelector,
                       let label = modelPillLabelOverride ?? config.appearance.modelPillLabel,
                       !label.isEmpty {
                        modelPill(label: label)
                    }

                    ZStack(alignment: .leading) {
                        TextField(
                            config.placeholder,
                            text: composerTextBinding,
                            axis: .vertical
                        )
                            .id(composerGeneration)
                            .textFieldStyle(.plain)
                            .lineLimit(1...6)
                            .font(.body)
                            .foregroundColor(config.appearance.textPrimary)
                            .tint(config.appearance.accent)
                            // NOTE: no `.fixedSize(vertical:)` here — it
                            // makes the field ignore imposed heights,
                            // which silently defeats the `pinnedFieldHeight`
                            // guard below (device-verified: rendered 57
                            // while pinned to 29).
                            // See `fieldSkipsAnimation`: the field must
                            // not animate its width through a restructure
                            // or its text wraps at intermediate widths
                            // and sticks there.
                            .transaction { t in
                                if fieldSkipsAnimation { t.animation = nil }
                            }
                            // Measured HERE, on the field itself — not on
                            // the padded ZStack around it. The ZStack
                            // width overstates the usable text width by
                            // its leading padding, which put the computed
                            // wrap point past the real one: the text
                            // wrapped vertically while the layout math
                            // still said it fit (verified on device:
                            // wrapped at textWidth=257 against a 261
                            // "width" that was really 255 + 6 padding).
                            .background(GeometryReader { g in
                                Color.clear
                                    .onAppear {
                                        handleFieldWidthChange(g.size.width)
                                        // onChange never fires for the
                                        // initial height, and the first
                                        // flip needs a known-good height
                                        // to pin.
                                        lastRenderedFieldHeight = g.size.height
                                    }
                                    .onChange(of: g.size.width) { newWidth in
                                        handleFieldWidthChange(newWidth)
                                    }
                                    .onChange(of: g.size.height) { h in
                                        AgentLog.debug(.input, "[Layout] field rendered h=\(Int(h)) w=\(Int(g.size.width)) waveform=\(showsWaveform) isMultiline=\(isMultiline) pinned=\(pinnedFieldHeight.map { Int($0) } ?? -1)")
                                        if !showsWaveform, pinnedFieldHeight == nil {
                                            lastRenderedFieldHeight = h
                                        }
                                        // Observed-wrap fallback: the
                                        // width math is an estimate; the
                                        // rendered height is ground
                                        // truth. If the field has
                                        // genuinely wrapped while still
                                        // single-row, expand regardless
                                        // of what the math said.
                                        if !showsWaveform, !isMultiline, h > multilineHeightThreshold {
                                            setMultiline(true, reason: "renderedWrap", forText: inputText)
                                        }
                                    }
                            })
                            .opacity(showsWaveform ? 0 : 1)
                            .allowsHitTesting(!isRecording)
                            // Zero opacity still occupies layout, and a
                            // vertical-axis field grows with its content — so a
                            // long transcript would push the composer taller
                            // behind the waveform. Clamp it while hidden.
                            .frame(height: showsWaveform ? RecordingWaveformView.preferredHeight : pinnedFieldHeight)

                        if showsWaveform {
                            RecordingWaveformView(level: dictation.audioLevel,
                                                  color: config.appearance.accent)
                        }
                    }
                    .padding(.leading, 6)

                    if showsWaveform {
                        dictationTrailingControls(accent: config.appearance.accent,
                                                  secondary: config.appearance.textSecondary,
                                                  fill: config.appearance.surfaceElevated)
                    } else if !twoRow {
                        if continuousAvailable {
                            autoSendToggle(tint: config.appearance.textSecondary)
                        }
                        if dictation.isTranscribing {
                            transcribingIndicator
                        } else if speechInputAvailable {
                            micButton(tint: config.appearance.textSecondary)
                        }

                        rightActionButton
                    }
                }

                if twoRow {
                    HStack(alignment: .center, spacing: 8) {
                        if speakAloudAvailable {
                            speakRepliesButton(tint: config.appearance.textSecondary)
                        }
                        if config.enableFiles {
                            circularIconButton(systemName: "plus") {
                                activeSheet = .addToChat
                            }
                            .accessibilityLabel("Add to chat")
                        }
                        if config.showModelSelector,
                           let label = modelPillLabelOverride ?? config.appearance.modelPillLabel,
                           !label.isEmpty {
                            modelPill(label: label)
                        }
                        Spacer(minLength: 0)
                        if continuousAvailable {
                            autoSendToggle(tint: config.appearance.textSecondary)
                        }
                        if dictation.isTranscribing {
                            transcribingIndicator
                        } else if speechInputAvailable {
                            micButton(tint: config.appearance.textSecondary)
                        }
                        rightActionButton
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: config.appearance.composerCornerRadius)
                    .fill(config.appearance.surface)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .onChange(of: inputText) { newText in
            handleInputTextChangeForLayout(newText)
        }
        // The reveal when the waveform goes away shows already-long text
        // without a text change, so the layout decision must run once here
        // too.
        .onChange(of: showsWaveform) { waveform in
            if !waveform {
                handleInputTextChangeForLayout(inputText, source: "recordingEnd")
            }
        }
        .background(config.appearance.background)
    }

    /// Trailing controls while dictating: stop, then send. `stop` ends the
    /// mic and leaves the transcript in the field for editing; `send`
    /// submits it. The waveform itself sits inside the field's slot so the
    /// text field can stay mounted underneath it. Shared by both composer
    /// styles, which differ only in their colour sources.
    @ViewBuilder
    private func dictationTrailingControls(accent: Color, secondary: Color, fill: Color) -> some View {
        Button(action: stopDictation) {
            Image(systemName: "stop.fill")
                .font(.title3)
                .foregroundColor(secondary)
                .frame(width: 36, height: 36)
                .background(fill)
                .clipShape(Circle())
        }
        .accessibilityLabel("Stop dictation")
        .accessibilityHint("Ends recording and keeps the transcribed text for editing.")

        // Same stationary-controls rule as the idle composer: send is
        // always in its slot, grey until the transcript gives it something
        // to do.
        Button(action: sendMessage) {
            Image(systemName: "arrow.up")
                .font(.title3)
                .foregroundColor(canSend ? config.appearance.textOnAccent : .white)
                .frame(width: 36, height: 36)
                .background(canSend ? accent : Color.gray)
                .clipShape(Circle())
        }
        .disabled(!canSend)
        .accessibilityLabel("Send")
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

    // MARK: - Shared composer atoms

    /// Right-hand action button shared by both composer layouts. Three
    /// states: cancel (run in flight), send, and send-disabled. Sizing and
    /// corner radius are constant across styles so the muscle memory of
    /// "tap bottom-right" is preserved.
    ///
    /// Stopping *speech* deliberately does not live here. It used to, and
    /// it was unreachable: TTS starts while the reply is still streaming,
    /// so `isLoading` was still true and the cancel-run branch won for the
    /// whole of it. Both branches drew the same glyph in the same colour,
    /// so the user pressing the obvious stop button silently cancelled the
    /// run instead of just muting it. Speech is stopped from
    /// ``speakRepliesButton`` on the left, which is unambiguous and
    /// independent of the run's state.
    @ViewBuilder
    private var rightActionButton: some View {
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
        } else {
            // Always present, greyed out and inert when there is nothing to
            // send. State is shown by colour, not by appearing/disappearing —
            // controls that move around are harder to hit than controls that
            // change colour.
            Button(action: sendMessage) {
                Image(systemName: "arrow.up")
                    .font(.title3)
                    .foregroundColor(canSend ? config.appearance.textOnAccent : .white)
                    .frame(width: 36, height: 36)
                    .background(canSend ? config.appearance.accent : Color.gray)
                    .clipShape(Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
    }

    /// Mic button, shared by every composer slot that offers one.
    ///
    /// While hands-free is listening it turns red and wears the silence
    /// countdown as a ring: a shrinking arc showing how long until what
    /// you've said is sent. Speaking refills it, so it only ever completes
    /// on a real pause.
    @ViewBuilder
    private func micButton(tint: Color) -> some View {
        Button(action: { toggleRecording() }) {
            ZStack {
                // Only once there is something to send: room tone can trip
                // the voice-activity threshold, and a ring counting down to
                // nothing reads as the app about to act when it isn't.
                if countdownProgress > 0, canSend {
                    Circle()
                        .trim(from: 0, to: countdownProgress)
                        .stroke(Color.red, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 30, height: 30)
                        .animation(.linear(duration: 0.1), value: countdownProgress)
                }
                Image(systemName: isRecording ? "mic.fill" : "mic")
                    .font(.title3)
                    .foregroundColor(isRecording ? .red : tint)
            }
            .frame(width: 36, height: 36)
        }
        .accessibilityLabel(isRecording ? "Stop listening" : "Dictate")
    }

    /// Hands-free toggle, immediately left of the mic. Filled and accented
    /// when on, so the mode is legible at a glance before you start
    /// talking rather than only once something has been sent for you.
    @ViewBuilder
    private func autoSendToggle(tint: Color) -> some View {
        Button(action: toggleAutoSend) {
            Image(systemName: autoSendEnabled
                  ? "arrow.triangle.2.circlepath.circle.fill"
                  : "arrow.triangle.2.circlepath.circle")
                .font(.title3)
                .foregroundColor(autoSendEnabled ? config.appearance.accent : tint)
                .frame(width: 36, height: 36)
        }
        .accessibilityLabel(autoSendEnabled
                            ? "Turn off continuous conversation"
                            : "Turn on continuous conversation")
        .accessibilityHint("Sends when you pause, reads replies aloud, and keeps listening.")
    }

    /// Whether the speak-aloud control should exist: the host renders it
    /// and has a voice to speak with.
    private var speakAloudAvailable: Bool {
        config.enableTTS && config.showTTSButton
    }

    /// Decides whether S'Ai talks out loud, and stops it when it is.
    ///
    /// Three states in one slot at the left of the bar: muted, will-speak,
    /// and speaking-now. The third is the point — while a reply is being
    /// read aloud this is the button that shuts it up, and it is the only
    /// one that does. It deliberately does *not* touch the run: the reply
    /// keeps arriving as text, you just stop hearing it.
    ///
    /// Stopping also hands the mic straight back in hands-free, via the
    /// same end-of-turn path a natural finish takes — so it behaves
    /// exactly like talking over S'Ai, only deliberate.
    @ViewBuilder
    private func speakRepliesButton(tint: Color) -> some View {
        if agentIsSpeakingTurn {
            Button(action: userStopAgent) {
                Image(systemName: "stop.fill")
                    .font(.title3)
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(Color(hex: "#a85d5d"))
                    .clipShape(Circle())
            }
            .accessibilityLabel("Stop speaking")
            .accessibilityHint("Stops reading the reply aloud. The reply itself keeps arriving.")
        } else {
            Button(action: toggleSpeakReplies) {
                Image(systemName: speakRepliesEnabled ? "speaker.wave.2" : "speaker.slash")
                    .font(.title3)
                    .foregroundColor(speakRepliesEnabled ? config.appearance.accent : tint)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(speakRepliesEnabled
                                ? "Turn off reading replies aloud"
                                : "Read replies aloud")
        }
    }

    /// Toggles spoken replies. Turning it on also clears the process-wide
    /// "voice provider is unavailable" latch, so a user who hit a TTS
    /// failure earlier gets a real retry rather than a dead button.
    private func toggleSpeakReplies() {
        speakRepliesEnabled.toggle()
        if speakRepliesEnabled {
            voiceController?.setEnabled(true)
        } else {
            voiceController?.stop()
        }
        voiceController?.autoSpeakReplies = speakRepliesEnabled
    }

    /// Compact circular icon button used for the `+` (attach) affordance
    /// and any future symmetrical controls on the Anthropic composer's
    /// bottom row.
    @ViewBuilder
    private func circularIconButton(systemName: String,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3)
                .foregroundColor(config.appearance.textSecondary)
                .frame(width: 36, height: 36)
        }
    }

    /// Pill button used for the model name. Visual only — the action
    /// is a no-op until a host wires it to a model picker. Capsule
    /// with text and a downward chevron.
    @ViewBuilder
    private func modelPill(label: String) -> some View {
        let pill = HStack(spacing: 4) {
            Text(label)
                .font(.subheadline.weight(.medium))
            Image(systemName: "chevron.down")
                .font(.caption2)
        }
        .foregroundColor(config.appearance.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(config.appearance.surfaceElevated)
        )

        if let onTap = onModelPillTap {
            // Tap opens `ModelOptionsSheet` (wired by the host). Use a
            // plain button style so the capsule's existing fill renders
            // without iOS's default button chrome.
            Button(action: onTap) { pill }
                .buttonStyle(.plain)
                .accessibilityLabel("Model: \(label) — open model options")
                .accessibilityHint("Toggles extended thinking and verbose multi-agent display.")
        } else {
            pill.accessibilityLabel("Model: \(label)")
        }
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


#if DEBUG
struct InputView_Previews: PreviewProvider {
    static var configAnthropic: ChatWidgetConfig {
        var c = ChatWidgetConfig()
        c.enableVoice = true
        c.enableFiles = true
        return c
    }
    static var configClassic: ChatWidgetConfig {
        var c = configAnthropic
        c.appearance = ChatAppearance.classic
        return c
    }

    static var previews: some View {
        // Live canvas: type into the field to watch send enable, the
        // two-row expansion trigger on wrap, and the layout collapse as
        // text shortens. Dictation is simulator-off, so the mic button
        // will not render here — its slot behaviour needs a device.
        VStack {
            Spacer()
            InputView(config: configAnthropic,
                      isLoading: false,
                      onSend: { _, _ in },
                      onCancel: {})
        }
        .background(Color(white: 0.95))
        .previewDisplayName("Anthropic composer")

        VStack {
            Spacer()
            InputView(config: configClassic,
                      isLoading: false,
                      onSend: { _, _ in },
                      onCancel: {})
        }
        .previewDisplayName("Classic composer")

        VStack {
            Spacer()
            InputView(config: configAnthropic,
                      isLoading: true,
                      onSend: { _, _ in },
                      onCancel: {})
        }
        .background(Color(white: 0.95))
        .previewDisplayName("Run in flight — cancel button")
    }
}
#endif
