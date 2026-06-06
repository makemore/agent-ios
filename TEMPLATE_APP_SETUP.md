# Template App Setup Guide

> **Purpose**: This document describes how to scaffold a complete ChatGPT-style iOS app using the `AgentFrontend` library. It is designed to be read by an LLM (or developer) and followed step-by-step to generate a fully working project. Every file, folder, scheme, and configuration is described explicitly.

---

## Table of Contents

1. [Project Structure](#1-project-structure)
2. [Xcode Project Setup](#2-xcode-project-setup)
3. [Xcode Schemes — Production & Development](#3-xcode-schemes--production--development)
4. [Environment Configuration](#4-environment-configuration)
5. [Authentication Service](#5-authentication-service)
6. [API Service Layer](#6-api-service-layer)
7. [App Entry Point](#7-app-entry-point)
8. [Main App Shell — ChatGPT-Style Layout](#8-main-app-shell--chatgpt-style-layout)
9. [Sidebar — Conversation List](#9-sidebar--conversation-list)
10. [Chat View — Main Content Area](#10-chat-view--main-content-area)
11. [Settings View](#11-settings-view)
12. [Login View](#12-login-view)
13. [Keychain Helper](#13-keychain-helper)
14. [Putting It All Together](#14-putting-it-all-together)

---

## 1. Project Structure

Create the following folder structure inside your Xcode project:

```
MyApp/
├── MyApp.xcodeproj
├── MyApp/
│   ├── App/
│   │   └── MyAppApp.swift              # @main entry point
│   ├── Configuration/
│   │   ├── AppEnvironment.swift         # Environment enum + API URLs
│   │   └── Info.plist                   # (Xcode-managed)
│   ├── Services/
│   │   ├── AuthService.swift            # Login, logout, token management
│   │   ├── APIService.swift             # Generic HTTP client wrapper
│   │   └── KeychainHelper.swift         # Secure token storage
│   ├── ViewModels/
│   │   └── AppViewModel.swift           # Root app state (auth, sidebar, navigation)
│   ├── Views/
│   │   ├── ContentView.swift            # Root view — auth gate
│   │   ├── MainShellView.swift          # ChatGPT-style shell (sidebar + chat)
│   │   ├── AppSidebarView.swift         # Sliding sidebar with conversation list
│   │   ├── ChatContainerView.swift      # Wraps AgentFrontend chat widget
│   │   ├── SettingsView.swift           # User settings / logout
│   │   └── LoginView.swift              # Email + password login form
│   ├── Assets.xcassets/
│   └── Preview Content/
└── MyAppTests/
```

---

## 2. Xcode Project Setup

1. **Create a new Xcode project**: iOS → App → SwiftUI → Swift. Name it `MyApp` (or your preferred name).
2. **Minimum deployment target**: iOS 16.0.
3. **Add AgentFrontend package** (Swift Package Manager, pinned to a version tag):
   - File → Add Package Dependencies… → paste `https://github.com/makemore/agent-ios.git` → choose **Up to Next Major Version** from `0.9.1` (use the latest [tag](https://github.com/makemore/agent-ios/tags)).
   - Or in `Package.swift`: `.package(url: "https://github.com/makemore/agent-ios.git", from: "0.9.1")`
   - Add the `AgentFrontend` product as a dependency of your app target.
   - **Public repo:** no token or credentials needed — SwiftPM (and CI) can clone `makemore/agent-ios` directly.
   - *(Library development only)* alternatively add the local folder via **Add Local…** or `.package(path: "../agent_libraries/clients/agent-ios")`.

---

## 3. Xcode Schemes — Production & Development

You need **two schemes** so the app can point to different API servers.

### Step-by-step:

1. **Create two Build Configurations**:
   - Open project settings → Info tab → Configurations section.
   - You already have `Debug` and `Release`.
   - Duplicate `Debug` → rename to `Debug (Production)`.
   - Duplicate `Release` → rename to `Release (Production)`.
   - The original `Debug` and `Release` will be your **Development** configurations.

2. **Add a User-Defined Build Setting**:
   - Project settings → Build Settings tab → click `+` → Add User-Defined Setting.
   - Name: `API_BASE_URL`
   - Set values:
     - `Debug`: `http://localhost:8000`
     - `Release`: `https://staging-api.yourapp.com`
     - `Debug (Production)`: `https://api.yourapp.com`
     - `Release (Production)`: `https://api.yourapp.com`

3. **Expose to code via Info.plist**:
   - Add a row to Info.plist: Key = `API_BASE_URL`, Value = `$(API_BASE_URL)`.

4. **Create the Development scheme** (likely already exists as `MyApp`):
   - Edit Scheme → Run → Build Configuration = `Debug`.
   - Archive → Build Configuration = `Release`.

5. **Create the Production scheme**:
   - Scheme menu → Manage Schemes → Duplicate `MyApp` → rename to `MyApp (Production)`.
   - Edit Scheme → Run → Build Configuration = `Debug (Production)`.
   - Archive → Build Configuration = `Release (Production)`.

Now switching schemes switches the API URL automatically.

---

## 4. Environment Configuration

### `MyApp/Configuration/AppEnvironment.swift`

```swift
import Foundation

enum AppEnvironment {
    /// The base URL for all API requests, read from Info.plist (set per-scheme).
    static var apiBaseURL: String {
        guard let url = Bundle.main.infoDictionary?["API_BASE_URL"] as? String,
              !url.isEmpty else {
            // Fallback for previews / tests
            return "http://localhost:8000"
        }
        return url
    }

    /// Whether we're running in a debug build.
    static var isDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// The agent key for the AgentFrontend widget.
    /// Change this to your agent's key from django_studio.
    static let agentKey = "default-agent"
}
```

---

## 5. Authentication Service

This service handles login via django_studio's token auth endpoint and stores the token securely in the Keychain.

### `MyApp/Services/AuthService.swift`

```swift
import Foundation
import Combine

@MainActor
final class AuthService: ObservableObject {
    @Published var token: String?
    @Published var isAuthenticated: Bool = false
    @Published var isLoading: Bool = false
    @Published var error: String?

    private let apiService: APIService

    init(apiService: APIService = APIService()) {
        self.apiService = apiService
        // Restore token from Keychain on launch
        self.token = KeychainHelper.load(key: "auth_token")
        self.isAuthenticated = self.token != nil
    }

    /// Log in with email and password.
    /// Calls django_studio's token auth endpoint: POST /api/accounts/token/
    /// Expected response: { "token": "abc123..." }
    func login(email: String, password: String) async {
        isLoading = true
        error = nil

        do {
            let body: [String: String] = ["email": email, "password": password]
            let response: TokenResponse = try await apiService.post(
                path: "/api/accounts/token/",
                body: body
            )
            self.token = response.token
            self.isAuthenticated = true
            KeychainHelper.save(key: "auth_token", value: response.token)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    /// Log out — clear token from memory and Keychain.
    func logout() {
        token = nil
        isAuthenticated = false
        KeychainHelper.delete(key: "auth_token")
    }
}

/// Response model for token auth
private struct TokenResponse: Decodable {
    let token: String
}
```

> **Note on auth endpoint**: django_studio typically exposes `/api/accounts/token/` for DRF Token auth or `/api/accounts/jwt/` for JWT. Adjust the path above to match your backend. If using JWT, you'll get `access` and `refresh` tokens — see the JWT variant below.

<details>
<summary><strong>JWT Variant (click to expand)</strong></summary>

If your backend uses JWT instead of DRF Token auth:

```swift
    /// JWT login — POST /api/accounts/jwt/
    /// Expected response: { "access": "...", "refresh": "..." }
    func loginJWT(email: String, password: String) async {
        isLoading = true
        error = nil

        do {
            let body: [String: String] = ["email": email, "password": password]
            let response: JWTResponse = try await apiService.post(
                path: "/api/accounts/jwt/",
                body: body
            )
            self.token = response.access
            self.isAuthenticated = true
            KeychainHelper.save(key: "auth_token", value: response.access)
            KeychainHelper.save(key: "refresh_token", value: response.refresh)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    /// Refresh an expired JWT access token
    func refreshJWT() async -> Bool {
        guard let refreshToken = KeychainHelper.load(key: "refresh_token") else {
            logout()
            return false
        }

        do {
            let body: [String: String] = ["refresh": refreshToken]
            let response: JWTRefreshResponse = try await apiService.post(
                path: "/api/accounts/jwt/refresh/",
                body: body
            )
            self.token = response.access
            KeychainHelper.save(key: "auth_token", value: response.access)
            return true
        } catch {
            logout()
            return false
        }
    }
}

private struct JWTResponse: Decodable {
    let access: String
    let refresh: String
}

private struct JWTRefreshResponse: Decodable {
    let access: String
}
```

</details>

---

## 6. API Service Layer

A lightweight, reusable HTTP client. All app-specific API calls go through this.

### `MyApp/Services/APIService.swift`

```swift
import Foundation

final class APIService {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(session: URLSession = .shared) {
        self.session = session

        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder.dateDecodingStrategy = .iso8601

        self.encoder = JSONEncoder()
        self.encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    /// GET request
    func get<T: Decodable>(path: String, token: String? = nil) async throws -> T {
        let request = try buildRequest(method: "GET", path: path, token: token)
        return try await execute(request)
    }

    /// POST request with Encodable body
    func post<T: Decodable, B: Encodable>(path: String, body: B, token: String? = nil) async throws -> T {
        var request = try buildRequest(method: "POST", path: path, token: token)
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await execute(request)
    }

    /// POST with no response body expected
    func post<B: Encodable>(path: String, body: B, token: String? = nil) async throws {
        var request = try buildRequest(method: "POST", path: path, token: token)
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    // MARK: - Private

    private func buildRequest(method: String, path: String, token: String?) throws -> URLRequest {
        let baseURL = AppEnvironment.apiBaseURL
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token = token {
            // Use "Token" prefix for DRF Token auth, "Bearer" for JWT
            request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try decoder.decode(T.self, from: data)
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        case 404:
            throw APIError.notFound
        default:
            throw APIError.httpError(statusCode: http.statusCode)
        }
    }
}

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case forbidden
    case notFound
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response"
        case .unauthorized: return "Unauthorized — please log in again"
        case .forbidden: return "Access denied"
        case .notFound: return "Not found"
        case .httpError(let code): return "HTTP error \(code)"
        }
    }
}
```

---

## 7. App Entry Point

### `MyApp/App/MyAppApp.swift`

```swift
import SwiftUI

@main
struct MyAppApp: App {
    @StateObject private var authService = AuthService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authService)
        }
    }
}
```

---

## 8. Main App Shell — ChatGPT-Style Layout

This is the core of the ChatGPT-style interface. The layout is:

```
┌─────────────────────────────────────────┐
│ ☰  My Assistant              ⚙️         │  ← Top bar
├─────────────────────────────────────────┤
│                                         │
│         Message bubbles area            │  ← Scrollable messages
│         (from AgentFrontend)            │
│                                         │
├─────────────────────────────────────────┤
│ [Type your message...]          [Send]  │  ← Input bar
└─────────────────────────────────────────┘
```

When the hamburger (☰) is tapped, a sidebar slides in from the left:

```
┌──────────────┬──────────────────────────┐
│  ✕           │                          │
│              │                          │
│ + New Chat   │    (dimmed main area)    │
│              │                          │
│ Today        │                          │
│  Chat about… │                          │
│  Help with…  │                          │
│              │                          │
│ Yesterday    │                          │
│  Debug the…  │                          │
│              │                          │
│              │                          │
│ ──────────── │                          │
│ ⚙️ Settings  │                          │
│ 🚪 Log out   │                          │
└──────────────┴──────────────────────────┘
```

### `MyApp/ViewModels/AppViewModel.swift`

```swift
import SwiftUI
import AgentFrontend

@MainActor
final class AppViewModel: ObservableObject {
    @Published var showSidebar: Bool = false
    @Published var selectedConversationId: String?
    @Published var showSettings: Bool = false

    /// The AgentFrontend ChatViewModel — created once, reused.
    @Published var chatViewModel: ChatViewModel?

    private var currentConfig: ChatWidgetConfig?

    /// Build the AgentFrontend config using the current auth token.
    func configure(token: String?) {
        var config = ChatWidgetConfig(
            backendUrl: AppEnvironment.apiBaseURL,
            agentKey: AppEnvironment.agentKey
        )
        config.title = "My Assistant"
        config.subtitle = ""
        config.showConversationSidebar = false   // We provide our own sidebar
        config.showClearButton = false           // We handle this ourselves
        config.showTasksTab = false              // Optional: set true if you want tasks
        config.enableFiles = true
        config.apiCaseStyle = .auto

        // Auth — use .token for DRF Token, .jwt for JWT Bearer
        if let token = token {
            config.authStrategy = .token         // Change to .jwt if using JWT
            config.authToken = token
        }

        self.currentConfig = config
        self.chatViewModel = AgentFrontend.createViewModel(config: config)
    }

    /// Start a new conversation
    func newConversation() {
        chatViewModel?.clearMessages()
        selectedConversationId = nil
        showSidebar = false
    }

    /// Load an existing conversation
    func selectConversation(_ id: String) {
        selectedConversationId = id
        Task {
            await chatViewModel?.loadConversation(id)
        }
        showSidebar = false
    }
}
```


### `MyApp/Views/ContentView.swift`

This is the auth gate — shows login or the main shell.

```swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var authService: AuthService

    var body: some View {
        Group {
            if authService.isAuthenticated {
                MainShellView()
                    .environmentObject(authService)
            } else {
                LoginView()
                    .environmentObject(authService)
            }
        }
        .animation(.easeInOut, value: authService.isAuthenticated)
    }
}
```

---

## 9. Sidebar — Conversation List

### `MyApp/Views/AppSidebarView.swift`

```swift
import SwiftUI
import AgentFrontend

struct AppSidebarView: View {
    @EnvironmentObject var authService: AuthService
    @ObservedObject var appViewModel: AppViewModel
    let onDismiss: () -> Void

    @State private var conversations: [Conversation] = []
    @State private var isLoading = false

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // Sidebar panel
                VStack(alignment: .leading, spacing: 0) {
                    // Close button
                    HStack {
                        Text("Conversations")
                            .font(.headline)
                        Spacer()
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()

                    Divider()

                    // New Chat button
                    Button(action: {
                        appViewModel.newConversation()
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("New Chat")
                                .fontWeight(.medium)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider()

                    // Conversation list
                    if isLoading {
                        Spacer()
                        ProgressView()
                            .frame(maxWidth: .infinity)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(conversations) { conversation in
                                    Button(action: {
                                        appViewModel.selectConversation(conversation.id)
                                    }) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(conversation.title ?? "Untitled")
                                                .font(.subheadline)
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                            if let date = conversation.updatedAt ?? conversation.createdAt {
                                                Text(date, style: .relative)
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .padding(.horizontal)
                                        .padding(.vertical, 10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            appViewModel.selectedConversationId == conversation.id
                                                ? Color.accentColor.opacity(0.1)
                                                : Color.clear
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    Divider()
                                }
                            }
                        }
                    }

                    Spacer()

                    Divider()

                    // Bottom section — Settings & Logout
                    VStack(spacing: 0) {
                        Button(action: { appViewModel.showSettings = true }) {
                            HStack {
                                Image(systemName: "gearshape")
                                Text("Settings")
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button(action: { authService.logout() }) {
                            HStack {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                Text("Log out")
                                    .foregroundColor(.red)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: min(300, geometry.size.width * 0.8))
                .background(Color(.systemBackground))

                // Dimmed overlay — tap to dismiss
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss() }
            }
        }
        .ignoresSafeArea()
        .task { await loadConversations() }
    }

    private func loadConversations() async {
        guard let token = authService.token else { return }
        isLoading = true
        // Use AgentFrontend's APIClient to fetch conversations
        var config = ChatWidgetConfig(
            backendUrl: AppEnvironment.apiBaseURL,
            agentKey: AppEnvironment.agentKey
        )
        config.authStrategy = .token
        config.authToken = token
        let storage = InMemoryStorage()
        let apiClient = APIClient(config: config, storage: storage)
        do {
            conversations = try await apiClient.loadConversations()
        } catch {
            print("Failed to load conversations: \(error)")
        }
        isLoading = false
    }
}
```

---

## 10. Chat View — Main Content Area

### `MyApp/Views/MainShellView.swift`

This is the top-level authenticated view. It composes the top bar, chat area, and sidebar overlay.

```swift
import SwiftUI
import AgentFrontend

struct MainShellView: View {
    @EnvironmentObject var authService: AuthService
    @StateObject private var appViewModel = AppViewModel()

    var body: some View {
        ZStack {
            // Main content
            VStack(spacing: 0) {
                // Top bar
                topBar

                // Chat area
                if let chatVM = appViewModel.chatViewModel {
                    ChatContainerView(viewModel: chatVM)
                } else {
                    Spacer()
                    ProgressView("Loading...")
                    Spacer()
                }
            }

            // Sidebar overlay
            if appViewModel.showSidebar {
                AppSidebarView(
                    appViewModel: appViewModel,
                    onDismiss: { appViewModel.showSidebar = false }
                )
                .transition(.move(edge: .leading))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appViewModel.showSidebar)
        .sheet(isPresented: $appViewModel.showSettings) {
            SettingsView()
                .environmentObject(authService)
        }
        .onAppear {
            appViewModel.configure(token: authService.token)
        }
        .onChange(of: authService.token) { newToken in
            appViewModel.configure(token: newToken)
        }
    }

    private var topBar: some View {
        HStack {
            // Hamburger menu
            Button(action: { appViewModel.showSidebar.toggle() }) {
                Image(systemName: "line.3.horizontal")
                    .font(.title2)
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("My Assistant")
                    .font(.headline)
                    .foregroundColor(.white)
            }

            Spacer()

            // New chat shortcut
            Button(action: { appViewModel.newConversation() }) {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(hex: "#0066cc"))
    }
}
```

### `MyApp/Views/ChatContainerView.swift`

This wraps the AgentFrontend `ChatWidgetView` into the main chat area. `ChatWidgetView` provides the chat flow (messages, error banner, input) — the header and sidebar are app-level concerns handled by `MainShellView` and `AppSidebarView` above.

```swift
import SwiftUI
import AgentFrontend

struct ChatContainerView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            MessageListView(
                messages: viewModel.messages,
                isLoading: viewModel.isLoading,
                hasMoreMessages: viewModel.hasMoreMessages,
                loadingMoreMessages: viewModel.loadingMoreMessages,
                config: ChatWidgetConfig(
                    backendUrl: AppEnvironment.apiBaseURL,
                    agentKey: AppEnvironment.agentKey
                ),
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

            // Error banner
            if let error = viewModel.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                    Spacer()
                    Button(action: { viewModel.error = nil }) {
                        Image(systemName: "xmark")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.1))
            }

            // Input bar
            InputView(
                config: ChatWidgetConfig(
                    backendUrl: AppEnvironment.apiBaseURL,
                    agentKey: AppEnvironment.agentKey
                ),
                isLoading: viewModel.isLoading,
                onSend: { content, files in
                    Task { await viewModel.sendMessage(content, files: files) }
                },
                onCancel: {
                    Task { await viewModel.cancelRun() }
                }
            )
        }
    }
}
```

> **Tip**: If you prefer the simpler approach, you can use `AgentFrontend.createChatWidget(config:)` directly instead of composing `MessageListView` + `InputView`. The trade-off is less control over the layout but faster setup. See the [Simple Alternative](#simple-alternative) section at the end.

---

## 11. Settings View

### `MyApp/Views/SettingsView.swift`

```swift
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("Account") {
                    if authService.isAuthenticated {
                        HStack {
                            Image(systemName: "person.circle.fill")
                                .font(.title2)
                                .foregroundColor(.accentColor)
                            Text("Logged in")
                        }
                    }
                }

                Section("App") {
                    HStack {
                        Text("Environment")
                        Spacer()
                        Text(AppEnvironment.isDebug ? "Development" : "Production")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("API URL")
                        Spacer()
                        Text(AppEnvironment.apiBaseURL)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Section {
                    Button("Log out", role: .destructive) {
                        authService.logout()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
```

---

## 12. Login View

### `MyApp/Views/LoginView.swift`

```swift
import SwiftUI

struct LoginView: View {
    @EnvironmentObject var authService: AuthService

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Logo / Title
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.accentColor)
                Text("My Assistant")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Text("Sign in to continue")
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Form
            VStack(spacing: 16) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)

                if let error = authService.error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Button(action: {
                    Task { await authService.login(email: email, password: password) }
                }) {
                    if authService.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else {
                        Text("Sign In")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                }
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(10)
                .disabled(email.isEmpty || password.isEmpty || authService.isLoading)
            }
            .padding(.horizontal, 32)

            Spacer()
        }
    }
}
```

---

## 13. Keychain Helper

### `MyApp/Services/KeychainHelper.swift`

Stores auth tokens securely in the iOS Keychain instead of UserDefaults.

```swift
import Foundation
import Security

enum KeychainHelper {
    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }

        // Delete any existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

---

## 14. Putting It All Together

### Checklist

After creating all the files above, verify:

- [ ] **Xcode project** has `AgentFrontend` package added as a dependency
- [ ] **Two schemes** exist: `MyApp` (Development) and `MyApp (Production)`
- [ ] **`API_BASE_URL`** user-defined build setting is configured for all 4 build configurations
- [ ] **Info.plist** has `API_BASE_URL` = `$(API_BASE_URL)` entry
- [ ] **All files** are added to the correct target
- [ ] **Build succeeds** on both schemes

### Customisation Points

| What | Where | How |
|------|-------|-----|
| App name / title | `MainShellView.swift` topBar | Change the `Text("My Assistant")` string |
| Primary colour | `MainShellView.swift` topBar | Change `Color(hex: "#0066cc")` |
| Agent key | `AppEnvironment.swift` | Change `agentKey` constant |
| Auth endpoint | `AuthService.swift` | Change `/api/accounts/token/` path |
| Auth strategy | `AppViewModel.swift` | Change `.token` to `.jwt` |
| Auth header prefix | `APIService.swift` | Change `"Token"` to `"Bearer"` for JWT |
| API base URLs | Xcode Build Settings | Edit `API_BASE_URL` per configuration |
| Sidebar width | `AppSidebarView.swift` | Change `min(300, geometry.size.width * 0.8)` |
| Feature flags | `AppViewModel.swift` `configure()` | Toggle `enableFiles`, `showTasksTab`, etc. |

### Simple Alternative

If you don't need a custom sidebar and top bar, you can skip `MainShellView`, `AppSidebarView`, and `ChatContainerView` entirely and use the chat widget directly:

```swift
struct MainShellView: View {
    @EnvironmentObject var authService: AuthService

    var body: some View {
        let config = ChatWidgetConfig.make(
            backendUrl: AppEnvironment.apiBaseURL,
            agentKey: AppEnvironment.agentKey,
            title: "My Assistant"
        ).withAuth(strategy: .token, token: authService.token)

        AgentFrontend.createChatWidget(config: config)
    }
}
```

This gives you the chat flow (messages, input, error handling) with no app shell around it. Add your own `NavigationView`, header, and sidebar as needed.

---

### AgentFrontend API Quick Reference

For the LLM or developer implementing this, here are the key types from the `AgentFrontend` library:

| Type | Purpose |
|------|---------|
| `AgentFrontend.createChatWidget(config:)` | Factory — returns a complete chat `View` |
| `AgentFrontend.createViewModel(config:)` | Factory — returns a `ChatViewModel` for custom UI |
| `ChatWidgetConfig` | All configuration (URLs, auth, UI flags, API paths) |
| `ChatWidgetConfig.make(backendUrl:agentKey:title:primaryColor:)` | Convenience config builder |
| `AuthStrategy` | Enum: `.token`, `.jwt`, `.session`, `.anonymous`, `.none` |
| `APICaseStyle` | Enum: `.camel`, `.snake`, `.auto` |
| `ChatViewModel` | `@MainActor ObservableObject` — messages, send, cancel, load, edit, retry |
| `ChatWidgetView` | Chat flow view (messages + error banner + input) |
| `MessageListView` | Just the scrollable message list |
| `InputView` | Just the text input + file picker + send/cancel buttons |
| `APIClient` | HTTP + SSE client for django_studio |
| `StorageService` | Protocol for key-value storage |
| `UserDefaultsStorage` | Default `StorageService` implementation |
| `InMemoryStorage` | In-memory `StorageService` (for previews/tests) |
| `Conversation` | Model — id, title, messages, hasMore, createdAt, updatedAt |
| `Message` | Model — id, role, content, timestamp, type, metadata, files |

### ChatViewModel Published Properties

```swift
@Published var messages: [Message]
@Published var isLoading: Bool
@Published var error: String?
@Published var conversationId: String?
@Published var hasMoreMessages: Bool
@Published var loadingMoreMessages: Bool
```

### ChatViewModel Methods

```swift
func sendMessage(_ content: String, files: [FileAttachment]) async
func cancelRun() async
func clearMessages()
func loadConversation(_ convId: String) async
func loadMoreMessages() async
func editMessage(at index: Int, newContent: String, model: String?, thinking: Bool) async
func retryMessage(at index: Int, model: String?, thinking: Bool) async
```

---

> **End of setup guide.** Follow sections 1–13 in order to scaffold the complete app. Customise using the table in section 14.