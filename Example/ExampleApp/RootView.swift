import SwiftUI
import AgentFrontend

/// Top-level view: builds the `ChatViewModel` once with `InMemoryStorage`
/// (so each launch is a clean slate for tests), shows the `ChatWidgetView`,
/// and optionally fires a single auto-send on appear so XCUITest doesn't
/// need to drive the keyboard.
struct RootView: View {
    let host: HostConfiguration
    @StateObject private var holder: ViewModelHolder

    init(host: HostConfiguration) {
        self.host = host
        _holder = StateObject(wrappedValue: ViewModelHolder(host: host))
    }

    var body: some View {
        ChatWidgetView(viewModel: holder.viewModel, config: holder.config)
            .accessibilityIdentifier("AgentChatRoot")
            .task {
                guard host.autoSendOnLaunch, !holder.didAutoSend else { return }
                holder.didAutoSend = true
                await holder.viewModel.sendMessage(host.autoSendPrompt, files: [])
                // Replay scripted follow-up user turns one at a time. Each
                // `await sendMessage(...)` now suspends until the SSE stream
                // for that turn reaches a terminal event, so the next turn
                // is never rejected by `guard !isLoading` inside ChatViewModel.
                for follow in host.autoSendFollowUps {
                    if follow.delayMs > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(follow.delayMs) * 1_000_000)
                    }
                    await holder.viewModel.sendMessage(follow.prompt, files: [])
                }
            }
    }
}

/// Holds the `ChatViewModel` so SwiftUI doesn't tear it down across body
/// re-evaluations and so the auto-send flag survives across `.task` calls.
@MainActor
final class ViewModelHolder: ObservableObject {
    let config: ChatWidgetConfig
    let viewModel: ChatViewModel
    var didAutoSend: Bool = false

    init(host: HostConfiguration) {
        let cfg = host.makeWidgetConfig()
        let storage = InMemoryStorage()
        let api = APIClient(config: cfg, storage: storage)
        self.config = cfg
        self.viewModel = ChatViewModel(config: cfg, apiClient: api, storage: storage)
    }
}
