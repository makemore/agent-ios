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

    private var isRecording: Bool { dictation.isRecording }
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

    /// Height above which a single-row field has visibly wrapped.
    private var multilineHeightThreshold: CGFloat {
        #if canImport(UIKit)
        return UIFont.preferredFont(forTextStyle: .body).lineHeight * 1.5
        #else
        return 33
        #endif
    }

    /// Width the text would occupy laid out on one line, for the
    /// reversion check.
    private func singleLineTextWidth(_ text: String) -> CGFloat {
        #if canImport(UIKit)
        return (text as NSString).size(
            withAttributes: [.font: UIFont.preferredFont(forTextStyle: .body)]
        ).width
        #else
        // No cheap text measurement available: stay expanded until the
        // field empties rather than guessing.
        return .greatestFiniteMagnitude
        #endif
    }

    private func handleFieldGeometryChange(height: CGFloat, width: CGFloat) {
        guard !isRecording, !isMultiline else { return }
        if height > multilineHeightThreshold {
            narrowFieldWidth = width
            isMultiline = true
        }
    }

    private func handleInputTextChangeForLayout(_ text: String) {
        guard isMultiline, !isRecording else { return }
        if text.isEmpty {
            isMultiline = false
        } else if !text.contains("\n"),
                  singleLineTextWidth(text) < narrowFieldWidth - 4 {
            isMultiline = false
        }
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
        .onDisappear {
            dictation.stop()
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

        // Dictation is a one-shot: sending always ends the mic session.
        // There is no hands-free loop to hand the mic back to.
        if dictation.isRecording {
            dictation.stop()
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
        dictation.stop()
        inputText = dictationPrefix
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
            dictation.stop()
        } else {
            // If a message is being read aloud, dictating supersedes it —
            // and the two want incompatible audio-session categories.
            voiceController?.stop()
            // Snapshot existing text so dictation appends to it. Captured
            // into the closure rather than held as view state, so a send
            // can't resurrect a stale prefix.
            let prefix = inputText
            dictationPrefix = prefix
            dictation.onTranscript = { transcribed in
                let separator = prefix.isEmpty ? "" : " "
                var newText = prefix + separator + transcribed
                // Whitespace-only compositions (e.g. an empty partial
                // against a bare separator) render as an empty field that
                // still suppresses the placeholder — normalise them to
                // genuinely empty.
                if newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    newText = ""
                }
                inputText = newText
            }
            dictation.start(policy: effectiveSpeechInputPolicy)
        }
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
                if isRecording {
                    dictationCancelButton(secondary: .secondary,
                                          fill: PlatformColors.systemGray6)
                }
                if !isRecording, config.enableFiles {
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
                        .opacity(isRecording ? 0 : 1)
                        .allowsHitTesting(!isRecording)
                        // Zero opacity still occupies layout, and a
                        // vertical-axis field grows with its content — so a
                        // long transcript would push the composer taller
                        // behind the waveform. Clamp it while hidden.
                        .frame(height: isRecording ? RecordingWaveformView.preferredHeight : nil)

                    if isRecording {
                        RecordingWaveformView(level: dictation.audioLevel, color: config.primaryColor)
                    }
                }
                .padding(10)
                .background(PlatformColors.systemGray6)
                .cornerRadius(20)

                if isRecording {
                    dictationTrailingControls(accent: config.primaryColor,
                                              secondary: .secondary,
                                              fill: PlatformColors.systemGray6)
                } else {
                    if speechInputAvailable {
                        Button(action: { toggleRecording() }) {
                            Image(systemName: "mic")
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }
                        .accessibilityLabel("Dictate")
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
        // Recording always presents as a single row: the field is hidden
        // behind the waveform, so there is no wrapped text to make room for.
        let twoRow = isMultiline && !isRecording
        VStack(spacing: 8) {
            if !attachedFiles.isEmpty {
                attachedFilesView
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    if isRecording {
                        dictationCancelButton(secondary: config.appearance.textSecondary,
                                              fill: config.appearance.surfaceElevated)
                    }
                    if !twoRow, !isRecording, config.enableFiles {
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
                    if !twoRow, !isRecording,
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
                            .opacity(isRecording ? 0 : 1)
                            .allowsHitTesting(!isRecording)
                            // Zero opacity still occupies layout, and a
                            // vertical-axis field grows with its content — so a
                            // long transcript would push the composer taller
                            // behind the waveform. Clamp it while hidden.
                            .frame(height: isRecording ? RecordingWaveformView.preferredHeight : nil)

                        if isRecording {
                            RecordingWaveformView(level: dictation.audioLevel,
                                                  color: config.appearance.accent)
                        }
                    }
                    .padding(.leading, 6)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear {
                                handleFieldGeometryChange(height: g.size.height,
                                                          width: g.size.width)
                            }
                            .onChange(of: g.size.height) { newHeight in
                                handleFieldGeometryChange(height: newHeight,
                                                          width: g.size.width)
                            }
                    })

                    if isRecording {
                        dictationTrailingControls(accent: config.appearance.accent,
                                                  secondary: config.appearance.textSecondary,
                                                  fill: config.appearance.surfaceElevated)
                    } else if !twoRow {
                        if speechInputAvailable {
                            Button(action: { toggleRecording() }) {
                                Image(systemName: "mic")
                                    .font(.title3)
                                    .foregroundColor(config.appearance.textSecondary)
                                    .frame(width: 36, height: 36)
                            }
                            .accessibilityLabel("Dictate")
                        }

                        rightActionButton
                    }
                }

                if twoRow {
                    HStack(alignment: .center, spacing: 8) {
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
                        if speechInputAvailable {
                            Button(action: { toggleRecording() }) {
                                Image(systemName: "mic")
                                    .font(.title3)
                                    .foregroundColor(config.appearance.textSecondary)
                                    .frame(width: 36, height: 36)
                            }
                            .accessibilityLabel("Dictate")
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
    /// states: cancel (run in flight), stop (TTS playing), send. Sizing
    /// and corner radius are constant across styles so the muscle
    /// memory of "tap bottom-right" is preserved.
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
