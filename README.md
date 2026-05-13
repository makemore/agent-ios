# AgentFrontend (iOS)

A SwiftUI chat widget package for AI agents. iOS equivalent of the `agent-frontend` JavaScript library.

**Requires:** iOS 16+ / macOS 13+ · Swift 5.9+

## Headless/API surface and reusable primitives

The package ships two products:

- `AgentClient`: product-neutral runtime client, models, SSE transport, `ChatViewModel`, local history, pagination, cancellation, and voice helpers.
- `AgentFrontend`: reusable SwiftUI primitives and the bundled widget. Host apps can use `MessageListView`, `MessageView`, `InputView`, `ContentBlockViews`, `TaskListView`, and `SystemPickerView` directly to build their own shell.

`ChatViewModel.runState` exposes the canonical lifecycle: `idle`, `sending`, `streaming`, `waiting`, `cancelling`, `cancelled`, `failed`, `succeeded`. `waiting` is used for `run.suspended` and `client.action.required` so mobile UI does not remain stuck in a loading state.

Supported visible event primitives include assistant deltas/messages, tool calls/results, content blocks, cancellations/failures/success, memory updates, sub-agent markers, and generic required-action cards. `AgentStreamEvent` and `AgentRunReducerState` provide headless typed parsing/reducer primitives for custom clients that do not want the bundled `ChatViewModel`. The shared backend contract is documented in `agent/docs/mobile-protocol-contract.md`.

The library boundary is intentionally generic: AgentClient owns agent stream events, SSE lifecycle, reducer state, tool/required-action semantics, fixtures, and tests. Host products own navigation, push notifications, integrations UI, branding, terminal sessions, and app-specific persistence.

## Installation

### Local Package (recommended for development)

In Xcode: **File → Add Package Dependencies → Add Local...** → select the `agent-ios` folder.

Or in your app's `Package.swift`:

```swift
dependencies: [
    .package(path: "/path/to/agent-ios"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "AgentFrontend", package: "AgentFrontend"),
        ]
    ),
]
```

## Quick Start

```swift
import SwiftUI
import AgentFrontend

struct ContentView: View {
    var body: some View {
        AgentFrontend.createChatWidget(
            config: .make(
                backendUrl: "https://your-api.com",
                agentKey: "your-agent-key"
            )
        )
    }
}
```

## Presenting as a Sheet or Full Screen

```swift
struct MyView: View {
    @State private var showChat = false

    let config = ChatWidgetConfig.make(
        backendUrl: "https://your-api.com",
        agentKey: "your-agent-key",
        title: "Support Chat"
    )

    var body: some View {
        Button("Open Chat") { showChat = true }
            .chatSheet(isPresented: $showChat, config: config)
            // or on iOS: .chatFullScreen(isPresented: $showChat, config: config)
    }
}
```

## Configuration

```swift
var config = ChatWidgetConfig(
    backendUrl: "https://your-api.com",
    agentKey: "your-agent-key"
)

// UI
config.title = "My Assistant"
config.subtitle = "How can I help?"
config.primaryColor = Color(hex: "#FF6600")
config.placeholder = "Ask me anything..."

// Features
config.showTasksTab = true
config.showModelSelector = false
config.enableFiles = true
config.enableVoice = true

// Authentication
config.authStrategy = .jwt
config.authToken = "your-jwt-token"

// Custom API paths
config.apiPaths = APIPaths(
    conversations: "/api/v2/conversations/",
    runs: "/api/v2/runs/"
)
```

### Auth Strategies

| Strategy    | Description                          |
|-------------|--------------------------------------|
| `.token`    | Django REST `Token {token}` header   |
| `.jwt`      | Bearer token `Bearer {token}` header |
| `.session`  | Cookie-based session auth            |
| `.anonymous`| Auto-fetched anonymous session token |
| `.none`     | No authentication                    |

## Custom ViewModel (Advanced)

For building your own UI on top of the chat logic:

```swift
struct CustomChatView: View {
    @StateObject private var viewModel: ChatViewModel

    init(config: ChatWidgetConfig) {
        let vm = AgentFrontend.createViewModel(config: config)
        _viewModel = StateObject(wrappedValue: vm)
    }

    var body: some View {
        VStack {
            ForEach(viewModel.messages) { message in
                Text(message.content)
            }
            Button("Send") {
                Task { await viewModel.sendMessage("Hello") }
            }
        }
        .task { await viewModel.loadInitialData() }
    }
}
```

## Custom Storage

Implement `StorageService` to replace the default `UserDefaults` persistence:

```swift
class KeychainStorage: StorageService {
    func get(_ key: String) -> String? { /* read from keychain */ }
    func set(_ key: String, value: String?) { /* write to keychain */ }
}

let widget = AgentFrontend.createChatWidget(
    config: config,
    storage: KeychainStorage()
)
```

## Two Products

The package ships two library products:

| Product | What it contains | Depends on |
|---------|-----------------|------------|
| **AgentClient** | Models, networking, SSE, configuration, storage | Foundation only |
| **AgentFrontend** | SwiftUI chat widget + view layer | AgentClient |

Existing consumers that `import AgentFrontend` continue to work unchanged — AgentFrontend re-exports AgentClient's types transitively.

To use only the headless core (e.g. to build a custom UI):

```swift
dependencies: [
    .package(path: "/path/to/agent-ios"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "AgentClient", package: "AgentFrontend"),
        ]
    ),
]
```

## Project Structure

```
Sources/AgentClient/
├── Configuration/               # ChatWidgetConfig, APIPaths, AuthStrategy
├── Models/                      # Message, Conversation, AgentModel, ContentBlock
├── Networking/                  # APIClient, SSEClient, APIError
├── Services/                    # StorageService protocol + implementations
├── Utilities/                   # Color+Hex
└── ViewModels/                  # ChatViewModel

Sources/AgentFrontend/
├── AgentFrontend.swift          # Public API entry point
├── Utilities/                   # PlatformColors
└── Views/                       # ChatWidgetView, MessageView, InputView, etc.
```


## Changelog

### 0.7.0

**Voice subsystem & Live Mic**

- **`AgentClient/Voice` module** — new `TTSProvider` abstraction with `ElevenLabsTTSProvider` (streaming) and `AVSpeechTTSProvider` (on-device fallback) implementations, a `SentenceChunker` that splits assistant deltas into playable units, and a `VoiceController` that owns the playback queue and exposes `isSpeaking` to the UI. `ChatViewModel` pipes `assistant.delta` and `assistant.message` events into the controller; `ChatWidgetView` wires it through automatically when `config.enableVoice` is true.
- **Audio session handling** — `ElevenLabsTTSProvider` configures `AVAudioSession` to `.playAndRecord` with `.defaultToSpeaker` + `.duckOthers` before each `play()`, so TTS is no longer silenced by the default `.soloAmbient` category and coexists with the mic capture flow. The provider preserves `.voiceChat` mode when set by the input layer (required for hardware acoustic echo cancellation during barge-in) and falls back to `.spokenAudio` for higher-fidelity playback when not.
- **Live Mic — auto-send** — when `autoSendEnabled` is on (persisted in `@AppStorage("voice.autoSend")`), a mic-initiated turn auto-submits after 3 s of silence and re-arms the recogniser the moment the agent finishes speaking, giving a hands-free conversation loop.
- **Live Mic — barge-in** — the user can interrupt agent TTS playback by speaking. Implemented as a *monitor* `SFSpeechRecognizer` that runs alongside playback (separate from the main recognition request so partials don't pollute `inputText`). Each monitor partial is diffed against `VoiceController.recentSpokenText` (a rolling 1500-char buffer of what the agent has actually queued for playback) using a tokenized novel-word count; barge-in fires when the user produces ≥ 2 words not in the agent's recent text. Hardware AEC (via `.voiceChat` mode) handles most leak-back; the text-overlap filter catches what the AEC misses, especially on simulator where there is no hardware AEC at all.
- **Manual stop button** — the send button is now three-state: cancel-run while a request is in flight, **stop-agent** while the agent is speaking (user-initiated barge-in that always fires regardless of recogniser state), send otherwise. Provides a guaranteed interrupt path that doesn't depend on the speech model.
- **Always-on audio engine** — the `AVAudioEngine` stays running across turns; only the `SFSpeechAudioBufferRecognitionRequest` is recycled on submit and on agent-speaking transitions. Eliminates engine restart latency between turns and avoids a class of crashes where the engine was started without a node connection.
- **Example app schemes** — replaced the in-app URL settings with Xcode schemes (`Local runserver` / `Local ngrok`) that inject `BACKEND_URL` / `AGENT_KEY` / `ENABLE_VOICE` via environment. New "Voice chat (TTS + mic)" and "Voice playback (TTS only)" scenarios; mic + speech-recognition entitlements added to `Info.plist`.

### 0.6.0

**Core / UI split**

- **Two library products** — the package now ships `AgentClient` (models, networking, SSE, configuration, storage, view models) and `AgentFrontend` (SwiftUI views). Existing consumers that depend on `AgentFrontend` are unaffected. New consumers can depend on `AgentClient` alone to build a custom UI without pulling in SwiftUI views.

### 0.5.1

**Full-screen video playback**

- **`VideoBlockView` full-screen mode** — video blocks now render with an expand control that promotes playback to a full-screen cover. The same `AVPlayer` instance is shared between inline and full-screen presentations so playback position and state are preserved across the transition.
- **`ChatWidgetConfig.onVideoFullScreenChange`** — new optional closure on `ChatWidgetConfig` fires with `true` when a video enters full-screen and `false` when it exits. The `ContentBlockRenderer` threads this down into every `VideoBlockView` it renders, so host apps only need to set it in one place. Host apps can use this to manage orientation locks or other chrome; orientation handling is deliberately left to the host.

### 0.5.0

**Rich-content persistence & sub-agent echo suppression**

- **Content blocks persist across reload** — video cards, widgets, and other rich tool-result blocks are now reconstructed from message metadata when a conversation is reloaded, matching what was shown during the live session. Requires `agent-runtime-core >= 0.10.6`, which stores `contentBlocks` on the tool message's `metadata`.
- **Sub-agent echo suppression** — after a sub-agent finishes streaming its final answer the parent agent typically re-streams the same text verbatim as its own deltas. The client now snapshots the sub-agent's last streamed content at `sub_agent.end` and silently buffers parent deltas while they still match the snapshot as a prefix, suppressing the duplicate bubble. If the parent genuinely diverges or extends past the snapshot, only the novel tail renders as a fresh bubble.
- **Turn finalisation watermark** — drops late-arriving `assistant.delta` events after an authoritative `assistant.message` has landed for the same turn. Prevents a second bubble from materialising with content we've already shown in full.

### 0.4.0

**Scroll redesign & streaming fixes**

- **Principled scroll state machine** — replaced ad-hoc scroll logic with a single `ScrollDecision` engine. Fixes the submit-time fly-off where messages would jump out of view when the keyboard dismissed.
- **Keyboard-dismiss animation delay** — waits past the keyboard-hide animation before pinning to bottom on submit, preventing a visual snap.
- **Cancel stops typewriter buffer** — pressing cancel now immediately halts the streaming drain timer; previously buffered text continued to type out after cancellation.
- **Finalize streaming bubble before non-delta events** — sub-agent start/end, tool calls, and content blocks now flush the active streaming buffer before inserting their message, preventing orphaned partial-text bubbles that duplicated the response.
- **Track streaming message by ID** — the in-flight streaming message is located by its tracked ID rather than assuming it is `messages.last`. Fixes a duplicate bubble when `assistant.message` arrived after content blocks (e.g. a video card) had been appended after the streaming bubble.