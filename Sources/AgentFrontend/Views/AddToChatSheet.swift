import SwiftUI
import AgentClient
#if canImport(UIKit)
import UIKit
#endif

/// Bottom sheet presented by the composer's `+` button. Mirrors the
/// reference "Add to Chat" panel: camera / recents tiles at the top,
/// a list of attachment + configuration rows, two feature toggles,
/// and a connectors row.
///
/// When a `ChatViewModel` is provided, the behaviour rows (Style,
/// Tool access, Research, Web search) bind directly to its persisted
/// preferences and the recents tile lists local conversation history.
/// When `nil` (preview / headless usage) the sheet falls back to
/// local stub state so it still renders standalone.
struct AddToChatSheet: View {
    let config: ChatWidgetConfig
    let viewModel: ChatViewModel?
    /// Invoked when the user picks the "Add files" row. The composer
    /// chains a file-picker sheet after the dismissal so the two
    /// presentations don't collide.
    let onAddFiles: () -> Void
    /// Invoked when the camera tile capture completes. Hosts append
    /// the returned image as a `FileAttachment` on the composer.
    let onCaptureImage: (PlatformImage) -> Void

    @Environment(\.dismiss) var dismiss
    @State var showCamera: Bool = false
    // Fallback state used only when no ChatViewModel is wired.
    @State var fallbackStyle: ChatViewModel.ResponseStyle = .normal
    @State var fallbackToolAccess: ChatViewModel.ToolAccess = .auto
    @State var fallbackResearch: Bool = false
    @State var fallbackWebSearch: Bool = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    topTiles
                    rowsCard
                    togglesCard
                    connectorsCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(config.appearance.background.ignoresSafeArea())
            .navigationTitle("Add to Chat")
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
            #if os(iOS)
            .toolbarBackground(config.appearance.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #if canImport(UIKit)
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                if let image = image { onCaptureImage(image) }
                showCamera = false
                dismiss()
            }
        }
        #endif
    }

    // MARK: - Bindings (real or fallback)

    var styleBinding: Binding<ChatViewModel.ResponseStyle> {
        if let vm = viewModel {
            return Binding(get: { vm.responseStyle }, set: { vm.responseStyle = $0 })
        }
        return $fallbackStyle
    }

    var toolAccessBinding: Binding<ChatViewModel.ToolAccess> {
        if let vm = viewModel {
            return Binding(get: { vm.toolAccess }, set: { vm.toolAccess = $0 })
        }
        return $fallbackToolAccess
    }

    var researchBinding: Binding<Bool> {
        if let vm = viewModel {
            return Binding(get: { vm.researchEnabled }, set: { vm.researchEnabled = $0 })
        }
        return $fallbackResearch
    }

    var webSearchBinding: Binding<Bool> {
        if let vm = viewModel {
            return Binding(get: { vm.webSearchEnabled }, set: { vm.webSearchEnabled = $0 })
        }
        return $fallbackWebSearch
    }
}

#if canImport(UIKit)
/// Platform alias so the `onCaptureImage` callback is a real type on
/// both iOS and (future) macOS catalyst builds. We avoid importing
/// AppKit so the sheet can stay in the shared frontend module.
typealias PlatformImage = UIImage
#else
typealias PlatformImage = Data
#endif
