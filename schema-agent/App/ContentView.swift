//
//  ContentView.swift
//  NexaLink
//
//  Created by Simon Skinner on 21/02/2026.
//

import SwiftUI
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ContentView: View {
    @StateObject private var connectionStore = MultiAppServerConnectionStore()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedThreadID: String?
    @State private var selectedProjectID: String?
    @State private var connectedProjects: [ConnectedProject] = []
    @State private var didConfigureInitialVisibility = false
    @StateObject private var appConnectionsCoordinator = AppConnectionsCoordinator()
    @StateObject private var threadSelectionSideEffects = ThreadSelectionSideEffectsController()
    @State private var newTaskPrompt = ""
    @State private var composerMeasuredHeight: CGFloat = 0
    @State private var selectedModelOverride = ""
    @State private var selectedEffortOverride = ""
    @State private var planModeEnabledThreadIDs: Set<String> = []
    @State private var planModeEnabledProjectIDs: Set<String> = []
    @State private var shouldScrollConversationToBottomOnNextUpdate = true
    @State private var isConversationBottomVisible = true
    @State private var isRunningTasksExpanded = true
    @State private var projectSectionsCache: [ProjectSection] = []
    @State private var visibleActivityCache: [ActivityEntry] = []
    @State private var inlineRunningTasksCache: [MergedRunningTask] = []
    @FocusState private var isComposerFocused: Bool

    private let conversationBottomAnchorID = "conversation-bottom-anchor"

    private var trimmedTaskPrompt: String {
        newTaskPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var connectionStatusByID: [String: ConnectionStatus] {
        Dictionary(uniqueKeysWithValues: connectionStore.connectionStatuses.map { ($0.id, $0) })
    }

    private var selectedProjectContext: ConnectedProject? {
        guard let selectedProjectID else { return nil }
        if let explicit = connectedProjects.first(where: { $0.id == selectedProjectID }) {
            return explicit
        }
        guard let parsed = parseProjectSelectionID(selectedProjectID) else { return nil }
        return ConnectedProject(
            id: selectedProjectID,
            connectionID: parsed.connectionID,
            projectPath: parsed.projectPath
        )
    }

    private var selectedProjectConnectionID: String? {
        selectedProjectContext?.connectionID
    }

    private var selectedProjectPath: String? {
        selectedProjectContext?.projectPath
    }

    private var selectedProjectConnectionName: String? {
        guard let selectedProjectConnectionID else { return nil }
        return connectionStatusByID[selectedProjectConnectionID]?.name ?? selectedProjectConnectionID
    }

    private var activeModelOptions: [AppServerModelOption] {
        if let selectedThreadID {
            return connectionStore.availableModels(for: selectedThreadID)
        }
        if let connectionID = selectedProjectConnectionID {
            return connectionStore.availableModels(connectionID: connectionID)
        }
        return []
    }

    private var activeCollaborationModeOptions: [AppServerCollaborationModeOption] {
        if let selectedThreadID {
            return connectionStore.availableCollaborationModes(for: selectedThreadID)
        }
        if let connectionID = selectedProjectConnectionID {
            return connectionStore.availableCollaborationModes(connectionID: connectionID)
        }
        return []
    }

    private var isPlanModeEnabledForCurrentContext: Bool {
        if let selectedThreadID {
            return planModeEnabledThreadIDs.contains(selectedThreadID)
        }
        if let selectedProjectID {
            return planModeEnabledProjectIDs.contains(selectedProjectID)
        }
        return false
    }

    private var composerSelection: ComposerSelectionState {
        ComposerSelectionState(
            activeModelOptions: activeModelOptions,
            activeCollaborationModeOptions: activeCollaborationModeOptions,
            selectedModelOverride: selectedModelOverride,
            selectedEffortOverride: selectedEffortOverride,
            isPlanModeEnabledForCurrentContext: isPlanModeEnabledForCurrentContext
        )
    }

    private var canStartTask: Bool {
        guard !trimmedTaskPrompt.isEmpty else { return false }
        if let selectedThreadID {
            return connectionStore.canStartTask(for: selectedThreadID)
        }
        if let connectionID = selectedProjectConnectionID,
           let selectedProjectPath,
           selectedProjectPath != unknownProjectPath {
            return connectionStore.canStartTask(connectionID: connectionID)
        }
        return false
    }

    private var isCurrentTargetSubmitting: Bool {
        if let selectedThreadID {
            return connectionStore.isTargetSubmittingTask(for: selectedThreadID)
        }
        if let selectedProjectConnectionID {
            return connectionStore.isSubmittingTask(connectionID: selectedProjectConnectionID)
        }
        return false
    }

    private var visibleActivity: [ActivityEntry] {
        visibleActivityCache
    }

    private var inlineRunningTasks: [MergedRunningTask] {
        inlineRunningTasksCache
    }

    private var connectProjectFlow: ConnectProjectFlowState {
        appConnectionsCoordinator.connectProjectFlow
    }

    private var connectProjectAvailableConnections: [ConnectionStatus] {
        appConnectionsCoordinator.availableConnections(from: connectionStore.connectionStatuses)
    }

    private var selectedConnectProjectConnection: ConnectionStatus? {
        appConnectionsCoordinator.selectedConnectProjectConnection(from: connectProjectAvailableConnections)
    }

    private var connectProjectFolderOptions: [String] {
        appConnectionsCoordinator.connectProjectFolderOptions(connectionStore: connectionStore)
    }

    private var connectProjectParentBrowsePath: String? {
        connectProjectFlow.parentBrowsePath
    }

    private var connectProjectManualFolderPathBinding: Binding<String> {
        Binding(
            get: { appConnectionsCoordinator.connectProjectManualFolderPath },
            set: { newValue in
                appConnectionsCoordinator.setConnectProjectManualFolderPath(newValue)
            }
        )
    }

    private var canContinueConnectProjectWizard: Bool {
        appConnectionsCoordinator.canContinueConnectProjectWizard(with: selectedConnectProjectConnection)
    }

    private var canCreateProjectThread: Bool {
        appConnectionsCoordinator.canCreateProjectThread(with: selectedConnectProjectConnection)
    }

    private var isConnectProjectPresentedBinding: Binding<Bool> {
        Binding(
            get: { connectProjectFlow.isPresented },
            set: { isPresented in
                appConnectionsCoordinator.updateConnectProjectPresentation(isPresented)
            }
        )
    }

    private var isSettingsPresentedBinding: Binding<Bool> {
        Binding(
            get: { appConnectionsCoordinator.isSettingsPresented },
            set: { isPresented in
                if isPresented {
                    appConnectionsCoordinator.openSettings()
                } else {
                    appConnectionsCoordinator.closeSettings()
                }
            }
        )
    }

    private var visibleActivityScrollToken: Int {
        var hasher = Hasher()
        hasher.combine(selectedThreadID)
        hasher.combine(visibleActivity.count)
        if let lastEntry = visibleActivity.last {
            hasher.combine(lastEntry.id)
            hasher.combine(lastEntry.text.count)
            hasher.combine(lastEntry.imageURLs.count)
            hasher.combine(lastEntry.localImagePaths.count)
        }
        hasher.combine(inlineRunningTasks.count)
        if let firstTask = inlineRunningTasks.first {
            hasher.combine(firstTask.id)
            hasher.combine(firstTask.startedAt.timeIntervalSince1970)
        }
        return hasher.finalize()
    }

    private var projectSections: [ProjectSection] {
        projectSectionsCache
    }

    private var runningThreadIDs: Set<String> {
        Set(connectionStore.mergedRunningTasks.map(\.mergedThreadID))
    }

    private var composerMinLines: Int {
        isIPhone ? 1 : 3
    }

    private var composerMaxLines: Int {
        isIPhone ? 10 : 15
    }

    private var composerFieldVerticalPadding: CGFloat {
        isIPhone ? 8 : 10
    }

    private var composerLineHeight: CGFloat {
        #if os(macOS)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return ceil(font.ascender - font.descender + font.leading)
        #else
        UIFont.preferredFont(forTextStyle: .body).lineHeight
        #endif
    }

    private var composerMinHeight: CGFloat {
        CGFloat(composerMinLines) * composerLineHeight + (composerFieldVerticalPadding * 2)
    }

    private var composerMaxHeight: CGFloat {
        CGFloat(composerMaxLines) * composerLineHeight + (composerFieldVerticalPadding * 2)
    }

    private var composerResolvedHeight: CGFloat {
        let measured = composerMeasuredHeight > 0 ? composerMeasuredHeight : composerMinHeight
        return min(max(measured, composerMinHeight), composerMaxHeight)
    }

    private func refreshProjectSectionsCache() {
        projectSectionsCache = ProjectSectionsBuilder.build(
            connectedProjects: connectedProjects,
            mergedThreads: connectionStore.mergedThreads,
            connectionStatusByID: connectionStatusByID
        )
    }

    private func refreshVisibleConversationCache() {
        visibleActivityCache = connectionStore.activityEntries(for: selectedThreadID)
        if let selectedThreadID {
            inlineRunningTasksCache = connectionStore.mergedRunningTasks.filter { $0.mergedThreadID == selectedThreadID }
        } else {
            inlineRunningTasksCache = []
        }
    }

    private func refreshCachesOnAppear() {
        DispatchQueue.main.async {
            refreshProjectSectionsCache()
            refreshVisibleConversationCache()
        }
    }

    private func scheduleVisibleConversationRefresh() {
        DispatchQueue.main.async {
            refreshVisibleConversationCache()
        }
    }

    private func scheduleProjectSectionsRefresh() {
        DispatchQueue.main.async {
            refreshProjectSectionsCache()
        }
    }

    private func applyMergedThreadsSideEffects(_ mergedThreads: [MergedAppThread]) {
        let update = threadSelectionSideEffects.mergedThreadsUpdate(
            mergedThreads: mergedThreads,
            selectedThreadID: selectedThreadID,
            planModeEnabledThreadIDs: planModeEnabledThreadIDs
        )
        selectedThreadID = update.selectedThreadID
        planModeEnabledThreadIDs = update.planModeEnabledThreadIDs
        scheduleProjectSectionsRefresh()
    }

    private func applyConnectionStatusesSideEffects(_ statuses: [ConnectionStatus]) {
        let update = threadSelectionSideEffects.connectionStatusesUpdate(
            statuses: statuses,
            connectedProjects: connectedProjects,
            selectedProjectID: selectedProjectID,
            planModeEnabledProjectIDs: planModeEnabledProjectIDs
        )
        connectedProjects = update.connectedProjects
        selectedProjectID = update.selectedProjectID
        planModeEnabledProjectIDs = update.planModeEnabledProjectIDs
        scheduleProjectSectionsRefresh()
    }

    private func applyTaskStartSuccessSideEffects() {
        newTaskPrompt = ""
        dismissComposerFocus()
        let update = ComposerTaskCoordinator.selectionAfterTaskStartSuccess(
            selectedThreadID: selectedThreadID,
            selectedProjectID: selectedProjectID,
            mergedThreads: connectionStore.mergedThreads,
            planModeEnabledProjectIDs: planModeEnabledProjectIDs,
            planModeEnabledThreadIDs: planModeEnabledThreadIDs
        )
        selectedThreadID = update.selectedThreadID
        planModeEnabledThreadIDs = update.planModeEnabledThreadIDs
    }

    private func sanitizeSelectedEffortOverride() {
        selectedEffortOverride = ComposerTaskCoordinator.sanitizeEffortOverride(
            selectedEffortOverride: selectedEffortOverride,
            effortChoices: composerSelection.effortChoices
        )
    }

    private func applyModelOptionsSideEffects(_ models: [String]) {
        let update = ComposerTaskCoordinator.sanitizeModelAndEffortOverrides(
            activeModelIDs: models,
            selectedModelOverride: selectedModelOverride,
            selectedEffortOverride: selectedEffortOverride,
            effortChoices: composerSelection.effortChoices
        )
        selectedModelOverride = update.selectedModelOverride
        selectedEffortOverride = update.selectedEffortOverride
    }

    private func applySelectedThreadSideEffects(_ threadID: String?) {
        let update = threadSelectionSideEffects.selectedThreadChange(
            to: threadID,
            selectedProjectID: selectedProjectID
        )
        selectedProjectID = update.selectedProjectID
        shouldScrollConversationToBottomOnNextUpdate = update.shouldScrollConversationToBottomOnNextUpdate
        dismissComposerFocus()
        scheduleVisibleConversationRefresh()
        guard let historyThreadID = update.historyThreadIDToLoad else { return }
        connectionStore.loadThreadHistory(for: historyThreadID)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
        } detail: {
            detailColumn
        }
        .onAppear {
            configureInitialSidebarVisibility()
            refreshCachesOnAppear()
        }
        .onReceive(connectionStore.$activityChangeCounter) { _ in
            scheduleVisibleConversationRefresh()
        }
        .onReceive(connectionStore.$mergedRunningTasks) { _ in
            scheduleVisibleConversationRefresh()
        }
        .onChange(of: inlineRunningTasks.map(\.id)) { _, taskIDs in
            if !taskIDs.isEmpty {
                isRunningTasksExpanded = true
            }
        }
        .onReceive(connectionStore.$mergedThreads) { mergedThreads in
            applyMergedThreadsSideEffects(mergedThreads)
        }
        .onReceive(connectionStore.$connectionStatuses) { statuses in
            applyConnectionStatusesSideEffects(statuses)
        }
        .onChange(of: connectedProjects.map(\.id)) { _, _ in
            scheduleProjectSectionsRefresh()
        }
        .onChange(of: connectionStore.taskStartSuccessCount) { _, _ in
            applyTaskStartSuccessSideEffects()
        }
        .onChange(of: composerSelection.activeModelIDs) { _, models in
            applyModelOptionsSideEffects(models)
        }
        .onChange(of: selectedModelOverride) { _, _ in
            sanitizeSelectedEffortOverride()
        }
        .onChange(of: selectedThreadID) { _, threadID in
            applySelectedThreadSideEffects(threadID)
        }
        .sheet(isPresented: isConnectProjectPresentedBinding) {
            connectProjectWizard
        }
        .sheet(isPresented: isSettingsPresentedBinding) {
            settingsModal
        }
        .alert("Archive Failed", isPresented: Binding(
            get: { threadSelectionSideEffects.archiveErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    threadSelectionSideEffects.clearArchiveError()
                }
            }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(threadSelectionSideEffects.archiveErrorMessage ?? "Failed to archive thread.")
        }
    }

    private var sidebarColumn: some View {
        ProjectSidebarView(
            projectSections: projectSections,
            selectedThreadID: $selectedThreadID,
            selectedProjectID: selectedProjectID,
            runningThreadIDs: runningThreadIDs,
            archivingThreadIDs: threadSelectionSideEffects.archivingThreadIDs,
            usesCompactSettingsLayout: usesCompactSettingsLayout,
            onConnectProject: {
                presentConnectProjectWizard()
            },
            onOpenSettings: {
                appConnectionsCoordinator.openSettings()
            },
            onNewThread: { projectID in
                beginNewThread(in: projectID)
            },
            onArchiveThread: { thread in
                archiveThread(thread)
            }
        )
    }

    private var detailColumn: some View {
        VStack(spacing: 0) {
            conversationView
            Divider()
            composer
        }
    }

    private func beginNewThread(in projectID: String) {
        let update = threadSelectionSideEffects.beginNewThreadSelection(for: projectID)
        selectedProjectID = update.selectedProjectID
        selectedThreadID = update.selectedThreadID
        shouldScrollConversationToBottomOnNextUpdate = update.shouldScrollConversationToBottom
    }

    private func archiveThread(_ thread: MergedAppThread) {
        threadSelectionSideEffects.archiveThread(thread, connectionStore: connectionStore) {
            if selectedThreadID == thread.id {
                selectedThreadID = nil
            }
            shouldScrollConversationToBottomOnNextUpdate = true
        }
    }

    private var connectProjectWizard: some View {
        ConnectProjectWizardView(
            step: connectProjectFlow.step,
            availableConnections: connectProjectAvailableConnections,
            selectedConnection: selectedConnectProjectConnection,
            selectedConnectionID: connectProjectFlow.connectionID,
            selectedFolderPath: connectProjectFlow.selectedFolderPath,
            manualFolderPath: connectProjectManualFolderPathBinding,
            browsePath: connectProjectFlow.browsePath,
            folderOptions: connectProjectFolderOptions,
            parentBrowsePath: connectProjectParentBrowsePath,
            isLoadingFolders: connectProjectFlow.isLoadingFolders,
            isCreating: connectProjectFlow.isCreating,
            canContinue: canContinueConnectProjectWizard,
            canCreate: canCreateProjectThread,
            errorMessage: connectProjectFlow.errorMessage,
            onClose: {
                dismissConnectProjectWizard()
            },
            onBack: {
                appConnectionsCoordinator.moveConnectProjectToConnectionStep()
            },
            onNext: {
                appConnectionsCoordinator.moveConnectProjectToFolderStep()
                loadConnectProjectFolders(cwd: nil)
            },
            onCreate: {
                createProjectFromWizard()
            },
            onSelectConnection: { connection in
                appConnectionsCoordinator.selectConnectProjectConnection(connection.id)
            },
            onRefreshFolders: { cwd in
                loadConnectProjectFolders(cwd: cwd)
            },
            onSelectFolder: { folderPath in
                appConnectionsCoordinator.selectConnectProjectFolder(folderPath)
            },
            onOpenFolder: { folderPath in
                loadConnectProjectFolders(cwd: folderPath)
            },
            onManualFolderPathChanged: { newValue in
                appConnectionsCoordinator.handleManualConnectProjectFolderPathChanged(newValue)
            },
            onFolderStepAppear: {
                appConnectionsCoordinator.loadConnectProjectFoldersIfNeeded(connectionStore: connectionStore)
            }
        )
    }

    private var settingsModal: some View {
        ConnectionSettingsModalContainer(
            connectionStore: connectionStore,
            usesCompactLayout: usesCompactSettingsLayout,
            onClose: { appConnectionsCoordinator.closeSettings() }
        )
    }

    private var conversationView: some View {
        ConversationPaneView(
            selectedThreadID: selectedThreadID,
            selectedProjectContext: selectedProjectContext,
            selectedProjectConnectionName: selectedProjectConnectionName,
            visibleActivity: visibleActivity,
            inlineRunningTasks: inlineRunningTasks,
            visibleActivityScrollToken: visibleActivityScrollToken,
            conversationBottomAnchorID: conversationBottomAnchorID,
            isRunningTasksExpanded: $isRunningTasksExpanded,
            shouldScrollConversationToBottomOnNextUpdate: $shouldScrollConversationToBottomOnNextUpdate,
            isConversationBottomVisible: $isConversationBottomVisible,
            onDismissComposerFocus: {
                dismissComposerFocus()
            }
        )
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if os(macOS)
            ZStack(alignment: .topLeading) {
                MacComposerInputView(
                    text: $newTaskPrompt,
                    measuredHeight: $composerMeasuredHeight,
                    minHeight: composerMinHeight,
                    maxHeight: composerMaxHeight,
                    onSubmit: {
                        _ = startComposerTask()
                    }
                )
                .frame(height: composerResolvedHeight)

                if newTaskPrompt.isEmpty {
                    Text("Ask for follow-up changes")
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .padding(.top, 1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, composerFieldVerticalPadding)
            #else
            TextField(
                "",
                text: $newTaskPrompt,
                prompt: Text("Ask for follow-up changes")
                    .foregroundStyle(.secondary),
                axis: .vertical
            )
            .lineLimit(composerMinLines...composerMaxLines)
            .focused($isComposerFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, composerFieldVerticalPadding)
            #endif

            TaskComposerControlsView(
                modelChoices: composerSelection.modelChoices,
                selectedModelValue: composerSelection.selectedModelValue,
                selectedModelLabel: composerSelection.selectedModelLabel,
                onSelectModel: { model in
                    selectedModelOverride = model ?? ""
                },
                effortChoices: composerSelection.effortChoices,
                selectedEffortValue: composerSelection.selectedEffortValue,
                selectedEffortLabel: composerSelection.selectedEffortLabel,
                onSelectEffort: { effort in
                    selectedEffortOverride = effort ?? ""
                },
                areModelChoicesDisabled: activeModelOptions.isEmpty,
                isPlanModeEnabled: isPlanModeEnabledForCurrentContext,
                canTogglePlanMode: composerSelection.canTogglePlanMode,
                onTogglePlanMode: {
                    togglePlanModeForCurrentContext()
                },
                isSubmitting: isCurrentTargetSubmitting,
                canStartTask: canStartTask,
                onStartTask: {
                    _ = startComposerTask()
                }
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @discardableResult
    private func startComposerTask() -> Bool {
        let started = ComposerTaskCoordinator.startTask(
            prompt: newTaskPrompt,
            selectedThreadID: selectedThreadID,
            selectedProjectContext: selectedProjectContext,
            composerSelection: composerSelection,
            connectionStore: connectionStore
        )
        if started {
            dismissComposerFocus()
        }
        return started
    }

    private func togglePlanModeForCurrentContext() {
        guard composerSelection.canTogglePlanMode else { return }
        if let selectedThreadID {
            if planModeEnabledThreadIDs.contains(selectedThreadID) {
                planModeEnabledThreadIDs.remove(selectedThreadID)
            } else {
                planModeEnabledThreadIDs.insert(selectedThreadID)
            }
            return
        }

        guard let selectedProjectID else { return }
        if planModeEnabledProjectIDs.contains(selectedProjectID) {
            planModeEnabledProjectIDs.remove(selectedProjectID)
        } else {
            planModeEnabledProjectIDs.insert(selectedProjectID)
        }
    }

    private func configureInitialSidebarVisibility() {
        guard !didConfigureInitialVisibility else { return }
        didConfigureInitialVisibility = true

        if isIPhone {
            columnVisibility = .detailOnly
        } else {
            columnVisibility = .all
        }
    }

    private func presentConnectProjectWizard() {
        appConnectionsCoordinator.presentConnectProjectWizard(connectionStatuses: connectionStore.connectionStatuses)
    }

    private func dismissConnectProjectWizard() {
        appConnectionsCoordinator.dismissConnectProjectWizard()
    }

    private func loadConnectProjectFolders(cwd: String?) {
        appConnectionsCoordinator.loadConnectProjectFolders(cwd: cwd, connectionStore: connectionStore)
    }

    private func createProjectFromWizard() {
        guard let update = appConnectionsCoordinator.createProjectFromWizard(connectedProjects: connectedProjects) else {
            return
        }
        connectedProjects = update.connectedProjects
        selectedProjectID = update.selectedProjectID
        selectedThreadID = update.selectedThreadID
        shouldScrollConversationToBottomOnNextUpdate = update.shouldScrollConversationToBottomOnNextUpdate
    }

    private func dismissComposerFocus() {
        #if os(macOS)
        NSApp.keyWindow?.makeFirstResponder(nil)
        #else
        isComposerFocused = false
        #endif
        #if os(iOS)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private var isIPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var usesCompactSettingsLayout: Bool {
        isIPhone
    }
}


struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
