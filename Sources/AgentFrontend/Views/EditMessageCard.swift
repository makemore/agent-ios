import SwiftUI
import AgentClient

/// Bottom card presented in place of the composer while editing a sent
/// user message. Mirrors the Claude iOS app's edit flow: a banner
/// explaining that sending restarts the conversation from this point,
/// an ✕ to abandon the edit, the message pre-filled in an editable
/// field, and an accent send button.
///
/// Dictation works here exactly as in the composer, backed by the same
/// ``DictationEngine``: the mic replaces the text with a live waveform,
/// stop keeps the transcript for review, send commits it. The engine's
/// transcript appends to whatever text the field held at mic-start.
///
/// Purely presentational — the truncate-and-supersede semantics live in
/// ``ChatViewModel.editMessage(at:newContent:)``, which the host invokes
/// from ``onSend``.
struct EditMessageCard: View {
    let config: ChatWidgetConfig
    @Binding var text: String
    let onSend: () -> Void
    let onCancel: () -> Void

    @StateObject private var dictation = DictationEngine()

    /// Edit text as it stood when the mic started, so ✕ can discard the
    /// dictated portion and restore it.
    @State private var dictationPrefix: String = ""

    /// Focus is requested on appear so the keyboard comes up with the
    /// card and the caret is ready in the pre-filled text.
    @FocusState private var focused: Bool

    private var appearance: ChatAppearance { config.appearance }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Same dropped-writes rule as the composer: while dictating, the
    /// transcript owns the field — the keyboard stays up but typing into
    /// it does nothing. Dictation assigns `text` directly.
    private var editTextBinding: Binding<String> {
        Binding(
            get: { text },
            set: { newValue in
                guard !dictation.isRecording else { return }
                text = newValue
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text("Editing this message will restart the conversation from this point.")
                    .font(.footnote)
                    .foregroundColor(appearance.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: {
                    dictation.stop()
                    onCancel()
                }) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(appearance.textSecondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Cancel editing")
            }

            HStack(alignment: .center, spacing: 8) {
                if dictation.isRecording {
                    Button(action: {
                        dictation.stop()
                        text = dictationPrefix
                    }) {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundColor(appearance.textSecondary)
                            .frame(width: 36, height: 36)
                            .background(appearance.surfaceElevated)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Cancel dictation")
                    .accessibilityHint("Discards the recording and restores the previous text.")
                }

                ZStack(alignment: .leading) {
                TextField("", text: editTextBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...10)
                    .font(.body)
                    .foregroundColor(appearance.textPrimary)
                    .tint(appearance.accent)
                    .focused($focused)
                    .opacity(dictation.isRecording ? 0 : 1)
                    .allowsHitTesting(!dictation.isRecording)
                    // Zero opacity still occupies layout and the field
                    // grows with the arriving transcript — clamp it while
                    // hidden, same as the composer.
                    .frame(height: dictation.isRecording ? RecordingWaveformView.preferredHeight : nil)

                if dictation.isRecording {
                    RecordingWaveformView(level: dictation.audioLevel,
                                          color: appearance.accent)
                }
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                if dictation.isRecording {
                    Button(action: { dictation.stop() }) {
                        Image(systemName: "stop.fill")
                            .font(.title3)
                            .foregroundColor(appearance.textSecondary)
                            .frame(width: 36, height: 36)
                            .background(appearance.surfaceElevated)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Stop dictation")
                    .accessibilityHint("Ends recording and keeps the transcribed text for editing.")
                } else if dictation.isAvailable(config: config) {
                    Button(action: startDictation) {
                        Image(systemName: "mic")
                            .font(.title3)
                            .foregroundColor(appearance.textSecondary)
                            .frame(width: 36, height: 36)
                    }
                    .accessibilityLabel("Dictate")
                }

                Button(action: {
                    dictation.stop()
                    onSend()
                }) {
                    Image(systemName: "arrow.up")
                        .font(.title3)
                        .foregroundColor(canSend ? appearance.textOnAccent : .white)
                        .frame(width: 36, height: 36)
                        .background(canSend ? appearance.accent : Color.gray)
                        .clipShape(Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Send edited message")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: appearance.composerCornerRadius)
                .fill(appearance.surface)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(appearance.background)
        .onAppear { focused = true }
        .onDisappear { dictation.stop() }
    }

    private func startDictation() {
        // Snapshot so dictation appends to the existing edit rather than
        // replacing it — captured into the closure, not held as state.
        let prefix = text
        dictationPrefix = prefix
        dictation.onTranscript = { transcribed in
            let separator = prefix.isEmpty ? "" : " "
            var newText = prefix + separator + transcribed
            if newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                newText = ""
            }
            text = newText
        }
        dictation.start(policy: config.effectiveSpeechInputPolicy)
    }
}
