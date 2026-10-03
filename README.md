# AgentFrontend (iOS)

A SwiftUI chat widget package for AI agents. iOS equivalent of the `agent-frontend` JavaScript library.

**Requires:** iOS 16+ / macOS 13+ · Swift 5.9+

## Headless/API surface and reusable primitives

The package ships two products:

- `AgentClient`: product-neutral runtime client, models, SSE transport, `ChatViewModel`, local history, pagination, cancellation, and voice helpers.
- `AgentFrontend`: reusable SwiftUI primitives and the bundled widget. Host apps can use `MessageListView`, `MessageView`, `InputView`, `ContentBlockViews`, `TaskListView`, and `SystemPickerView` directly to build their own shell.

`ChatViewModel.runState` exposes the canonical lifecycle: `idle`, `sending`, `streaming`, `waiting`, `cancelling`, `cancelled`, `failed`, `succeeded`. `waiting` is used for `run.suspended` and `client.action.required` so mobile UI does not remain stuck in a loading state.

Supported visible event primitives include assistant deltas/messages, tool calls/results, content blocks, cancellations/failures/success, memory updates, sub-agent markers, and generic required-action cards. `AgentStreamEvent` and `AgentRunReducerState` provide headless typed parsing/reducer primitives for custom clients that do not want the bundled `ChatViewModel`. The shared backend contract is documented in `packages/python/django_agent_runtime/docs/mobile-protocol-contract.md`.

The library boundary is intentionally generic: AgentClient owns agent stream events, SSE lifecycle, reducer state, tool/required-action semantics, fixtures, and tests. Host products own navigation, push notifications, integrations UI, branding, terminal sessions, and app-specific persistence.

## Installation

The library is distributed via **Swift Package Manager** from the public
`makemore/agent-ios` repository, pinned to a version tag — **no token or
credentials required**. Use the latest tag from
[makemore/agent-ios/tags](https://github.com/makemore/agent-ios/tags).

### Swift Package Manager (recommended)

In Xcode: **File → Add Package Dependencies…** → paste
`https://github.com/makemore/agent-ios.git` → choose **Up to Next Major Version**
from `3.1.0` → add the **AgentFrontend** product to your app target.

Or in your app's `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/makemore/agent-ios.git", from: "3.1.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "AgentFrontend", package: "agent-ios"),
        ]
    ),
]
```

> **Public repo:** the repository is public, so SwiftPM (and CI) can clone it with
> no SSH key, PAT, or Xcode account configuration.

<details>
<summary><strong>Local package (for library development)</strong></summary>

To work against the library source instead of a tagged release, in Xcode use
**File → Add Package Dependencies → Add Local…** → select the `agent-ios` folder, or in
`Package.swift`:

```swift
dependencies: [
    .package(path: "/path/to/agent-ios"),
],
```

</details>

### Publishing a new release

See [RELEASING.md](RELEASING.md) for how to cut a version — for SwiftPM this is a
semver Git tag push (no artifact upload); consumers resolve the new tag directly.

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

// Appearance — new integrations should start from .recommended.
// Named presets: .classic (pre-0.8 look), .anthropic (warm-dark),
// .neutral (system-adaptive, unbranded), .resilientGold (RM house style).
config.appearance = .recommended

// Features
config.showTasksTab = true
config.showModelSelector = false
config.enableFiles = true
config.enableVoice = true
config.enableTTS = true
config.ttsProviderPolicy = .automatic

// Authentication
config.authStrategy = .jwt
config.authToken = "your-jwt-token"

// Custom API paths
config.apiPaths = APIPaths(
    conversations: "/api/v2/conversations/",
    runs: "/api/v2/runs/"
)
```

### Privacy-safe voice output

Normal mode keeps the existing remote/provider-backed voice behavior when the
Django voice proxy is configured:

```swift
config.enableTTS = true
config.ttsProviderPolicy = .automatic
```

Protected/private mode should use system TTS so assistant message text never
goes to ElevenLabs or another remote TTS provider:

```swift
config.privateOnly = true
config.enableTTS = true
config.ttsProviderPolicy = .localOnly
```

`privateOnly = true` also makes `.automatic` resolve to local/system TTS. In
that mode the library does not request `/voice/token/` and does not call
`/voice/tts/`. Host apps can inspect `VoiceController.voiceMode` to show states
such as “Using device voice in Protected AI Mode” or an unavailable reason.

Local/system voice quality depends on the OS, installed voices, and device; it
will not match ElevenLabs quality. Speech input also has a `speechInputPolicy`;
protected mode defaults to on-device recognition and disables the mic when the
OS cannot provide it.

### On-device neural voice (Kokoro)

The optional **`AgentKokoro`** product adds [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M)
v1.0, a small neural TTS model that sounds far more natural than the system
voice and runs entirely on the device. Assistant text never leaves the phone,
so it is suitable for Protected AI Mode; the only network traffic is the
one-time download of the model files. It is opt-in: nothing changes until the
host registers it.

The engine is Microsoft [ONNX Runtime](https://onnxruntime.ai) (full build, CPU)
running the Kokoro model, with our own English text-to-phoneme front end:
number/date/money normalisation, the misaki dictionaries, and a small BART
model (also ONNX) for words the dictionaries do not know. There is no
espeak-ng, sherpa-onnx or `phonemizer` anywhere. The front end follows the
cross-platform spec in the meta-repo, `tools/kokoro-assets/README.md`, and
passes all of its golden vectors, so the same text produces the same phonemes,
and the same voice id the same voice, on iOS, Android and the web widget.
iOS 16+ (the package's minimum); ONNX Runtime's Swift package requires
macOS 14, so the package's macOS minimum is 14.

Add the product next to `AgentFrontend` (or `AgentClient`):

```swift
.product(name: "AgentKokoro", package: "agent-ios"),
```

**Use it as the widget's on-device voice.** Register once at launch. From then
on, whenever the library resolves on-device speech (`.localOnly`, Protected AI
Mode, or `.automatic` without a voice proxy) it speaks with Kokoro instead of
`AVSpeechSynthesizer`. Policies are unchanged: `.disabled` still means no voice,
and a configured remote voice proxy still wins under `.automatic`/`.remote`.

```swift
import AgentKokoro

KokoroTTS.register()                 // e.g. in your App's init; engine id "kokoro"

var config = ChatWidgetConfig(backendUrl: "...", agentKey: "...")
config.enableTTS = true
config.ttsProviderPolicy = .localOnly
config.voiceId = "bf_emma"           // any Kokoro voice id; default "af_heart"
```

**Or build the controller yourself** and inject it:

```swift
let provider = KokoroTTSProvider(configuration: KokoroConfiguration(voice: "am_michael", speed: 1.1))
let voice = VoiceController(provider: provider)
ChatWidgetView(viewModel: viewModel, config: config, voiceController: voice)
```

**Configuration.** `KokoroConfiguration` has the same fields on every platform:
`baseURL` (default `https://storage.googleapis.com/makemore-voice-models/kokoro/v1/`,
our public copy of the asset set; point it at your own mirror of the same
files), `voice` (default `"af_heart"`) and `speed` (default `1.0`, 0.5–2.0),
plus `cacheDirectory`, `allowsCellularDownload` and `manifestSHA256`.
**`allowsCellularDownload` is `false` by default**: the ~97 MB download only
runs on Wi-Fi or wired networks (not cellular, a personal hotspot or Low Data
Mode) unless the host opts in; until then Kokoro speaks with the system voice.

**Download, verification and cache.** Nothing is bundled. The first time
Kokoro is asked to speak without its files it starts a one-time download (that
turn is spoken by the system voice). It fetches `manifest.json`, checks it
against the SHA-256 pinned in the library, then fetches only what the voice
needs and checks every file's size and SHA-256 against the manifest:

| Download | Size |
| --- | --- |
| Model (`kokoro-v1.0-q8.onnx`) + vocab | 92.4 MB |
| One voice pack | 0.52 MB |
| One language's G2P (gzip dictionaries, BART model, vocab) + `voices.json` | 1.4–1.5 MB dictionaries + 3.1 MB model |
| **Total, `en-us` voice (e.g. `af_heart`)** | **97.4 MB** (97,404,535 bytes + 21 KB manifest) |
| **Total, `en-gb` voice (e.g. `bf_emma`)** | **97.5 MB** (97,498,865 bytes + 21 KB manifest) |

The language comes from the voice id (`a*` = `en-us`, `b*` = `en-gb`); a second
language or voice adds only its own files. Files are cached by SHA-256 in
`Application Support/AgentKokoro` (excluded from iCloud backup). An interrupted
download resumes with an HTTP range request; files already verified are never
fetched again.

```swift
let model = KokoroTTS.modelManager           // or KokoroModelManager.shared
model.state      // .notDownloaded / .downloading / .loading / .ready / .failed(KokoroModelError)
model.onModelProgress = { p in print(p.fraction, p.bytesDownloaded, p.bytesTotal) }
try await model.prepare()                    // download + verify + load, idempotent
model.prefetch(voice: "bf_emma")             // the same in the background
let voices = try await model.voices()        // id, name, language, gender, grade, suggested
model.downloadedBytes                        // bytes on disk
try model.deleteDownloadedModel()            // free the space; next use downloads again

// Your own mirror, cellular allowed, no download on first use:
KokoroTTS.register(configuration: KokoroConfiguration(
    baseURL: URL(string: "https://cdn.example.com/kokoro/v1/")!,
    allowsCellularDownload: true), autoDownload: false)
```

`state` and `progress` are `@Published`, so a SwiftUI view can observe the
manager for a progress bar.

**Behaviour.** Each chunk from `VoiceController` is turned into phonemes and
synthesised on a background queue (never the main thread). Long text is cut
into pieces at punctuation: the first piece is kept short so audio starts
early, later pieces grow, and each piece's 24 kHz audio is scheduled on an
`AVAudioPlayerNode` behind the previous one, so playback is gapless while the
rest is synthesised. Chunks queued behind the one playing are synthesised ahead,
and the model loads in the background when a turn starts. `stop()` silences
audio immediately (generation stops after the current piece). Playback follows
the same `AVAudioSession` rules as the other providers
(`.playback`/`.spokenAudio`, leaves a hands-free session alone, never plays
during Live voice). If the files are missing, the model fails to load, or a
chunk fails, that turn is spoken by `AVSpeechTTSProvider` instead — the fallback
stays for the rest of the turn so a reply never switches voice mid-way — and a
content-free reason is logged and passed to `KokoroTTSProvider.onFallback`. Text
in scripts the English voices cannot read (Chinese, Japanese, Korean) also uses
the system voice.

**Measuring.** `KokoroTTSProvider.onSpeechMetrics` reports, per utterance,
`loadMs`, `firstAudioMs` (from `speak()` to the first buffer scheduled),
`chunkCount`, `audioSeconds` and `synthSeconds` (`realTimeFactor` is their
ratio); with `AGENT_LOG=voice` the same line is printed. In the iOS simulator
on an Apple M5 Mac (debug build, Mac shared with other heavy jobs, so numbers
varied): loading the model and the `en-us` G2P took 0.4–0.7 s; synthesis ran at
1.8–2.6× real time; for a two-sentence reply whose first piece is two seconds
of speech, the first audio was scheduled 0.8–1.3 s after `speak()` with the
model loaded (1.2–1.7 s including the load), and a chunk prefetched while the
previous one played started at once. It has not yet been measured on an
iPhone.

**Voices** (`KokoroVoice.all`, `KokoroTTS.voices`, `listVoices()`, or
`voices()` from the asset set):

| | Female | Male |
|---|---|---|
| American (`en-us`) | `af_heart` (default), `af_alloy`, `af_aoede`, `af_bella`, `af_jessica`, `af_kore`, `af_nicole`, `af_nova`, `af_river`, `af_sarah`, `af_sky` | `am_adam`, `am_echo`, `am_eric`, `am_fenrir`, `am_liam`, `am_michael`, `am_onyx`, `am_puck`, `am_santa` |
| British (`en-gb`) | `bf_alice`, `bf_emma` (suggested), `bf_isabella`, `bf_lily` | `bm_daniel`, `bm_fable`, `bm_george`, `bm_lewis` |

**Licences.** No GPL, AGPL or LGPL code or data is linked, bundled or
downloaded.

| Component | How it ships | Licence |
| --- | --- | --- |
| `AgentKokoro` sources, including our port of misaki's lexicon and hexgrad/kokoro's chunking | compiled into the app | Ours; the ported parts are Apache-2.0 (hexgrad), attributed in the source headers |
| [onnxruntime-swift-package-manager](https://github.com/microsoft/onnxruntime-swift-package-manager) 1.24.2 (Objective-C bindings) | compiled into the app | MIT |
| ONNX Runtime 1.24.2 `onnxruntime.xcframework` (pod archive `onnxruntime-c`, full build, static) | linked into the app | MIT. Third-party code inside, per its `ThirdPartyNotices.txt` and the symbols in the binary: ONNX (Apache-2.0), Protocol Buffers (BSD-3-Clause), Abseil (Apache-2.0), RE2 (BSD-3-Clause), FlatBuffers (Apache-2.0), nlohmann/json (MIT), Microsoft GSL (MIT), HowardHinnant/date (MIT), SafeInt (MIT), Boost.Mp11 (BSL-1.0), MLAS (MIT), XNNPACK (BSD-3-Clause), pthreadpool (BSD-2-Clause), cpuinfo (BSD-2-Clause), KleidiAI (Apache-2.0), coremltools protos/MILBlob/ModelPackage (BSD-3-Clause), MurmurHash3 (public domain), **Eigen (MPL-2.0, unmodified; approved by the owner)** |
| `onnxruntime-extensions` 0.13.0 xcframework | downloaded by SwiftPM with the package; **not linked** (we do not use the `onnxruntime_extensions` product) | MIT (its notices list no GPL/LGPL code) |
| kokoro/v1 asset set: Kokoro v1.0 q8 model, 28 voice packs, misaki dictionaries, our BART G2P export, vocab files | downloaded at runtime | Apache-2.0 (all 49 files; see the set's `NOTICE` and `manifest.json`) |
| Golden test vectors, manifest, vocab and voices JSON in `Tests/AgentKokoroTests/Resources` | tests only | Apache-2.0 (from the asset set) |

**No telemetry.** The pinned ONNX Runtime 1.24.2 Apple build has no telemetry
provider and no network code: its telemetry hooks are no-ops on Apple
platforms, and the binary references no sockets, `URLSession`, 1DS/OneCollector
client or Microsoft endpoint. (ONNX Runtime added optional POSIX telemetry in
1.29; `AgentKokoro` also sets `ORT_DISABLE_TELEMETRY=1`, unless the host set it,
before creating its environment, so a future version bump stays silent.) The
only network traffic is the asset download from `baseURL`.

Apps that do not import `AgentKokoro` do not compile or link any of it, but
SwiftPM still resolves the ONNX Runtime package and downloads its two binary
archives (about 70 MB, cached) for every consumer of this package, as it
already does for WhisperKit and WebRTC.

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

The package ships two library products, plus the optional `AgentKokoro`
voice (see [On-device neural voice](#on-device-neural-voice-kokoro)):

| Product | What it contains | Depends on |
|---------|-----------------|------------|
| **AgentClient** | Models, networking, SSE, configuration, storage | Foundation only |
| **AgentFrontend** | SwiftUI chat widget + view layer | AgentClient |
| **AgentKokoro** (optional) | On-device Kokoro neural voice (`KokoroTTSProvider`, G2P, model download/cache) | AgentClient, ONNX Runtime |

Existing consumers that `import AgentFrontend` continue to work unchanged — AgentFrontend re-exports AgentClient's types transitively.

To use only the headless core (e.g. to build a custom UI):

```swift
dependencies: [
    .package(url: "https://github.com/makemore/agent-ios.git", from: "3.1.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "AgentClient", package: "agent-ios"),
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

Sources/AgentKokoro/             # Optional on-device Kokoro voice
├── KokoroTTSProvider.swift      # TTSProvider: streaming, prefetch, fallback, metrics
├── KokoroTTS.swift              # register() / makeProvider()
├── KokoroVoice.swift            # Voice catalogue (Kokoro ids), languages
├── Assets/                      # Configuration, manifest, download/verify/cache, state
├── Engine/                      # ONNX Runtime sessions, chunking, AVAudioEngine playback
└── G2P/                         # Normaliser, tokenizer, lexicon, G2P (spec port)
```


## Changelog

### Unreleased

- **On-device neural voice (`AgentKokoro`, new optional product).** `KokoroTTSProvider` speaks with
  Kokoro-82M v1.0 on ONNX Runtime 1.24.2 with our own English G2P (spec port; passes every kokoro/v1
  golden vector), entirely on the device: pieces streamed gaplessly to `AVAudioEngine`, chunks
  prefetched while earlier ones play, model loaded at turn start, prompt cancel,
  `AudioSessionCoordinator` respected. `KokoroModelManager` downloads only what a voice needs
  (97.4 MB for `en-us`, 97.5 MB for `en-gb`) from a configurable base URL (default: our public
  kokoro/v1 bucket), pins the manifest's SHA-256, verifies every file, resumes interrupted downloads,
  caches by SHA-256 and can delete it; `prepare()`, `onModelProgress`, `voices()`. On any failure or
  while files are missing, the turn falls back to `AVSpeechTTSProvider` with a content-free reason.
  `onSpeechMetrics` reports load time, time to first audio and real-time factor. 28 English voices
  with Kokoro ids. `KokoroTTS.register()` makes Kokoro the voice whenever on-device speech is
  resolved. No GPL/AGPL/LGPL code or data; see [On-device neural voice](#on-device-neural-voice-kokoro).
- **macOS minimum is now 14** (package-wide; required by ONNX Runtime's Swift package). iOS stays 16.
- `VoiceFactory.onDeviceProviderFactory`: optional hook that replaces the system voice used for
  `.localOnly`, Protected AI Mode and proxy-less `.automatic`. `nil` (default) keeps `AVSpeechTTSProvider`.
- `TTSProvider` gains two optional members with no-op defaults (existing providers compile unchanged):
  `prepareForNewTurn()`, called by `VoiceController.reset()`, and `prefetch(_:options:)`, called for
  every chunk as `VoiceController` queues it.

### 3.1.0

- **Fixes building from a tag.** 3.0.1's `ChatWidgetConfig` referenced `TTSProviderPolicy` and
  `SpeechInputPolicy` without the file that defines them (`Voice/VoiceTypes.swift`), so apps
  resolving 3.0.1 from GitHub failed to compile. Use 3.1.0 or later.
- Voice: companion and Live voice (GPT-Live, spoken replies, hands-free with mic-level silence
  detection, on-device WhisperKit dictation, speak-aloud toggle, TTS at media volume).
- Calls: incoming app calls with PushKit and CallKit, a reusable system-call lifecycle and
  revocable Live voice signalling.
- Chat: Claude-style edit and retry with exact supersede hints, markdown pipe tables, readable
  column layout, chat UI presets, run recovery and history hardening.

### 3.0.1

**`onDisconnect` callback**

- **New `onDisconnect` on `ChatWidgetConfig`** — optional `((String, DisconnectReason) -> Void)?` fired exactly once per run when the SSE stream is torn down. The first argument is the `runId` of the stream that just closed; the second classifies the teardown so the host can distinguish a user-driven cancel (`.explicit`) from a network failure (`.network`) or a view/VM/OS lifecycle event (`.lifecycle`). The library does not perform any network call in response — this is purely a signal for the host to decide what to do (e.g. notify a backend that the user left). Default `nil` preserves the existing behaviour.
- **`DisconnectReason` enum** — new public type on `AgentClient` with cases `explicit`, `network`, `lifecycle`, `error`. Mirrors the Android enum and the web `DisconnectReason` union.
- **`SSEClient.disconnect(reason:)`** — signature extended from `disconnect()` to `disconnect(reason: DisconnectReason = .explicit)`. Callers (the view model) choose the reason; the SSE owner no longer has enough context to distinguish "user cancelled" from "view disappeared". A `hasFiredDisconnect` guard ensures the callback fires at most once per run.
- **`ChatViewModel`** — passes `runId` into `SSEClient.connect(url:headers:runId:)`, forwards `config.onDisconnect` to the SSE owner's callback, and tags each of the four `sseClient?.disconnect()` call sites with the right reason: `.explicit` from `cancelRun()` and the new-run-replaces-prior path, `.lifecycle` from terminal `run.suspended` / `client.action.required` and from a terminal `run.succeeded` / `run.failed` / `run.cancelled` / `run.timed_out`. A new `deinit` on `ChatViewModel` calls `sseClient?.disconnect(reason: .lifecycle)` so VM teardown also produces a clean lifecycle signal.
- **Additive** — no breaking changes. Default `onDisconnect = nil` makes the entire feature a no-op for existing consumers; every existing call site (`sseClient?.disconnect()`) continues to compile and behave identically.

### 3.0.0

**Unified client versioning + themable transcript**

- **Synchronized versioning** — iOS, Android, and web clients now share a single version line starting at `3.0.0`. This release carries the same feature set as the prior `0.10.0` (iOS) / `0.9.0` (Android) tags; the major bump signals production maturity and version alignment across platforms, not a breaking API change.
- **Message-bubble theming** — `ChatAppearance` gains `userBubble`, `assistantBubble`, `systemBubble`, and `link` tokens. `MessageView` now drives bubble backgrounds, text colours, corner radius, and markdown link tint from these tokens. Tokens are optional and fall back to the previous behaviour (host `primaryColor` / adaptive system greys), so existing integrations are unaffected.

### 0.10.0

**`showModelSelector` now gates the model selector**

- **Behaviour change** — `ChatWidgetConfig.showModelSelector` (default `false`) finally controls the composer model selector. The Anthropic composer's model pill — the only entry point to `ModelOptionsSheet` (model picker + extended-thinking / verbose multi-agent toggles) — is rendered **only** when `showModelSelector == true`. Previously the flag was unused and the pill appeared whenever a model label resolved. Hosts that relied on seeing the model selector must now set `showModelSelector = true` explicitly.
- Model-loading in `ChatViewModel` is unchanged; this is purely a visibility gate on the composer pill / sheet.

### 0.9.1

**Verbose multi-agent display hardening**

- Ensures the bundled SwiftUI views render with the same effective `subAgentActivityStyle` used by `ChatViewModel`, so the persisted **Verbose multi-agent** preference reliably switches between collapsed pill mode and legacy bubble mode.
- Adds streaming regression coverage for toggling verbose multi-agent on while using the warm-dark default appearance.

### 0.9.0

**Sub-agent activity display + Model Options sheet**

- **Sub-agent activity is a UI affordance, not a model concern** — when an orchestrator hands off to a specialist sub-agent, the bundled UI collapses the intermediate `assistant.delta` / `tool.call` / `assistant.message` events into a live activity pill (`SubAgentActivityPillView`) and, once the bracket closes, a single quiet "Consulted *Name* · 4s" row in the history. This is independent from any model-level reasoning / extended-thinking the underlying LLM does; the two never share terminology. Control surface: `ChatAppearance.subAgentActivityStyle` (`.pill` default on the warm-dark appearance, `.bubbles` on `.classic`).
- **Extended thinking is a separate per-run flag** — `ChatViewModel.sendMessage(_:files:model:thinking:supersedeFromMessageIndex:)` forwards the documented `thinking: bool` parameter (see `packages/python/django_agent_runtime/docs/mobile-protocol-contract.md`) to the runtime, which passes it through to the provider's reasoning mode. The new `ModelOptionsSheet` surfaces a toggle so end users can flip it without host code changes.
- **`ModelOptionsSheet`** — modal opened by tapping the model pill in the anthropic composer. Two toggles: **Extended thinking** (per-conversation, off by default) and **Verbose multi-agent** (per-app preference, off by default — when on, switches `subAgentActivityStyle` back to `.bubbles` so every specialist step gets its own bubble for debugging / inspection).
- **`MessageMetadata.subAgentDurationSeconds`** — renamed from `thinkingDurationSeconds` to remove the reasoning-model collision. Carries the elapsed wall-clock for a `sub_agent.start`→`sub_agent.end` bracket; populates the collapsed history row.

### 0.8.0

**Warm-dark "S'Ai" shell**

- **New configuration types** — `ChatAppearance` (palette, typography, composer style, brand-mark style), `ChatGreetingConfig` (time-of-day greeting + optional user name), and `ChatSidebarConfig` (slide-in drawer items, wordmark, footer). `ChatWidgetConfig` now exposes `appearance`, `greeting`, and `sidebar` properties; defaults flipped to the warm-dark baseline (`#0E0E0E` background, `#D97757` coral accent, `composerStyle = .anthropic`, greeting + sidebar enabled). Set `ChatAppearance.classic()` and `greeting.enabled = false` / `sidebar.enabled = false` to restore the pre-redesign look.
- **`GreetingView`** — new centered empty-state view: brand starburst + system-serif `"Good {morning|afternoon|evening}, {name}"`. `MessageListView.EmptyStateView` swaps to it when `config.greeting.enabled` so direct consumers see no change unless they opt in.
- **`ChatSidebarView`** — slide-in conversation drawer (~80% of screen width, floored at 280 pt for legibility). Header wordmark, nav rows, Recents loaded via `APIClient.loadConversations`, footer avatar + "New chat" pill wired to `ChatViewModel.clearMessages()` / `loadConversation(id:)`. Dim/blur backdrop, tap-outside to dismiss.
- **`AnthropicTopBar` + sidebar overlay in `ChatWidgetView`** — bundled widget now mounts a top bar with a circular hamburger button (opens the sidebar) and a "+" new-chat button. When `sidebar.enabled = false` the widget renders exactly as before.
- **`InputView` composer styles** — `ComposerStyle.anthropic` renders a two-row rounded card (text row + action row with `+` attach, model pill, mic, send circle); `ComposerStyle.classic` keeps the legacy single-row layout. Voice/STT logic is unchanged and shared between both styles.
- **`AddToChatSheet`** — modal presented by the composer `+` / paperclip button. Camera + Recents preview tiles, action rows (Add files, Add to project, Choose style…), tool toggles, and connectors list. Re-skins automatically for hosts using `.classic`. Tapping `Add files` chains into the existing file picker.
- **Example app** — `HostConfiguration` gains `anthropicShell`, `userName`, `enableTTS`, `enableVoice`; reads `USER_NAME` / `ANTHROPIC_SHELL` env vars. `ScenarioLauncherView` adds a "S'Ai shell (warm-dark baseline)" section with `S'Ai home (empty chat)` and `S'Ai home (streaming demo)` scenarios. Legacy scenarios explicitly opt out so they keep the classic look for A/B comparison.

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