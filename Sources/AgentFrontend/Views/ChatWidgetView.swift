import SwiftUI
import AgentClient

/// Main chat widget view — provides the chat flow (messages, error banner, input).
/// Navigation, headers, and sidebars are app-level concerns.
/// See TEMPLATE_APP_SETUP.md for a full ChatGPT-style app scaffold.
public struct ChatWidgetView: View {
    @ObservedObject var viewModel: ChatViewModel
    let config: ChatWidgetConfig
    @State private var showSystemPicker = false
    /// TTS controller, created lazily on first appear so the view can be
    /// previewed without a backend. Bound to the viewModel so SSE events
    /// flow into voice playback.
    @StateObject private var voiceController: VoiceController

    public init(
        viewModel: ChatViewModel,
        config: ChatWidgetConfig,
        apiClient: APIClient? = nil,
        voiceController: VoiceController? = nil
    ) {
        self.viewModel = viewModel
        self.config = config
        // Build the controller up front: ``StateObject`` only honours its
        // initial value on first creation, so we have to resolve the
        // provider here. Host apps that need a custom provider pass one
        // in explicitly via ``voiceController``.
        let initial: VoiceController
        if let injected = voiceController {
            initial = injected
        } else if let api = apiClient,
                  let built = VoiceFactory.makeController(config: config, apiClient: api) {
            initial = built
        } else {
            initial = VoiceController(provider: AVSpeechTTSProvider(), enabled: config.enableTTS)
        }
        _voiceController = StateObject(wrappedValue: initial)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Messages list
            MessageListView(
                messages: viewModel.messages,
                isLoading: viewModel.isLoading,
                hasMoreMessages: viewModel.hasMoreMessages,
                loadingMoreMessages: viewModel.loadingMoreMessages,
                config: config,
                onLoadMore: {
                    Task { await viewModel.loadMoreMessages() }
                },
                onRetry: { index in
                    Task { await viewModel.retryMessage(at: index) }
                },
                onEdit: { index, content in
                    Task { await viewModel.editMessage(at: index, newContent: content) }
                }
            )

            // Error display
            if let error = viewModel.error {
                ErrorBannerView(message: error) {
                    viewModel.error = nil
                }
            }

            // System picker / TTS toggle row — bottom-right, above input
            if config.showSystemPicker || config.showTTSButton {
                HStack {
                    // Show current system name if selected
                    if config.showSystemPicker,
                       let slug = viewModel.selectedSystemSlug,
                       let system = viewModel.systems.first(where: { $0.slug == slug }) {
                        Text(system.name)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        if let version = system.activeVersion {
                            Text("v\(version)")
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                    }

                    Spacer()

                    // TTS toggle: shows speaker icon, fills/animates while
                    // playback is active. Tapping toggles ``enableTTS`` on
                    // the controller — disabling cuts off any in-flight
                    // audio so the user isn't trapped listening to the rest.
                    if config.showTTSButton {
                        Button(action: { voiceController.setEnabled(!voiceController.isEnabled) }) {
                            Image(systemName: ttsIconName)
                                .font(.body)
                                .foregroundColor(voiceController.isEnabled ? config.primaryColor : .secondary)
                                .padding(8)
                                .background(PlatformColors.systemGray6)
                                .clipShape(Circle())
                        }
                        .accessibilityLabel(voiceController.isEnabled ? "Disable voice output" : "Enable voice output")
                    }

                    if config.showSystemPicker {
                        Button(action: { showSystemPicker = true }) {
                            Image(systemName: "gearshape")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .padding(8)
                                .background(PlatformColors.systemGray6)
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }

            // Input form
            InputView(
                config: config,
                isLoading: viewModel.isLoading,
                onSend: { content, files in
                    Task { await viewModel.sendMessage(content, files: files) }
                },
                onCancel: {
                    Task { await viewModel.cancelRun() }
                }
            )
        }
        // Auto-restore saved conversation on launch (paginated, not full history)
        .task {
            // Bind the voice controller to the viewModel so SSE deltas
            // flow into TTS playback. The controller already mirrors
            // ``config.enableTTS`` so this is a no-op when disabled.
            viewModel.voiceController = voiceController

            print("[📜 ChatWidgetView] .task fired — calling restoreConversationIfNeeded()")
            await viewModel.restoreConversationIfNeeded()
            print("[📜 ChatWidgetView] .task complete — messages.count=\(viewModel.messages.count)")

            // Load systems if picker is enabled
            if config.showSystemPicker {
                await viewModel.loadSystems()
            }
        }
        .sheet(isPresented: $showSystemPicker) {
            SystemPickerView(
                systems: viewModel.systems,
                selectedSystemSlug: viewModel.selectedSystemSlug,
                selectedVersion: viewModel.selectedSystemVersion,
                isLoading: viewModel.isLoadingSystems,
                onSelectSystem: { system in
                    viewModel.selectSystem(system)
                },
                onSelectVersion: { version in
                    viewModel.selectSystemVersion(version)
                }
            )
        }
    }

    /// Speaker icon: filled when speech is enabled, ``.3`` waves while
    /// playback is in flight, slashed when muted.
    private var ttsIconName: String {
        if !voiceController.isEnabled { return "speaker.slash.fill" }
        return voiceController.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2.fill"
    }
}

/// Error banner view
struct ErrorBannerView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            Text(message)
                .font(.caption)
                .foregroundColor(.red)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
    }
}

#if DEBUG
struct ChatWidgetView_Previews: PreviewProvider {
    static var previews: some View {
        let config = ChatWidgetConfig()
        let storage = InMemoryStorage()
        let apiClient = APIClient(config: config, storage: storage)
        let viewModel = ChatViewModel(config: config, apiClient: apiClient, storage: storage)

        ChatWidgetView(viewModel: viewModel, config: config, apiClient: apiClient)
    }
}
#endif

