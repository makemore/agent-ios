import SwiftUI
import AgentClient

/// Modal opened by tapping the model pill in the anthropic composer.
/// Surfaces the two run-time toggles that are otherwise invisible:
///
/// 1. **Extended thinking** — per-conversation; forwards to the
///    runtime as the `thinking:` parameter on the next turn. Asks the
///    model to spend reasoning budget. Reset to `false` automatically
///    by `ChatViewModel.clearMessages()`.
/// 2. **Verbose multi-agent** — per-app preference, persisted via
///    `StorageService`. When `true`, every sub-agent's narration
///    surfaces as its own bubble (`SubAgentActivityStyle.bubbles`)
///    instead of collapsing into the activity pill.
///
/// The header shows the currently active model name (from
/// `ChatAppearance.modelPillLabel`) so the user has context for what
/// the toggles will apply to. Bindings are direct to the view model,
/// so flips persist or take effect without explicit save/apply.
struct ModelOptionsSheet: View {
    let config: ChatWidgetConfig
    @ObservedObject var viewModel: ChatViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    modelHeader
                    modelPickerCard
                    togglesCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(config.appearance.background.ignoresSafeArea())
            .navigationTitle("Model options")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.medium))
                            .foregroundColor(config.appearance.textPrimary)
                            .frame(width: 32, height: 32)
                            .background(config.appearance.surface)
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }

    private var modelHeader: some View {
        VStack(spacing: 6) {
            Text(viewModel.selectedModelDisplayName ?? "Default model")
                .font(.title3.weight(.semibold))
                .foregroundColor(config.appearance.textPrimary)
            Text("Adjust how the model and its specialists work for this conversation.")
                .font(.footnote)
                .foregroundColor(config.appearance.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// Picker card — lists every model the runtime advertises, grouped
    /// by provider. Loading + empty states are spelt out so the sheet
    /// stays informative even before the catalogue arrives.
    @ViewBuilder
    private var modelPickerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Model")
            VStack(spacing: 0) {
                if viewModel.isLoadingModels && viewModel.availableModels.isEmpty {
                    pickerStatusRow(
                        icon: "arrow.triangle.2.circlepath",
                        text: "Loading models…"
                    )
                } else if viewModel.availableModels.isEmpty {
                    pickerStatusRow(
                        icon: "exclamationmark.triangle",
                        text: "No models reported by the runtime. Using its default."
                    )
                } else {
                    let groups = groupedModels(viewModel.availableModels)
                    ForEach(Array(groups.enumerated()), id: \.element.provider) { idx, group in
                        if idx > 0 { rowDivider }
                        providerHeader(group.provider)
                        ForEach(Array(group.models.enumerated()), id: \.element.id) { modelIdx, model in
                            if modelIdx > 0 { rowDivider }
                            modelRow(model)
                        }
                    }
                }
            }
            .background(config.appearance.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private var togglesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Behaviour")
            VStack(spacing: 0) {
                toggleRow(
                    systemImage: "brain",
                    label: "Extended thinking",
                    caption: extendedThinkingCaption,
                    isOn: $viewModel.extendedThinking,
                    isEnabled: extendedThinkingAvailable
                )
                rowDivider
                toggleRow(
                    systemImage: "rectangle.stack",
                    label: "Verbose multi-agent",
                    caption: "Show every specialist's intermediate replies as their own bubbles instead of collapsing them into the activity pill.",
                    isOn: $viewModel.verboseMultiAgent,
                    isEnabled: true
                )
            }
            .background(config.appearance.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private var extendedThinkingAvailable: Bool {
        // If we haven't loaded the catalogue yet, leave the toggle live
        // so users on slow networks aren't blocked. Once the model is
        // resolved we honour its `supportsThinking` flag.
        guard let model = viewModel.selectedModel else { return true }
        return model.supportsThinking
    }

    private var extendedThinkingCaption: String {
        if extendedThinkingAvailable {
            return "Ask the model to spend extra reasoning budget on harder turns. Resets when you start a new conversation."
        }
        let name = viewModel.selectedModel?.name ?? "This model"
        return "\(name) doesn't support extended thinking. Pick a thinking-capable model above to enable this."
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(config.appearance.textSecondary.opacity(0.12))
            .frame(height: 0.5)
            .padding(.leading, 52)
    }

    private func toggleRow(
        systemImage: String,
        label: String,
        caption: String,
        isOn: Binding<Bool>,
        isEnabled: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundColor(config.appearance.textPrimary)
                .frame(width: 24, height: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.body)
                    .foregroundColor(config.appearance.textPrimary)
                Text(caption)
                    .font(.footnote)
                    .foregroundColor(config.appearance.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(config.appearance.accent)
                .padding(.top, 2)
                .disabled(!isEnabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(isEnabled ? 1.0 : 0.55)
    }

    // MARK: - Model picker helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundColor(config.appearance.textSecondary)
            .padding(.horizontal, 4)
            .padding(.bottom, 6)
    }

    private func providerHeader(_ provider: String) -> some View {
        HStack {
            Text(prettyProviderName(provider))
                .font(.footnote.weight(.semibold))
                .foregroundColor(config.appearance.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func modelRow(_ model: AgentModel) -> some View {
        let isSelected = (viewModel.selectedModel?.id == model.id)
        return Button {
            viewModel.selectModel(model.id)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundColor(isSelected
                                     ? config.appearance.accent
                                     : config.appearance.textSecondary)
                    .frame(width: 24, height: 24)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(model.name)
                            .font(.body)
                            .foregroundColor(config.appearance.textPrimary)
                        if model.supportsThinking {
                            Text("Thinking")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(config.appearance.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(config.appearance.accent.opacity(0.15))
                                )
                        }
                    }
                    if let desc = model.description, !desc.isEmpty {
                        Text(desc)
                            .font(.footnote)
                            .foregroundColor(config.appearance.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.name) by \(prettyProviderName(model.provider))")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func pickerStatusRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(config.appearance.textSecondary)
            Text(text)
                .font(.footnote)
                .foregroundColor(config.appearance.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// Group models by provider while preserving the server's ordering
    /// within each provider section. First-seen provider order wins so
    /// the runtime can surface its preferred bucket at the top.
    private func groupedModels(_ models: [AgentModel]) -> [(provider: String, models: [AgentModel])] {
        var order: [String] = []
        var buckets: [String: [AgentModel]] = [:]
        for m in models {
            if buckets[m.provider] == nil {
                order.append(m.provider)
                buckets[m.provider] = []
            }
            buckets[m.provider, default: []].append(m)
        }
        return order.map { (provider: $0, models: buckets[$0] ?? []) }
    }

    private func prettyProviderName(_ provider: String) -> String {
        switch provider.lowercased() {
        case "openai": return "OpenAI"
        case "anthropic": return "Anthropic"
        case "google", "gemini", "vertex_ai": return "Google"
        default: return provider.capitalized
        }
    }
}
