//
//  AppConnectionsCoordinator.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import Foundation
import SwiftUI
import Combine

struct ConnectProjectCreationUpdate {
    let connectedProjects: [ConnectedProject]
    let selectedProjectID: String?
    let selectedThreadID: String?
    let shouldScrollConversationToBottomOnNextUpdate: Bool
}

@MainActor
final class AppConnectionsCoordinator: ObservableObject {
    @Published private(set) var connectProjectFlow = ConnectProjectFlowState()
    @Published var isSettingsPresented = false

    var connectProjectManualFolderPath: String {
        connectProjectFlow.manualFolderPath
    }

    func openSettings() {
        isSettingsPresented = true
    }

    func closeSettings() {
        isSettingsPresented = false
    }

    func updateConnectProjectPresentation(_ isPresented: Bool) {
        if isPresented {
            connectProjectFlow.isPresented = true
        } else {
            dismissConnectProjectWizard()
        }
    }

    func presentConnectProjectWizard(connectionStatuses: [ConnectionStatus]) {
        let preferredConnection = connectionStatuses.first(where: { $0.isEnabled && $0.state == .connected })
            ?? connectionStatuses.first(where: \.isEnabled)
            ?? connectionStatuses.first

        connectProjectFlow.present(preferredConnectionID: preferredConnection?.id)
    }

    func dismissConnectProjectWizard() {
        connectProjectFlow.dismiss()
    }

    func availableConnections(from statuses: [ConnectionStatus]) -> [ConnectionStatus] {
        statuses
    }

    func selectedConnectProjectConnection(from statuses: [ConnectionStatus]) -> ConnectionStatus? {
        guard let connectionID = connectProjectFlow.connectionID else { return nil }
        return statuses.first(where: { $0.id == connectionID })
    }

    func connectProjectKnownFolders(connectionStore: MultiAppServerConnectionStore) -> [String] {
        guard let connectionID = connectProjectFlow.connectionID else { return [] }
        return connectionStore.knownProjectFolders(connectionID: connectionID)
    }

    func connectProjectFolderOptions(connectionStore: MultiAppServerConnectionStore) -> [String] {
        ConnectProjectHelpers.mergedFolderOptions(
            remoteFolders: connectProjectFlow.remoteFolders,
            knownFolders: connectProjectKnownFolders(connectionStore: connectionStore)
        )
    }

    func canContinueConnectProjectWizard(with selectedConnection: ConnectionStatus?) -> Bool {
        guard let selectedConnection else { return false }
        return selectedConnection.isEnabled
    }

    func canCreateProjectThread(with selectedConnection: ConnectionStatus?) -> Bool {
        guard let selectedConnection else { return false }
        guard selectedConnection.isEnabled else { return false }
        guard selectedConnection.state == .connected else { return false }
        guard let path = connectProjectFlow.resolvedFolderPath, !path.isEmpty else { return false }
        return !connectProjectFlow.isCreating
    }

    func moveConnectProjectToConnectionStep() {
        connectProjectFlow.errorMessage = nil
        connectProjectFlow.step = .connection
    }

    func moveConnectProjectToFolderStep() {
        connectProjectFlow.errorMessage = nil
        connectProjectFlow.step = .folder
    }

    func selectConnectProjectConnection(_ connectionID: String) {
        connectProjectFlow.selectConnection(connectionID)
    }

    func selectConnectProjectFolder(_ folderPath: String) {
        connectProjectFlow.selectedFolderPath = folderPath
        connectProjectFlow.manualFolderPath = ""
        connectProjectFlow.errorMessage = nil
    }

    func setConnectProjectManualFolderPath(_ value: String) {
        connectProjectFlow.manualFolderPath = value
        handleManualConnectProjectFolderPathChanged(value)
    }

    func handleManualConnectProjectFolderPathChanged(_ newValue: String) {
        if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            connectProjectFlow.selectedFolderPath = nil
        }
    }

    func loadConnectProjectFolders(
        cwd: String?,
        connectionStore: MultiAppServerConnectionStore
    ) {
        guard let connectionID = connectProjectFlow.connectionID else {
            connectProjectFlow.errorMessage = "Choose a connection first."
            return
        }

        let loadGeneration = connectProjectFlow.beginFolderLoad()
        let expectedConnectionID = connectionID

        connectionStore.listRemoteFolders(connectionID: connectionID, cwd: cwd) { [weak self] basePath, folders, errorMessage in
            guard let self else { return }
            guard self.connectProjectFlow.folderLoadGeneration == loadGeneration else { return }
            guard self.connectProjectFlow.connectionID == expectedConnectionID else { return }

            self.connectProjectFlow.applyFolderLoadResult(
                basePath: basePath,
                requestedCWD: cwd,
                folders: folders,
                errorMessage: errorMessage?.isEmpty == false ? errorMessage : nil
            )

            if self.connectProjectFlow.trimmedManualFolderPath.isEmpty {
                let mergedFolderOptions = self.connectProjectFolderOptions(connectionStore: connectionStore)
                if let selected = self.connectProjectFlow.selectedFolderPath,
                   mergedFolderOptions.contains(selected) {
                    // Keep prior selection when still visible.
                } else {
                    self.connectProjectFlow.selectedFolderPath = mergedFolderOptions.first
                }
            }
        }
    }

    func loadConnectProjectFoldersIfNeeded(connectionStore: MultiAppServerConnectionStore) {
        let mergedFolderOptions = connectProjectFolderOptions(connectionStore: connectionStore)
        if mergedFolderOptions.isEmpty && !connectProjectFlow.isLoadingFolders {
            loadConnectProjectFolders(cwd: connectProjectFlow.browsePath, connectionStore: connectionStore)
        }
    }

    func createProjectFromWizard(
        connectedProjects: [ConnectedProject]
    ) -> ConnectProjectCreationUpdate? {
        guard let connectionID = connectProjectFlow.connectionID else {
            connectProjectFlow.errorMessage = "Choose a connection first."
            return nil
        }
        guard let folderPath = connectProjectFlow.resolvedFolderPath, !folderPath.isEmpty else {
            connectProjectFlow.errorMessage = "Choose a folder path first."
            return nil
        }

        connectProjectFlow.isCreating = true
        connectProjectFlow.errorMessage = nil

        let normalizedPath = canonicalProjectPath(folderPath)
        let projectID = projectSelectionID(connectionID: connectionID, projectPath: normalizedPath)

        var updatedProjects = connectedProjects
        if !updatedProjects.contains(where: { $0.id == projectID }) {
            updatedProjects.insert(
                ConnectedProject(
                    id: projectID,
                    connectionID: connectionID,
                    projectPath: normalizedPath
                ),
                at: 0
            )
        }

        connectProjectFlow.isCreating = false
        dismissConnectProjectWizard()

        return ConnectProjectCreationUpdate(
            connectedProjects: updatedProjects,
            selectedProjectID: projectID,
            selectedThreadID: nil,
            shouldScrollConversationToBottomOnNextUpdate: true
        )
    }
}
