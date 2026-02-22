//
//  ThreadSelectionSideEffectsController.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import SwiftUI
import Foundation
import Combine

@MainActor
final class ThreadSelectionSideEffectsController: ObservableObject {
    @Published private(set) var archivingThreadIDs: Set<String> = []
    @Published var archiveErrorMessage: String?

    func clearArchiveError() {
        archiveErrorMessage = nil
    }

    func beginNewThreadSelection(for projectID: String) -> (selectedProjectID: String?, selectedThreadID: String?, shouldScrollConversationToBottom: Bool) {
        (
            selectedProjectID: projectID,
            selectedThreadID: nil,
            shouldScrollConversationToBottom: true
        )
    }

    func mergedThreadsUpdate(
        mergedThreads: [MergedAppThread],
        selectedThreadID: String?,
        planModeEnabledThreadIDs: Set<String>
    ) -> (selectedThreadID: String?, planModeEnabledThreadIDs: Set<String>) {
        let threadIDs = Set(mergedThreads.map(\.id))
        let updatedSelectedThreadID = selectedThreadID.flatMap { threadIDs.contains($0) ? $0 : nil }
        let updatedPlanModeThreadIDs = planModeEnabledThreadIDs.intersection(threadIDs)
        return (updatedSelectedThreadID, updatedPlanModeThreadIDs)
    }

    func connectionStatusesUpdate(
        statuses: [ConnectionStatus],
        connectedProjects: [ConnectedProject],
        selectedProjectID: String?,
        planModeEnabledProjectIDs: Set<String>
    ) -> (connectedProjects: [ConnectedProject], selectedProjectID: String?, planModeEnabledProjectIDs: Set<String>) {
        let validConnectionIDs = Set(statuses.map(\.id))
        let updatedProjects = connectedProjects.filter { validConnectionIDs.contains($0.connectionID) }

        let updatedSelectedProjectID: String?
        if let selectedProjectID,
           let parsed = parseProjectSelectionID(selectedProjectID),
           !validConnectionIDs.contains(parsed.connectionID) {
            updatedSelectedProjectID = nil
        } else {
            updatedSelectedProjectID = selectedProjectID
        }

        let updatedProjectModes = Set(planModeEnabledProjectIDs.filter { projectID in
            guard let parsed = parseProjectSelectionID(projectID) else { return false }
            return validConnectionIDs.contains(parsed.connectionID)
        })

        return (
            connectedProjects: updatedProjects,
            selectedProjectID: updatedSelectedProjectID,
            planModeEnabledProjectIDs: updatedProjectModes
        )
    }

    func selectedThreadChange(
        to threadID: String?,
        selectedProjectID: String?
    ) -> (selectedProjectID: String?, shouldScrollConversationToBottomOnNextUpdate: Bool, historyThreadIDToLoad: String?) {
        (
            selectedProjectID: threadID == nil ? selectedProjectID : nil,
            shouldScrollConversationToBottomOnNextUpdate: true,
            historyThreadIDToLoad: threadID
        )
    }

    func archiveThread(
        _ thread: MergedAppThread,
        connectionStore: MultiAppServerConnectionStore,
        onArchived: @escaping () -> Void
    ) {
        let mergedThreadID = thread.id
        guard !archivingThreadIDs.contains(mergedThreadID) else { return }
        archivingThreadIDs.insert(mergedThreadID)

        connectionStore.archiveThread(mergedThreadID: mergedThreadID) { [weak self] success, errorMessage in
            Task { @MainActor in
                guard let self else { return }
                self.archivingThreadIDs.remove(mergedThreadID)
                guard success else {
                    if let errorMessage, !errorMessage.isEmpty {
                        self.archiveErrorMessage = errorMessage
                    } else {
                        self.archiveErrorMessage = "Could not archive \"\(thread.title)\"."
                    }
                    return
                }
                onArchived()
            }
        }
    }
}
