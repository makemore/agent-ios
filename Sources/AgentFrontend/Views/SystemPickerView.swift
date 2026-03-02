import SwiftUI

/// Modal view for selecting which agent system and version the conversation uses
struct SystemPickerView: View {
    let systems: [AgentSystem]
    let selectedSystemSlug: String?
    let selectedVersion: String?
    let isLoading: Bool
    let onSelectSystem: (AgentSystem) -> Void
    let onSelectVersion: (AgentSystemVersionSummary) -> Void
    @Environment(\.dismiss) private var dismiss

    /// The currently selected system object
    private var currentSystem: AgentSystem? {
        guard let slug = selectedSystemSlug else { return nil }
        return systems.first { $0.slug == slug }
    }

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("Loading systems…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if systems.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "square.stack.3d.up.slash")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No Systems Available")
                            .font(.headline)
                        Text("No agent systems have been configured.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        // Systems section
                        Section {
                            ForEach(systems) { system in
                                SystemRowView(
                                    system: system,
                                    isSelected: system.slug == selectedSystemSlug,
                                    onSelect: { onSelectSystem(system) }
                                )
                            }
                        } header: {
                            Text("Systems")
                        }

                        // Version section — shown when a system is selected and has versions
                        if let system = currentSystem,
                           let versions = system.versions, versions.count > 1 {
                            Section {
                                ForEach(versions) { version in
                                    VersionRowView(
                                        version: version,
                                        isSelected: version.version == selectedVersion,
                                        onSelect: { onSelectVersion(version) }
                                    )
                                }
                            } header: {
                                Text("Version — \(system.name)")
                            }
                        }

                        // Members section — shown when a system is selected
                        if let system = currentSystem,
                           let members = system.members, !members.isEmpty {
                            Section {
                                ForEach(members) { member in
                                    MemberRowView(
                                        member: member,
                                        isEntryAgent: member.agent.slug == system.entryAgent?.slug
                                    )
                                }
                            } header: {
                                Text("Agents in \(system.name)")
                            }
                        }
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #endif
                }
            }
            .navigationTitle("System Settings")
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

/// A single system row in the picker
private struct SystemRowView: View {
    let system: AgentSystem
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title2)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(system.name)
                        .font(.headline)
                        .foregroundColor(.primary)

                    if let description = system.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        if let version = system.activeVersion {
                            Label(version, systemImage: "tag")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if let members = system.members, !members.isEmpty {
                            Label("\(members.count) agent\(members.count == 1 ? "" : "s")", systemImage: "person.2")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                        .font(.title3)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

/// A version row — shows version string, status badges
private struct VersionRowView: View {
    let version: AgentSystemVersionSummary
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: "tag")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(version.version)
                            .font(.body)
                            .foregroundColor(.primary)

                        if version.isActive {
                            Text("active")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .foregroundColor(.green)
                                .cornerRadius(4)
                        }

                        if version.isDraft {
                            Text("draft")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .foregroundColor(.orange)
                                .cornerRadius(4)
                        }
                    }

                    if let notes = version.releaseNotes, !notes.isEmpty {
                        Text(notes)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }
}

/// A member agent row — informational, shows agent name and role
private struct MemberRowView: View {
    let member: AgentSystemMember
    let isEntryAgent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isEntryAgent ? "arrow.right.circle.fill" : "person.fill")
                .foregroundColor(isEntryAgent ? .accentColor : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.agent.name)
                        .font(.body)
                        .foregroundColor(.primary)

                    if isEntryAgent {
                        Text("entry point")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundColor(.accentColor)
                            .cornerRadius(4)
                    }
                }

                Text(member.role)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let version = member.agent.activeVersion {
                Text("v\(version)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

