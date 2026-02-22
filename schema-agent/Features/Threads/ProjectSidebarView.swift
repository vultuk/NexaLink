//
//  ProjectSidebarView.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import SwiftUI

struct ProjectSidebarView: View {
    let projectSections: [ProjectSection]
    @Binding var selectedThreadID: String?
    let selectedProjectID: String?
    let runningThreadIDs: Set<String>
    let archivingThreadIDs: Set<String>
    let usesCompactSettingsLayout: Bool
    let onConnectProject: () -> Void
    let onOpenSettings: () -> Void
    let onNewThread: (String) -> Void
    let onArchiveThread: (MergedAppThread) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onConnectProject) {
                Label("Connect project", systemImage: "square.and.pencil")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Divider()
                .padding(.vertical, 10)

            HStack {
                Text("Threads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)

            List(selection: $selectedThreadID) {
                ForEach(projectSections) { section in
                    projectSection(section)
                }
            }
            .listStyle(.sidebar)

            Divider()

            Button(action: onOpenSettings) {
                Label("Settings", systemImage: "gearshape")
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .navigationTitle("NexaLink")
    }

    @ViewBuilder
    private func projectSection(_ section: ProjectSection) -> some View {
        Section {
            ForEach(section.threads) { thread in
                projectThreadRow(thread)
            }

            if section.threads.isEmpty {
                Text("No threads yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            }
        } header: {
            projectSectionHeader(section)
        }
    }

    private func projectThreadRow(_ thread: MergedAppThread) -> some View {
        let isRunning = runningThreadIDs.contains(thread.id)
        let isArchiving = archivingThreadIDs.contains(thread.id)
        return HStack(alignment: .center, spacing: 10) {
            Group {
                if isRunning {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    Color.clear
                }
            }
            .frame(width: 12, height: 12)

            Text(thread.title)
                .font(.subheadline)
                .lineLimit(1)

            Spacer(minLength: 6)

            Text(thread.updatedAtText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .tag(thread.id)
        .contextMenu {
            Button(role: .destructive) {
                onArchiveThread(thread)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .disabled(isArchiving)
        }
    }

    private func projectSectionHeader(_ section: ProjectSection) -> some View {
        let isProjectSelected = selectedThreadID == nil && selectedProjectID == section.id
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(section.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isProjectSelected ? Color.accentColor : Color.primary)
                .lineLimit(1)

            Text(section.connectionName)
                .font(.caption2.weight(.semibold))
                .foregroundColor(colorFromHex(section.connectionColorHex))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(colorFromHex(section.connectionColorHex).opacity(0.14))
                )

            if let subtitle = section.subtitle {
                Text("•")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !usesCompactSettingsLayout {
                Spacer(minLength: 0)
            }

            Button {
                onNewThread(section.id)
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Start new thread")
        }
        .textCase(nil)
    }
}
