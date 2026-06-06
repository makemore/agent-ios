import SwiftUI
import AgentClient

/// Published by ``ChatWidgetView`` with the measured height of the
/// composer (input) area, including its surrounding padding. Host apps
/// that overlay their own chrome above the input bar — e.g. an
/// empty-state action button floated at the bottom of the chat — read
/// this via `.onPreferenceChange(ChatComposerHeightPreferenceKey.self)`
/// so the overlay rises as the multi-line composer grows instead of
/// colliding with it. Reports `0` until the first layout pass.
public struct ChatComposerHeightPreferenceKey: PreferenceKey {
    public static let defaultValue: CGFloat = 0
    public static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // Single composer, but keep the larger value defensively so a
        // transient zero during a layout pass can't collapse the offset.
        value = max(value, nextValue())
    }
}

/// Main chat widget view — provides the chat flow (messages, error banner, input).
/// Navigation, headers, and sidebars are app-level concerns.
/// See TEMPLATE_APP_SETUP.md for a full ChatGPT-style app scaffold.
public struct ChatWidgetView: View {
    @ObservedObject var viewModel: ChatViewModel
    let config: ChatWidgetConfig
    /// APIClient is now retained so the sidebar's recents list can fetch
    /// `loadConversations()` without the host having to pass a second copy.
    let apiClient: APIClient?
    @State private var showSystemPicker = false
    @State private var showSidebar = false
    /// Drives presentation of `ModelOptionsSheet` when the user taps
    /// the model pill in the anthropic composer. Lives at the widget
    /// level (not inside `InputView`) so the sheet is anchored to the
    /// whole screen and the input view stays purely about the composer.
    @State private var showModelOptions = false
    /// TTS controller, created lazily on first appear so the view can be
    /// previewed without a backend. Bound to the viewModel so SSE events
    /// flow into voice playback.
    @StateObject private var voiceController: VoiceController
    /// Optional host hook fired when the user taps a ``BlockAction``
    /// inside a rendered ``ContentBlock``. The widget supplies a
    /// default handler that auto-sends `type == "message"` actions
    /// as a real user turn and opens `type == "link"` URLs; the
    /// host hook is called for `"callback"` actions (and for any
    /// action whose type the default handler doesn't recognise) so
    /// app-specific logic (analytics, navigation, custom triggers)
    /// can live in the host without re-implementing the common cases.
    private let onBlockAction: ((BlockAction) -> Void)?

    public init(
        viewModel: ChatViewModel,
        config: ChatWidgetConfig,
        apiClient: APIClient? = nil,
        voiceController: VoiceController? = nil,
        onBlockAction: ((BlockAction) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.config = config
        self.apiClient = apiClient
        self.onBlockAction = onBlockAction
        // Build the controller up front: ``StateObject`` only honours its
        // initial value on first creation, so we have to resolve the
        // provider here. Host apps that need a custom provider pass one
        // in explicitly via ``voiceController``.
        let initial: VoiceController
        if let injected = voiceController {
            initial = injected
        } else if let api = apiClient,
                  let built = VoiceFactory.makeController(
                      config: config,
                      apiClient: api,
                      voiceId: config.voiceId,
                      modelId: config.voiceModelId
                  ) {
            initial = built
        } else {
            initial = VoiceController(
                provider: AVSpeechTTSProvider(voiceIdentifier: config.voiceId),
                enabled: config.enableTTS
            )
        }
        _voiceController = StateObject(wrappedValue: initial)
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            mainStack
            if config.sidebar.enabled && showSidebar {
                ChatSidebarView(
                    viewModel: viewModel,
                    config: config,
                    apiClient: apiClient,
                    onDismiss: { withAnimation(.easeOut(duration: 0.2)) { showSidebar = false } },
                    onNewChat: {
                        viewModel.clearMessages()
                        withAnimation(.easeOut(duration: 0.2)) { showSidebar = false }
                    },
                    onSelectConversation: { conv in
                        Task { await viewModel.loadConversation(conv.id) }
                        withAnimation(.easeOut(duration: 0.2)) { showSidebar = false }
                    }
                )
                .transition(.move(edge: .leading))
                .zIndex(2)
            }
        }
        .background(config.appearance.background.ignoresSafeArea())
    }

    /// UI-facing config after applying view-model runtime preferences.
    ///
    /// `ChatViewModel` is the source of truth for whether verbose
    /// multi-agent mode is active. The reducer already uses its effective
    /// `subAgentActivityStyle`; pass the same style into child views so
    /// rendering stays in lockstep with the messages/state the reducer
    /// produced.
    private var effectiveConfig: ChatWidgetConfig {
        var effective = config
        effective.appearance.subAgentActivityStyle = viewModel.subAgentActivityStyle
        return effective
    }

    private var mainStack: some View {
        VStack(spacing: 0) {
            // Built-in top bar (hamburger + new-chat pencil). Hosts
            // that provide their own navigation chrome set
            // `config.showInternalTopBar = false` and surface
            // equivalents themselves.
            if config.showInternalTopBar {
                anthropicTopBar
            }

            // Messages list. `agentIsSpeaking` propagates the TTS
            // playback state to the latest assistant row so its avatar
            // glows while audio is in flight. The S'Ai orb is rendered
            // as a per-message avatar inside `MessageView` (gated by
            // `config.showPresenceOrb`) rather than as a fixed row
            // above the list, so it stays anchored to the assistant's
            // identity in the scrollback instead of floating at the
            // top of the chrome.
            MessageListView(
                messages: viewModel.messages,
                isLoading: viewModel.isLoading,
                hasMoreMessages: viewModel.hasMoreMessages,
                loadingMoreMessages: viewModel.loadingMoreMessages,
                config: effectiveConfig,
                onLoadMore: {
                    Task { await viewModel.loadMoreMessages() }
                },
                onRetry: { index in
                    Task { await viewModel.retryMessage(at: index) }
                },
                onEdit: { index, content in
                    Task { await viewModel.editMessage(at: index, newContent: content) }
                },
                activity: viewModel.subAgentActivity,
                agentIsSpeaking: voiceController.isSpeaking,
                onBlockAction: { action in
                    handleBlockAction(action)
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
                isAgentSpeaking: voiceController.isSpeaking,
                voiceController: voiceController,
                onSend: { content, files in
                    // Forward the per-conversation extended-thinking
                    // toggle so a user flip in `ModelOptionsSheet`
                    // takes effect on the next turn without the host
                    // having to thread the flag through itself.
                    Task {
                        await viewModel.sendMessage(
                            content,
                            files: files,
                            thinking: viewModel.extendedThinking
                        )
                    }
                },
                onCancel: {
                    Task { await viewModel.cancelRun() }
                },
                onModelPillTap: { showModelOptions = true },
                modelPillLabelOverride: viewModel.selectedModelDisplayName,
                viewModel: viewModel
            )
            // Publish the composer's rendered height so host overlays (e.g. an
            // empty-state Sessions button) can sit above it and track its
            // growth across multi-line input. See ``ChatComposerHeightPreferenceKey``.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ChatComposerHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            )
        }
        // Auto-restore saved conversation on launch (paginated, not full history)
        .task {
            // Bind the voice controller to the viewModel so SSE deltas
            // flow into TTS playback. The controller already mirrors
            // ``config.enableTTS`` so this is a no-op when disabled.
            viewModel.voiceController = voiceController
            // Signal to the host that voice is wired up. Hosts use
            // this to fire scripted opening turns (welcome line +
            // action buttons) at the exact moment TTS can play, with
            // no polling and no timing guesswork.
            config.onVoiceControllerReady?(viewModel)


            print("[📜 ChatWidgetView] .task fired — calling restoreConversationIfNeeded()")
            await viewModel.restoreConversationIfNeeded()
            print("[📜 ChatWidgetView] .task complete — messages.count=\(viewModel.messages.count)")

            // Load systems if picker is enabled
            if config.showSystemPicker {
                await loadModelsAndSystemsInParallel()
            } else {
                // Even without the system picker we still want the
                // model catalogue so the composer pill and
                // `ModelOptionsSheet` reflect the real options.
                await viewModel.loadModels()
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
        .sheet(isPresented: $showModelOptions) {
            ModelOptionsSheet(config: config, viewModel: viewModel)
        }
    }

    /// Speaker icon: filled when speech is enabled, ``.3`` waves while
    /// playback is in flight, slashed when muted.
    private var ttsIconName: String {
        if !voiceController.isEnabled { return "speaker.slash.fill" }
        return voiceController.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2.fill"
    }

    /// Top bar shown when `config.showInternalTopBar` is `true`. Left
    /// circular button opens the sidebar (only rendered when the
    /// sidebar overlay is enabled). Right circular button starts a
    /// fresh conversation (gated by `config.showNewChatButton`). Both
    /// are drawn on the surface colour so they pop against the
    /// warm-dark background without an outline.
    private var anthropicTopBar: some View {
        HStack {
            if config.sidebar.enabled {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showSidebar = true }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.body.weight(.medium))
                        .foregroundColor(config.appearance.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(config.appearance.surface)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Open conversations")
            }
            Spacer()
            if config.showNewChatButton {
                Button {
                    viewModel.clearMessages()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.body.weight(.medium))
                        .foregroundColor(config.appearance.textPrimary)
                        .frame(width: 40, height: 40)
                        .background(config.appearance.surface)
                        .clipShape(Circle())
                }
                .accessibilityLabel("New conversation")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Kick off the systems and models catalogue requests concurrently.
    /// Both are independent, both feed the composer UI, and neither
    /// blocks message send \u2014 so we let them race rather than serialising.
    private func loadModelsAndSystemsInParallel() async {
        async let systems: Void = viewModel.loadSystems()
        async let models: Void = viewModel.loadModels()
        _ = await (systems, models)
    }

    /// Default action router for ``BlockAction`` taps inside any
    /// rendered ``ContentBlock``. Keeps the common cases
    /// (`message`, `link`) inside the library so hosts only need to
    /// override for app-specific behaviour (e.g. `callback` IDs).
    private func handleBlockAction(_ action: BlockAction) {
        switch action.type {
        case "message":
            // Treat the tap as the user choosing this canned reply.
            // Prefer the explicit `message` payload for what the
            // model sees; fall back to the visible `label` so the
            // happy path still works when only one is supplied.
            let content = (action.message?.isEmpty == false ? action.message! : action.label)
            guard !content.isEmpty else { return }
            Task { await viewModel.sendMessage(content) }
        case "link":
            #if os(iOS)
            if let raw = action.url, let url = URL(string: raw) {
                UIApplication.shared.open(url)
            }
            #endif
        default:
            // `callback` (and any future type) is host-driven.
            onBlockAction?(action)
        }
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

