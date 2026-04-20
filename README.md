# AgentFrontend (iOS)

A SwiftUI chat widget package for AI agents. iOS equivalent of the `agent-frontend` JavaScript library.

**Requires:** iOS 16+ / macOS 13+ · Swift 5.9+

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

## Project Structure

```
Sources/AgentFrontend/
├── AgentFrontend.swift          # Public API entry point
├── Configuration/               # ChatWidgetConfig, APIPaths, AuthStrategy
├── Models/                      # Message, Conversation, AgentModel, TaskItem
├── Networking/                  # APIClient, SSEClient, APIError
├── Services/                    # StorageService protocol + implementations
├── Utilities/                   # Color+Hex, PlatformColors
├── ViewModels/                  # ChatViewModel
└── Views/                       # ChatWidgetView, MessageView, InputView, etc.
```


## Changelog

### 0.5.1

**Full-screen video playback**

- **`VideoBlockView` full-screen mode** — video blocks now render with an expand control that promotes playback to a full-screen cover. The same `AVPlayer` instance is shared between inline and full-screen presentations so playback position and state are preserved across the transition.
- **`onFullScreenChange` callback** — new optional closure on `VideoBlockView` fires with `true` when entering full-screen and `false` when exiting. Host apps can use this to manage orientation locks or other chrome; orientation handling is deliberately left to the host.

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