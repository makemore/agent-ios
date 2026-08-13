import SwiftUI
import AgentClient

/// Bottom card presented in place of the composer while editing a sent
/// user message. Mirrors the Claude iOS app's edit flow: a banner
/// explaining that sending restarts the conversation from this point,
/// an ✕ to abandon the edit, the message pre-filled in an editable
/// field, and an accent send button.
///
/// Purely presentational — the truncate-and-supersede semantics live in
/// ``ChatViewModel.editMessage(at:newContent:)``, which the host invokes
/// from ``onSend``.
struct EditMessageCard: View {
    let appearance: ChatAppearance
    @Binding var text: String
    let onSend: () -> Void
    let onCancel: () -> Void

    /// Focus is requested on appear so the keyboard comes up with the
    /// card and the caret is ready in the pre-filled text.
    @FocusState private var focused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text("Editing this message will restart the conversation from this point.")
                    .font(.footnote)
                    .foregroundColor(appearance.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(appearance.textSecondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Cancel editing")
            }

            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...10)
                .font(.body)
                .foregroundColor(appearance.textPrimary)
                .tint(appearance.accent)
                .focused($focused)

            HStack {
                Spacer(minLength: 0)
                Button(action: onSend) {
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
    }
}
