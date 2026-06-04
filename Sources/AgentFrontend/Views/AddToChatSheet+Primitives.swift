import SwiftUI
import AgentClient

/// Row primitives used by `AddToChatSheet`. Pulled out so the main
/// sheet file isn't dominated by layout helpers.
extension AddToChatSheet {

    var rowDivider: some View {
        Divider().background(config.appearance.divider).padding(.leading, 50)
    }

    func rowIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.body)
            .foregroundColor(config.appearance.textSecondary)
            .frame(width: 24, alignment: .center)
    }

    func actionRow(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
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

    func valueRowLabel(systemImage: String, label: String, value: String) -> some View {
        HStack(spacing: 14) {
            rowIcon(systemImage)
            Text(label)
                .font(.body)
                .foregroundColor(config.appearance.textPrimary)
            Spacer()
            Text(value)
                .font(.body)
                .foregroundColor(config.appearance.textSecondary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundColor(config.appearance.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    /// Disabled-looking row with a small "Soon" badge. Used for the
    /// features that aren't wired to the runtime yet so the layout
    /// matches the reference design without misleading users into
    /// thinking the row does something.
    func soonRow(systemImage: String, label: String) -> some View {
        HStack(spacing: 14) {
            rowIcon(systemImage)
            Text(label)
                .font(.body)
                .foregroundColor(config.appearance.textPrimary.opacity(0.55))
            Spacer()
            soonBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    var soonBadge: some View {
        Text("Soon")
            .font(.caption2.weight(.semibold))
            .foregroundColor(config.appearance.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(config.appearance.background.opacity(0.6))
            .clipShape(Capsule())
    }

    func toggleRow(systemImage: String, label: String, isOn: Binding<Bool>) -> some View {
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

    var toolAccessMenuRow: some View {
        Menu {
            ForEach(ChatViewModel.ToolAccess.allCases, id: \.self) { option in
                Button {
                    toolAccessBinding.wrappedValue = option
                } label: {
                    if option == toolAccessBinding.wrappedValue {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            valueRowLabel(systemImage: "briefcase",
                          label: "Tool access",
                          value: toolAccessBinding.wrappedValue.displayName)
        }
    }
}
