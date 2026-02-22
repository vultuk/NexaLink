//
//  ConnectionsSettingsPanels.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import SwiftUI

struct ConnectionsSettingsPanel: View {
    let connections: [ConnectionStatus]
    let onAdd: () -> Void
    let onEdit: (ConnectionStatus) -> Void
    let onDelete: (ConnectionStatus) -> Void
    let enabledBinding: (ConnectionStatus) -> Binding<Bool>
    let colorBinding: (ConnectionStatus) -> Binding<Color>
    let statusColor: (ConnectionStatus) -> Color

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Connections")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button(action: onAdd) {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }

                Text("All enabled websocket connections auto-connect on launch.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if connections.isEmpty {
                    Text("No connections configured yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 10)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(connections) { connection in
                            ConnectionSettingsCard(
                                connection: connection,
                                isEnabled: enabledBinding(connection),
                                color: colorBinding(connection),
                                statusColor: statusColor(connection),
                                onEdit: { onEdit(connection) },
                                onDelete: { onDelete(connection) }
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
    }
}

struct CompactConnectionsSettingsPanel: View {
    let connections: [ConnectionStatus]
    let onEdit: (ConnectionStatus) -> Void
    let onDelete: (ConnectionStatus) -> Void
    let enabledBinding: (ConnectionStatus) -> Binding<Bool>
    let statusColor: (ConnectionStatus) -> Color

    var body: some View {
        List {
            Section {
                Text("All enabled websocket connections auto-connect on launch.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Connections") {
                if connections.isEmpty {
                    Text("No connections configured yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(connections) { connection in
                        CompactConnectionSettingsRow(
                            connection: connection,
                            isEnabled: enabledBinding(connection),
                            statusColor: statusColor(connection),
                            colorHex: connection.colorHex,
                            onEdit: { onEdit(connection) },
                            onDelete: { onDelete(connection) }
                        )
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
    }
}
