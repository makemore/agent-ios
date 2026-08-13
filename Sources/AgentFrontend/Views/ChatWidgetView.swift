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
    /// Drives the transient "Copied" confirmation over the transcript.
    @State private var copyConfirmationVisible = false
    /// Incremented per copy so a second copy while the toast is still up
    /// restarts the dismiss timer instead of the first one cutting the
    /// second one short.
    @State private var copyConfirmationToken = 0
    /// TTS controller, created lazily on first appear so the view can be
    /// previewed without a backend. Bound to the viewModel so SSE events
    /// flow into voice playback.
    @StateObject private var voiceController: VoiceController
    /// Id of the message whose text was last handed to the voice
    /// controller by the per-message speaker button. Only meaningful
    /// while ``voiceController.isSpeaking``; cleared when playback ends
    /// so the row's stop button reverts to a speaker on its own.
    @State private var speakingMessageId: String? = nil
    /// Index and working text of the user message being edited, or `nil`.
    /// While set, ``EditMessageCard`` replaces the composer; sending
    /// commits via ``ChatViewModel.editMessage(at:newContent:)``, which
    /// truncates the transcript and restarts the conversation from that
    /// point.
    @State private var editingMessageIndex: Int? = nil
    @State private var editingText: String = ""
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
        } else {
            initial = VoiceFactory.makeController(
                config: config,
                apiClient: apiClient,
                voiceId: config.voiceId,
                modelId: config.voiceModelId
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

    /// Flash the "Message copied" confirmation over the transcript.
    ///
    /// The token guard means copying a second message while the first
    /// toast is still on screen restarts the dwell rather than letting
    /// the earlier timer dismiss the newer confirmation early.
    private func showCopyConfirmation() {
        copyConfirmationToken += 1
        let token = copyConfirmationToken
        copyConfirmationVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard copyConfirmationToken == token else { return }
            copyConfirmationVisible = false
        }
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

            // Context-usage banner. Server-driven: renders only when
            // the runtime has shipped at least one `context.usage`
            // event for this conversation (i.e. `contextTokens` is
            // non-nil on the view model). The denominator and
            // progress bar appear when the runtime also shipped a
            // `context_window` for the active model. There is no
            // client-side estimation — the banner stays hidden until
            // the server has something to show.
            if let tokens = viewModel.contextTokens {
                ContextUsageBanner(
                    totalTokens: tokens,
                    contextWindow: viewModel.contextWindow,
                    modelId: viewModel.contextModelId
                )
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
                onBeginEdit: { index, content in
                    editingText = content
                    editingMessageIndex = index
                },
                // Toggle: tapping the speaker on the playing message stops
                // it; tapping any other message switches playback to that
                // one. `stop()` also clears the turn-failed latch, so
                // replaying still works after a provider error earlier in
                // the same turn. Playback never touches the composer — the
                // user keeps typing and sending while a message plays.
                onSpeak: effectiveConfig.enableTTS ? { message in
                    if speakingMessageId == message.id, voiceController.isSpeaking {
                        voiceController.stop()
                        speakingMessageId = nil
                    } else {
                        voiceController.stop()
                        // With the global mute toggle gone, an explicit
                        // play tap is the "try again" affordance: it
                        // clears the session-wide unavailable latch a
                        // provider failure may have set, so playback can
                        // recover without an app restart.
                        voiceController.setEnabled(true)
                        speakingMessageId = message.id
                        voiceController.finishTurn(finalText: message.content)
                    }
                } : nil,
                speakingMessageId: voiceController.isSpeaking ? speakingMessageId : nil,
                onCopy: { showCopyConfirmation() },
                activity: viewModel.subAgentActivity,
                agentIsSpeaking: voiceController.isSpeaking,
                onBlockAction: { action in
                    handleBlockAction(action)
                }
            )
            .onChange(of: voiceController.isSpeaking) { speaking in
                if !speaking { speakingMessageId = nil }
            }

            // Error display
            if let error = viewModel.error {
                ErrorBannerView(message: error) {
                    viewModel.error = nil
                }
            }

            // System picker row — bottom-right, above input
            if config.showSystemPicker {
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
            if let editIndex = editingMessageIndex {
                EditMessageCard(
                    appearance: effectiveConfig.appearance,
                    text: $editingText,
                    onSend: {
                        let content = editingText
                        editingMessageIndex = nil
                        editingText = ""
                        Task { await viewModel.editMessage(at: editIndex, newContent: content) }
                    },
                    onCancel: {
                        editingMessageIndex = nil
                        editingText = ""
                    }
                )
            } else {
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
        }
        .overlay(alignment: .top) {
            if copyConfirmationVisible {
                CopyConfirmationToast(appearance: effectiveConfig.appearance)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    // Never intercept taps — it sits over the transcript.
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: copyConfirmationVisible)
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


            AgentLog.debug(.lifecycle, "[ChatWidgetView] .task fired — restoreConversationIfNeeded()")
            await viewModel.restoreConversationIfNeeded()
            AgentLog.debug(.lifecycle, "[ChatWidgetView] .task complete — messages.count=\(viewModel.messages.count)")

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


/// Transient "Copied" confirmation shown over the top of the transcript.
///
/// Exists because copying a message was previously silent: a successful
/// copy and a tap that missed the icon looked identical, so the button
/// read as broken. Purely presentational — the copy itself happens in
/// ``MessageView``.
private struct CopyConfirmationToast: View {
    let appearance: ChatAppearance

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
            Text("Message copied")
                .font(.caption)
        }
        .foregroundColor(appearance.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                // `assistantBubble` is optional in ChatAppearance — fall
                // back to the themed surface so the toast is never
                // transparent against the transcript.
                .fill(appearance.assistantBubble ?? appearance.background)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Message copied")
    }
}
