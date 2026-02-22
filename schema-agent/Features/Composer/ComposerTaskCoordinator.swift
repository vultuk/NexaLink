//
//  ComposerTaskCoordinator.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import Foundation

enum ComposerTaskCoordinator {
    static func startTask(
        prompt: String,
        selectedThreadID: String?,
        selectedProjectContext: ConnectedProject?,
        composerSelection: ComposerSelectionState,
        connectionStore: MultiAppServerConnectionStore
    ) -> Bool {
        if let selectedThreadID {
            return connectionStore.startTask(
                prompt: prompt,
                selectedMergedThreadID: selectedThreadID,
                model: composerSelection.selectedModelValue,
                effort: composerSelection.selectedEffortValue,
                collaborationMode: composerSelection.selectedCollaborationModeValue
            )
        }

        guard let selectedProjectContext,
              selectedProjectContext.projectPath != unknownProjectPath else {
            return false
        }

        return connectionStore.startTaskInProject(
            prompt: prompt,
            connectionID: selectedProjectContext.connectionID,
            cwd: selectedProjectContext.projectPath,
            model: composerSelection.selectedModelValue,
            effort: composerSelection.selectedEffortValue,
            collaborationMode: composerSelection.selectedCollaborationModeValue
        )
    }

    static func selectionAfterTaskStartSuccess(
        selectedThreadID: String?,
        selectedProjectID: String?,
        mergedThreads: [MergedAppThread],
        planModeEnabledProjectIDs: Set<String>,
        planModeEnabledThreadIDs: Set<String>
    ) -> (selectedThreadID: String?, planModeEnabledThreadIDs: Set<String>) {
        guard selectedThreadID == nil else {
            return (selectedThreadID, planModeEnabledThreadIDs)
        }

        if let selectedProjectID,
           let matchingThread = mergedThreads.first(where: { thread in
               projectSelectionID(connectionID: thread.connectionID, projectPath: canonicalProjectPath(thread.cwd)) == selectedProjectID
           }) {
            var updatedThreadModes = planModeEnabledThreadIDs
            if planModeEnabledProjectIDs.contains(selectedProjectID) {
                updatedThreadModes.insert(matchingThread.id)
            }
            return (matchingThread.id, updatedThreadModes)
        }

        return (mergedThreads.first?.id, planModeEnabledThreadIDs)
    }

    static func sanitizeModelAndEffortOverrides(
        activeModelIDs: [String],
        selectedModelOverride: String,
        selectedEffortOverride: String,
        effortChoices: [ComposerChoice]
    ) -> (selectedModelOverride: String, selectedEffortOverride: String) {
        let updatedModel: String
        if !selectedModelOverride.isEmpty && !activeModelIDs.contains(selectedModelOverride) {
            updatedModel = ""
        } else {
            updatedModel = selectedModelOverride
        }

        return (
            selectedModelOverride: updatedModel,
            selectedEffortOverride: sanitizeEffortOverride(
                selectedEffortOverride: selectedEffortOverride,
                effortChoices: effortChoices
            )
        )
    }

    static func sanitizeEffortOverride(
        selectedEffortOverride: String,
        effortChoices: [ComposerChoice]
    ) -> String {
        guard !selectedEffortOverride.isEmpty else { return "" }
        guard effortChoices.contains(where: { $0.value == selectedEffortOverride }) else {
            return ""
        }
        return selectedEffortOverride
    }
}
