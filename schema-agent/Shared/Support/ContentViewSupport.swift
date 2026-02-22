//
//  ContentViewSupport.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import Foundation

enum ConnectionDraftDefaults {
    static let host = "127.0.0.1"
    static let port = "9281"
    static let colorHex = SavedAppServerConnection.defaultColorHex
}

struct ComposerSelectionState {
    let activeModelOptions: [AppServerModelOption]
    let activeCollaborationModeOptions: [AppServerCollaborationModeOption]
    let selectedModelOverride: String
    let selectedEffortOverride: String
    let isPlanModeEnabledForCurrentContext: Bool

    var defaultModelOption: AppServerModelOption? {
        activeModelOptions.first(where: \.isDefault) ?? activeModelOptions.first
    }

    var defaultModelLabel: String {
        defaultModelOption?.displayName ?? "Server Default"
    }

    var modelChoices: [ComposerChoice] {
        var choices = [ComposerChoice(id: "model-default", label: "Default (\(defaultModelLabel))", value: nil)]
        choices.append(
            contentsOf: activeModelOptions.map { model in
                ComposerChoice(id: "model-\(model.id)", label: model.displayName, value: model.model)
            }
        )
        return choices
    }

    var selectedModelValue: String? {
        guard !selectedModelOverride.isEmpty else { return nil }
        guard activeModelOptions.contains(where: { $0.model == selectedModelOverride }) else {
            return nil
        }
        return selectedModelOverride
    }

    var selectedModelOption: AppServerModelOption? {
        if let selectedModelValue {
            return activeModelOptions.first(where: { $0.model == selectedModelValue })
        }
        return defaultModelOption
    }

    var defaultReasoningLabel: String {
        guard let selectedModelOption else { return "Default Reasoning" }
        guard !selectedModelOption.defaultReasoningEffort.isEmpty else { return "Default Reasoning" }
        return "Default (\(reasoningEffortDisplayName(selectedModelOption.defaultReasoningEffort)))"
    }

    var effortChoices: [ComposerChoice] {
        var choices = [ComposerChoice(id: "effort-default", label: defaultReasoningLabel, value: nil)]
        guard let selectedModelOption else { return choices }

        var seenEfforts = Set<String>()
        for option in selectedModelOption.supportedReasoningEfforts {
            if !seenEfforts.insert(option.reasoningEffort).inserted {
                continue
            }
            choices.append(
                ComposerChoice(
                    id: "effort-\(option.id)",
                    label: reasoningEffortDisplayName(option.reasoningEffort),
                    value: option.reasoningEffort
                )
            )
        }
        return choices
    }

    var selectedEffortValue: String? {
        guard !selectedEffortOverride.isEmpty else { return nil }
        guard effortChoices.contains(where: { $0.value == selectedEffortOverride }) else {
            return nil
        }
        return selectedEffortOverride
    }

    var selectedModelLabel: String {
        if let selectedModelValue {
            return modelChoices.first(where: { $0.value == selectedModelValue })?.label ?? selectedModelValue
        }
        return defaultModelLabel
    }

    var selectedEffortLabel: String {
        if let selectedEffortValue {
            return effortChoices.first(where: { $0.value == selectedEffortValue })?.label ?? selectedEffortValue
        }
        guard let selectedModelOption,
              !selectedModelOption.defaultReasoningEffort.isEmpty else {
            return "Reasoning"
        }
        return reasoningEffortDisplayName(selectedModelOption.defaultReasoningEffort)
    }

    var planCollaborationMode: AppServerCollaborationModeOption? {
        activeCollaborationModeOptions.first { option in
            option.mode.caseInsensitiveCompare("plan") == .orderedSame
        }
    }

    var defaultCollaborationMode: AppServerCollaborationModeOption? {
        if let explicitDefault = activeCollaborationModeOptions.first(where: { option in
            option.mode.caseInsensitiveCompare("default") == .orderedSame
        }) {
            return explicitDefault
        }
        if let flaggedDefault = activeCollaborationModeOptions.first(where: \.isDefault) {
            return flaggedDefault
        }
        guard planCollaborationMode != nil else { return nil }
        return AppServerCollaborationModeOption(
            id: "default",
            mode: "default",
            displayName: "Default",
            isDefault: true,
            settingsModel: nil
        )
    }

    var collaborationModeModelValue: String? {
        if let selectedModelValue {
            return selectedModelValue
        }
        if let defaultModel = defaultModelOption?.model, !defaultModel.isEmpty {
            return defaultModel
        }
        if let modeModel = defaultCollaborationMode?.settingsModel, !modeModel.isEmpty {
            return modeModel
        }
        if let modeModel = planCollaborationMode?.settingsModel, !modeModel.isEmpty {
            return modeModel
        }
        return nil
    }

    var selectedCollaborationModeValue: AppServerCollaborationModeSelection? {
        guard let model = collaborationModeModelValue else { return nil }
        if isPlanModeEnabledForCurrentContext {
            guard let planMode = planCollaborationMode else { return nil }
            return AppServerCollaborationModeSelection(
                mode: planMode.mode,
                model: model,
                reasoningEffort: selectedEffortValue
            )
        }
        guard let defaultMode = defaultCollaborationMode else { return nil }
        return AppServerCollaborationModeSelection(
            mode: defaultMode.mode,
            model: model,
            reasoningEffort: selectedEffortValue
        )
    }

    var canTogglePlanMode: Bool {
        planCollaborationMode != nil && collaborationModeModelValue != nil
    }

    var activeModelIDs: [String] {
        activeModelOptions.map(\.model)
    }
}

enum ProjectSectionsBuilder {
    static func build(
        connectedProjects: [ConnectedProject],
        mergedThreads: [MergedAppThread],
        connectionStatusByID: [String: ConnectionStatus]
    ) -> [ProjectSection] {
        var groupedThreads: [String: [MergedAppThread]] = [:]
        var groupOrder: [String] = []

        func ensureGroup(_ key: String) {
            if groupedThreads[key] == nil {
                groupedThreads[key] = []
                groupOrder.append(key)
            }
        }

        for project in connectedProjects {
            ensureGroup(project.id)
        }

        for thread in mergedThreads {
            let groupKey = projectSelectionID(connectionID: thread.connectionID, projectPath: canonicalProjectPath(thread.cwd))
            ensureGroup(groupKey)
            groupedThreads[groupKey, default: []].append(thread)
        }

        var titleCounts: [String: Int] = [:]
        for key in groupOrder {
            guard let parsed = parseProjectSelectionID(key) else { continue }
            let title = projectTitle(for: parsed.projectPath)
            titleCounts["\(parsed.connectionID)::\(title)", default: 0] += 1
        }

        return groupOrder.compactMap { key in
            guard let parsed = parseProjectSelectionID(key),
                  let connectionStatus = connectionStatusByID[parsed.connectionID] else {
                return nil
            }

            let threads = (groupedThreads[key] ?? []).sorted { $0.updatedAt > $1.updatedAt }
            let title = projectTitle(for: parsed.projectPath)
            let titleKey = "\(parsed.connectionID)::\(title)"
            let subtitle: String?
            if parsed.projectPath == unknownProjectPath {
                subtitle = nil
            } else if (titleCounts[titleKey] ?? 0) > 1 {
                subtitle = parsed.projectPath
            } else {
                subtitle = nil
            }

            return ProjectSection(
                id: key,
                connectionID: parsed.connectionID,
                projectPath: parsed.projectPath,
                title: title,
                subtitle: subtitle,
                connectionName: connectionStatus.name,
                connectionColorHex: connectionStatus.colorHex,
                threads: threads,
                latestUpdatedAt: threads.first?.updatedAt ?? .distantPast
            )
        }
    }
}

enum ConnectProjectHelpers {
    static func mergedFolderOptions(remoteFolders: [String], knownFolders: [String]) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []

        for folder in remoteFolders + knownFolders {
            let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                merged.append(trimmed)
            }
        }

        return merged
    }

    static func parentPath(for browsePath: String?) -> String? {
        guard let browsePath = browsePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !browsePath.isEmpty,
              browsePath != "/" else {
            return nil
        }

        let nsPath = (browsePath as NSString).deletingLastPathComponent
        if nsPath.isEmpty {
            return "/"
        }
        if nsPath == browsePath {
            return nil
        }
        return nsPath
    }

    static func resolvedFolderPath(manualPath: String, selectedPath: String?) -> String? {
        let trimmedManualPath = manualPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedManualPath.isEmpty {
            return trimmedManualPath
        }
        return selectedPath?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedHost(_ rawHost: String, fallback: String = ConnectionDraftDefaults.host) -> String {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    static func normalizedPort(_ rawPort: String, fallback: String = ConnectionDraftDefaults.port) -> String {
        let digits = rawPort.trimmingCharacters(in: .whitespacesAndNewlines).filter(\.isNumber)
        return digits.isEmpty ? fallback : digits
    }

    static func canSubmitConnection(name: String, host: String, normalizedPort: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty && !trimmedHost.isEmpty && !normalizedPort.isEmpty
    }
}

func reasoningEffortDisplayName(_ reasoningEffort: String) -> String {
    switch reasoningEffort {
    case "none":
        return "No Reasoning"
    case "minimal":
        return "Minimal"
    case "low":
        return "Low"
    case "medium":
        return "Medium"
    case "high":
        return "High"
    case "xhigh":
        return "Extra High"
    default:
        return reasoningEffort.capitalized
    }
}
