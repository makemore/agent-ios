import SwiftUI
import AgentClient

/// Sections + row primitives for `AddToChatSheet`. Split out so the
/// main file stays readable; nothing here is reused elsewhere.
extension AddToChatSheet {

    // MARK: - Top tiles (camera + recents preview)

    var topTiles: some View {
        HStack(spacing: 12) {
            cameraTile
            recentsTile
        }
        .frame(height: 130)
    }

    private var cameraTile: some View {
        Button {
            #if canImport(UIKit)
            showCamera = true
            #endif
        } label: {
            VStack(alignment: .leading) {
                Image(systemName: "camera")
                    .font(.title3)
                    .foregroundColor(config.appearance.textPrimary)
                Spacer()
                Text("Camera")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(config.appearance.textPrimary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(config.appearance.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    /// Preview of the user's three most-recent local conversations.
    /// Falls back to placeholder lines when nothing is recorded yet so
    /// the tile keeps its visual weight.
    private var recentsTile: some View {
        let recents = Array((viewModel?.localConversations ?? []).prefix(3))
        return VStack(alignment: .leading, spacing: 6) {
            Text("Recents")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(config.appearance.textPrimary)
                .padding(.bottom, 2)
            if recents.isEmpty {
                ForEach(["No history yet", "Start chatting to", "see recent items"], id: \.self) { line in
                    Text(line)
                        .font(.system(size: 10))
                        .foregroundColor(config.appearance.textSecondary)
                        .lineLimit(1)
                }
            } else {
                ForEach(recents) { item in
                    Button {
                        guard let vm = viewModel else { return }
                        dismiss()
                        Task { await vm.loadConversation(item.id) }
                    } label: {
                        Text(item.title.isEmpty ? "Untitled" : item.title)
                            .font(.system(size: 10))
                            .foregroundColor(config.appearance.textSecondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(config.appearance.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Rows / toggles / connectors cards

    var rowsCard: some View {
        VStack(spacing: 0) {
            actionRow(systemImage: "doc.badge.plus", label: "Add files") {
                onAddFiles()
            }
            rowDivider
            soonRow(systemImage: "tray.full", label: "Add to project")
            rowDivider
            styleMenuRow
            rowDivider
            toolAccessMenuRow
        }
        .background(config.appearance.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    var togglesCard: some View {
        VStack(spacing: 0) {
            toggleRow(systemImage: "scope", label: "Research", isOn: researchBinding)
            rowDivider
            toggleRow(systemImage: "globe", label: "Web search", isOn: webSearchBinding)
        }
        .background(config.appearance.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    var connectorsCard: some View {
        HStack(spacing: 14) {
            rowIcon("square.grid.2x2")
            Text("Connectors")
                .font(.body)
                .foregroundColor(config.appearance.textPrimary.opacity(0.55))
            Spacer()
            soonBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(config.appearance.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Menu rows wired to the view model

    private var styleMenuRow: some View {
        Menu {
            ForEach(ChatViewModel.ResponseStyle.allCases, id: \.self) { option in
                Button {
                    styleBinding.wrappedValue = option
                } label: {
                    if option == styleBinding.wrappedValue {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            valueRowLabel(systemImage: "pencil.tip",
                          label: "Choose style",
                          value: styleBinding.wrappedValue.displayName)
        }
    }
}
