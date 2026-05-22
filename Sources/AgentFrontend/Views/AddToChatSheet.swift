import SwiftUI
import AgentClient

/// Bottom sheet presented by the composer's `+` button. Mirrors the
/// reference "Add to Chat" panel: camera / recents tiles at the top,
/// a list of attachment + configuration rows, two feature toggles,
/// and a connectors row. Everything except "Add files" is a stub
/// today — state stays local so host apps get a usable preview
/// without any wiring. Hosts can replace this view wholesale by
/// reading `ChatWidgetConfig` and presenting their own sheet from
/// the same `+` action.
struct AddToChatSheet: View {
    let config: ChatWidgetConfig
    /// Invoked when the user picks the "Add files" row. The composer
    /// chains a file-picker sheet after the dismissal so the two
    /// presentations don't collide.
    let onAddFiles: () -> Void

    @Environment(\.dismiss) private var dismiss

    // Stub state — visual only until hosts wire real handlers.
    @State private var addToProject: String = "None"
    @State private var chosenStyle: String = "Normal"
    @State private var toolAccess: String = "Auto"
    @State private var researchEnabled: Bool = false
    @State private var webSearchEnabled: Bool = true

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
                ToolbarItem(placement: .primaryAction) {
                    Button("All photos") { /* stub */ }
                        .foregroundColor(config.appearance.textPrimary)
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
    }

    // MARK: - Top tiles (camera + recents preview)

    private var topTiles: some View {
        HStack(spacing: 12) {
            tileButton(systemImage: "camera", label: "Camera") { /* stub */ }
            recentsTile
        }
        .frame(height: 130)
    }

    private func tileButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundColor(config.appearance.textPrimary)
                Spacer()
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(config.appearance.textPrimary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(config.appearance.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    /// Decorative preview of the user's recent items — purely visual
    /// stub so the tile looks populated.
    private var recentsTile: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(["Artifacts", "Code", "Dispatch", "Recents",
                     "Building a sports car on a bu…",
                     "Data lakes vs databases exp…",
                     "Mervin the Paranoid Androi…"], id: \.self) { line in
                Text(line)
                    .font(.system(size: 9))
                    .foregroundColor(config.appearance.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(config.appearance.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Rows / toggles / connectors cards

    private var rowsCard: some View {
        VStack(spacing: 0) {
            actionRow(systemImage: "doc.badge.plus", label: "Add files") {
                onAddFiles()
            }
            rowDivider
            valueRow(systemImage: "tray.full", label: "Add to project", value: addToProject) {
                // Toggle between the two stub values so the tap is visible.
                addToProject = addToProject == "None" ? "Personal" : "None"
            }
            rowDivider
            valueRow(systemImage: "pencil.tip", label: "Choose style", value: chosenStyle) {
                chosenStyle = chosenStyle == "Normal" ? "Concise" : "Normal"
            }
            rowDivider
            valueRow(systemImage: "briefcase", label: "Tool access", value: toolAccess) {
                toolAccess = toolAccess == "Auto" ? "Manual" : "Auto"
            }
        }
        .background(config.appearance.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var togglesCard: some View {
        VStack(spacing: 0) {
            toggleRow(systemImage: "scope", label: "Research", isOn: $researchEnabled)
            rowDivider
            toggleRow(systemImage: "globe", label: "Web search", isOn: $webSearchEnabled)
        }
        .background(config.appearance.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var connectorsCard: some View {
        Button { /* stub */ } label: {
            HStack(spacing: 14) {
                rowIcon("square.grid.2x2")
                Text("Connectors")
                    .font(.body)
                    .foregroundColor(config.appearance.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(config.appearance.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(config.appearance.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Row primitives

    private var rowDivider: some View {
        Divider().background(config.appearance.divider).padding(.leading, 50)
    }

    private func rowIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.body)
            .foregroundColor(config.appearance.textSecondary)
            .frame(width: 24, alignment: .center)
    }

    private func actionRow(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                rowIcon(systemImage)
                Text(label)
                    .font(.body)
                    .foregroundColor(config.appearance.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
    }

    private func valueRow(systemImage: String, label: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                rowIcon(systemImage)
                Text(label)
                    .font(.body)
                    .foregroundColor(config.appearance.textPrimary)
                Spacer()
                Text(value)
                    .font(.body)
                    .foregroundColor(config.appearance.textSecondary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(config.appearance.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
    }

    private func toggleRow(systemImage: String, label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            rowIcon(systemImage)
            Text(label)
                .font(.body)
                .foregroundColor(config.appearance.textPrimary)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(config.appearance.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
