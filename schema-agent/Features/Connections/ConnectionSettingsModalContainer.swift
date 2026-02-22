//
//  ConnectionSettingsModalContainer.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import SwiftUI

struct ConnectionSettingsModalContainer: View {
    @ObservedObject var connectionStore: MultiAppServerConnectionStore
    let usesCompactLayout: Bool
    let onClose: () -> Void

    @State private var selectedSettingsSection: SettingsSection? = .connections
    @State private var isAddConnectionPresented = false
    @State private var draftConnectionName = ""
    @State private var draftConnectionHost = ConnectionDraftDefaults.host
    @State private var draftConnectionPort = ConnectionDraftDefaults.port
    @State private var draftConnectionColor = colorFromHex(ConnectionDraftDefaults.colorHex)
    @State private var isEditConnectionPresented = false
    @State private var editConnectionID: String?
    @State private var editConnectionName = ""
    @State private var editConnectionHost = ConnectionDraftDefaults.host
    @State private var editConnectionPort = ConnectionDraftDefaults.port
    @State private var editConnectionColor = colorFromHex(ConnectionDraftDefaults.colorHex)
    @State private var pendingDeleteConnectionID: String?
    @State private var pendingDeleteConnectionName = ""

    var body: some View {
        SettingsModalView(
            usesCompactLayout: usesCompactLayout,
            selectedSection: $selectedSettingsSection,
            onClose: onClose,
            onAdd: { presentAddConnectionSheet() }
        ) {
            compactConnectionsSettings
        } connectionsContent: {
            connectionsSettings
        }
    }

    private var connectionsSettings: some View {
        withConnectionSettingsPresentation {
            ConnectionsSettingsPanel(
                connections: connectionStore.connectionStatuses,
                onAdd: { presentAddConnectionSheet() },
                onEdit: { connection in
                    presentEditConnectionSheet(connection)
                },
                onDelete: { connection in
                    presentConnectionDeleteConfirmation(connection)
                },
                enabledBinding: { connection in
                    connectionEnabledBinding(for: connection)
                },
                colorBinding: { connection in
                    connectionColorBinding(for: connection)
                },
                statusColor: { connection in
                    connectionStatusColor(connection.state)
                }
            )
        }
    }

    private var compactConnectionsSettings: some View {
        withConnectionSettingsPresentation {
            CompactConnectionsSettingsPanel(
                connections: connectionStore.connectionStatuses,
                onEdit: { connection in
                    presentEditConnectionSheet(connection)
                },
                onDelete: { connection in
                    presentConnectionDeleteConfirmation(connection)
                },
                enabledBinding: { connection in
                    connectionEnabledBinding(for: connection)
                },
                statusColor: { connection in
                    connectionStatusColor(connection.state)
                }
            )
        }
    }

    private func withConnectionSettingsPresentation<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .sheet(isPresented: $isAddConnectionPresented) {
                addConnectionSheet
            }
            .sheet(isPresented: $isEditConnectionPresented) {
                editConnectionSheet
            }
            .confirmationDialog(
                "Delete Connection",
                isPresented: Binding(
                    get: { pendingDeleteConnectionID != nil },
                    set: { isPresented in
                        if !isPresented {
                            clearPendingConnectionDeletion()
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete \"\(pendingDeleteConnectionName)\"", role: .destructive) {
                    guard let connectionID = pendingDeleteConnectionID else { return }
                    connectionStore.deleteConnection(connectionID: connectionID)
                    clearPendingConnectionDeletion()
                }
                Button("Cancel", role: .cancel) {
                    clearPendingConnectionDeletion()
                }
            } message: {
                Text("This removes the saved connection from NexaLink.")
            }
    }

    private func presentConnectionDeleteConfirmation(_ connection: ConnectionStatus) {
        pendingDeleteConnectionID = connection.id
        pendingDeleteConnectionName = connection.name
    }

    private func connectionEnabledBinding(for connection: ConnectionStatus) -> Binding<Bool> {
        Binding(
            get: { connection.isEnabled },
            set: { isEnabled in
                connectionStore.setConnectionEnabled(isEnabled, connectionID: connection.id)
            }
        )
    }

    private func connectionColorBinding(for connection: ConnectionStatus) -> Binding<Color> {
        Binding(
            get: { colorFromHex(connection.colorHex) },
            set: { newColor in
                connectionStore.setConnectionColor(
                    hexString(from: newColor),
                    connectionID: connection.id
                )
            }
        )
    }

    private var addConnectionSheet: some View {
        ConnectionEditorSheetView(
            title: "Add Connection",
            subtitle: "Add a websocket endpoint for merged thread data.",
            actionTitle: "Add",
            usesCompactLayout: usesCompactLayout,
            canSubmit: canAddDraftConnection,
            name: $draftConnectionName,
            host: $draftConnectionHost,
            port: $draftConnectionPort,
            color: $draftConnectionColor,
            onCancel: { isAddConnectionPresented = false },
            onSubmit: {
                connectionStore.addConnection(
                    name: draftConnectionName,
                    host: normalizedDraftConnectionHost,
                    port: normalizedDraftConnectionPort,
                    colorHex: hexString(from: draftConnectionColor)
                )
                isAddConnectionPresented = false
            }
        )
    }

    private var editConnectionSheet: some View {
        ConnectionEditorSheetView(
            title: "Edit Connection",
            subtitle: "Update websocket endpoint settings.",
            actionTitle: "Save",
            usesCompactLayout: usesCompactLayout,
            canSubmit: canSaveEditedConnection,
            name: $editConnectionName,
            host: $editConnectionHost,
            port: $editConnectionPort,
            color: $editConnectionColor,
            onCancel: { clearEditConnectionDraft() },
            onSubmit: {
                guard let connectionID = editConnectionID else { return }
                connectionStore.updateConnection(
                    connectionID: connectionID,
                    name: editConnectionName,
                    host: normalizedEditConnectionHost,
                    port: normalizedEditConnectionPort,
                    colorHex: hexString(from: editConnectionColor)
                )
                clearEditConnectionDraft()
            }
        )
    }

    private func presentAddConnectionSheet() {
        draftConnectionName = ""
        draftConnectionHost = ConnectionDraftDefaults.host
        draftConnectionPort = ConnectionDraftDefaults.port
        draftConnectionColor = colorFromHex(ConnectionDraftDefaults.colorHex)
        isAddConnectionPresented = true
    }

    private func presentEditConnectionSheet(_ connection: ConnectionStatus) {
        editConnectionID = connection.id
        editConnectionName = connection.name
        editConnectionHost = connection.host
        editConnectionPort = connection.port
        editConnectionColor = colorFromHex(connection.colorHex)
        isEditConnectionPresented = true
    }

    private func clearEditConnectionDraft() {
        isEditConnectionPresented = false
        editConnectionID = nil
        editConnectionName = ""
        editConnectionHost = ConnectionDraftDefaults.host
        editConnectionPort = ConnectionDraftDefaults.port
        editConnectionColor = colorFromHex(ConnectionDraftDefaults.colorHex)
    }

    private func clearPendingConnectionDeletion() {
        pendingDeleteConnectionID = nil
        pendingDeleteConnectionName = ""
    }

    private var normalizedDraftConnectionHost: String {
        ConnectProjectHelpers.normalizedHost(draftConnectionHost)
    }

    private var normalizedDraftConnectionPort: String {
        ConnectProjectHelpers.normalizedPort(draftConnectionPort)
    }

    private var normalizedEditConnectionHost: String {
        ConnectProjectHelpers.normalizedHost(editConnectionHost)
    }

    private var normalizedEditConnectionPort: String {
        ConnectProjectHelpers.normalizedPort(editConnectionPort)
    }

    private var canAddDraftConnection: Bool {
        ConnectProjectHelpers.canSubmitConnection(
            name: draftConnectionName,
            host: draftConnectionHost,
            normalizedPort: normalizedDraftConnectionPort
        )
    }

    private var canSaveEditedConnection: Bool {
        guard editConnectionID != nil else { return false }
        return ConnectProjectHelpers.canSubmitConnection(
            name: editConnectionName,
            host: editConnectionHost,
            normalizedPort: normalizedEditConnectionPort
        )
    }

    private func connectionStatusColor(_ state: AppServerConnectionState) -> Color {
        switch state {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .failed:
            return .red
        case .disconnected:
            return .secondary
        }
    }
}
