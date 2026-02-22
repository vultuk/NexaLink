//
//  ConnectProjectFlowState.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import Foundation

struct ConnectProjectFlowState {
    var isPresented = false
    var step: ConnectProjectWizardStep = .connection
    var connectionID: String?
    var selectedFolderPath: String?
    var manualFolderPath = ""
    var browsePath: String?
    var remoteFolders: [String] = []
    var isLoadingFolders = false
    var folderLoadGeneration = 0
    var isCreating = false
    var errorMessage: String?

    var trimmedManualFolderPath: String {
        manualFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var parentBrowsePath: String? {
        ConnectProjectHelpers.parentPath(for: browsePath)
    }

    var resolvedFolderPath: String? {
        ConnectProjectHelpers.resolvedFolderPath(
            manualPath: manualFolderPath,
            selectedPath: selectedFolderPath
        )
    }

    mutating func present(preferredConnectionID: String?) {
        step = .connection
        isCreating = false
        isLoadingFolders = false
        errorMessage = nil
        manualFolderPath = ""
        browsePath = nil
        remoteFolders = []
        folderLoadGeneration = 0
        connectionID = preferredConnectionID
        selectedFolderPath = nil
        isPresented = true
    }

    mutating func dismiss() {
        isPresented = false
        step = .connection
        isCreating = false
        isLoadingFolders = false
        errorMessage = nil
        manualFolderPath = ""
        browsePath = nil
        remoteFolders = []
        folderLoadGeneration = 0
        selectedFolderPath = nil
    }

    mutating func selectConnection(_ newConnectionID: String) {
        connectionID = newConnectionID
        manualFolderPath = ""
        selectedFolderPath = nil
        browsePath = nil
        remoteFolders = []
        errorMessage = nil
    }

    mutating func beginFolderLoad() -> Int {
        folderLoadGeneration += 1
        isLoadingFolders = true
        errorMessage = nil
        return folderLoadGeneration
    }

    mutating func applyFolderLoadResult(
        basePath: String?,
        requestedCWD: String?,
        folders: [String],
        errorMessage: String?
    ) {
        isLoadingFolders = false

        if let basePath, !basePath.isEmpty {
            browsePath = basePath
        } else if let requestedCWD, !requestedCWD.isEmpty {
            browsePath = requestedCWD
        }

        remoteFolders = folders
        self.errorMessage = errorMessage
    }
}
