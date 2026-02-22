//
//  ConnectProjectWizardView.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import SwiftUI

struct ConnectProjectWizardView: View {
    let step: ConnectProjectWizardStep
    let availableConnections: [ConnectionStatus]
    let selectedConnection: ConnectionStatus?
    let selectedConnectionID: String?
    let selectedFolderPath: String?
    @Binding var manualFolderPath: String
    let browsePath: String?
    let folderOptions: [String]
    let parentBrowsePath: String?
    let isLoadingFolders: Bool
    let isCreating: Bool
    let canContinue: Bool
    let canCreate: Bool
    let errorMessage: String?
    let onClose: () -> Void
    let onBack: () -> Void
    let onNext: () -> Void
    let onCreate: () -> Void
    let onSelectConnection: (ConnectionStatus) -> Void
    let onRefreshFolders: (String?) -> Void
    let onSelectFolder: (String) -> Void
    let onOpenFolder: (String) -> Void
    let onManualFolderPathChanged: (String) -> Void
    let onFolderStepAppear: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connect Project")
                            .font(.title3.weight(.semibold))
                        Text(step == .connection ? "Step 1 of 2: Select connection" : "Step 2 of 2: Select folder")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(Color.secondary.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                Divider()

                Group {
                    switch step {
                    case .connection:
                        connectionStep
                    case .folder:
                        folderStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Divider()

                HStack(spacing: 10) {
                    Button("Cancel", action: onClose)
                        .buttonStyle(.bordered)

                    if step == .folder {
                        Button("Back", action: onBack)
                            .buttonStyle(.bordered)
                    }

                    Spacer()

                    if step == .connection {
                        Button("Next", action: onNext)
                            .buttonStyle(.borderedProminent)
                            .disabled(!canContinue)
                    } else {
                        Button(action: onCreate) {
                            if isCreating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Add Project")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canCreate)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .frame(minWidth: 640, minHeight: 520)
        }
    }

    private var connectionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose which connection this project should use.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if availableConnections.isEmpty {
                Text("No connections configured yet. Add one in Settings first.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(availableConnections) { connection in
                            connectProjectConnectionRow(connection)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if let connection = selectedConnection, !connection.isEnabled {
                Text("This connection is disabled. Enable it in Settings before continuing.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func connectProjectConnectionRow(_ connection: ConnectionStatus) -> some View {
        let isSelected = selectedConnectionID == connection.id
        return Button {
            onSelectConnection(connection)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(connection.name)
                            .font(.headline)
                        Text(connection.stateLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(connectionStatusColor(connection.state))
                    }

                    Text("\(connection.host):\(connection.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !connection.isEnabled {
                    Text("Disabled")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.12))
                        )
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.16), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var folderStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let selectedConnection {
                Text("Choose a folder for \(selectedConnection.name).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Choose a folder.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Browsing")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(browsePath ?? "Resolving current folder...")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if isLoadingFolders {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    onRefreshFolders(browsePath)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isLoadingFolders || selectedConnectionID == nil)

                if let parentBrowsePath {
                    Button {
                        onRefreshFolders(parentBrowsePath)
                    } label: {
                        Image(systemName: "arrow.up.left")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLoadingFolders)
                }
            }

            if folderOptions.isEmpty {
                Text(isLoadingFolders
                     ? "Loading folders..."
                     : "No folders found in this location. You can still enter a full folder path below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            } else {
                Text("Folders")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(folderOptions, id: \.self) { folderPath in
                            HStack(spacing: 8) {
                                Button {
                                    onSelectFolder(folderPath)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: selectedFolderPath == folderPath ? "checkmark.circle.fill" : "folder")
                                            .foregroundStyle(selectedFolderPath == folderPath ? Color.accentColor : Color.secondary)
                                        Text(folderPath)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    onOpenFolder(folderPath)
                                } label: {
                                    Image(systemName: "chevron.right.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open folder")
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(selectedFolderPath == folderPath ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06))
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 220)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Folder Path")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("/absolute/path/to/project", text: $manualFolderPath)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.secondary.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    )
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onChange(of: manualFolderPath) { _, newValue in
                        onManualFolderPathChanged(newValue)
                    }
            }

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let connection = selectedConnection, connection.state != .connected {
                Text("Connection is currently \(connection.stateLabel.lowercased()). Wait until it is connected to add this project.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .onAppear(perform: onFolderStepAppear)
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
