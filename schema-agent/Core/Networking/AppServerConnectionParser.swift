//
//  AppServerConnectionParser.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import Foundation

enum AppServerConnectionParser {
    static func parseModelOption(_ raw: [String: Any]) -> AppServerModelOption? {
        guard
            let id = raw["id"] as? String,
            let model = raw["model"] as? String
        else { return nil }

        let rawDisplayName = (raw["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = rawDisplayName.isEmpty ? model : rawDisplayName
        let isDefault = raw["isDefault"] as? Bool ?? false
        let defaultReasoningEffort = (raw["defaultReasoningEffort"] as? String) ?? ""
        let supportedRaw = raw["supportedReasoningEfforts"] as? [[String: Any]] ?? []
        var supported = supportedRaw.compactMap { option -> AppServerReasoningEffortOption? in
            guard let reasoningEffort = option["reasoningEffort"] as? String else { return nil }
            let description = (option["description"] as? String) ?? ""
            return AppServerReasoningEffortOption(
                id: "\(model)-\(reasoningEffort)",
                reasoningEffort: reasoningEffort,
                description: description
            )
        }

        if !defaultReasoningEffort.isEmpty && !supported.contains(where: { $0.reasoningEffort == defaultReasoningEffort }) {
            supported.insert(
                AppServerReasoningEffortOption(
                    id: "\(model)-\(defaultReasoningEffort)",
                    reasoningEffort: defaultReasoningEffort,
                    description: ""
                ),
                at: 0
            )
        }

        return AppServerModelOption(
            id: id,
            model: model,
            displayName: displayName,
            isDefault: isDefault,
            defaultReasoningEffort: defaultReasoningEffort,
            supportedReasoningEfforts: supported
        )
    }

    static func deduplicatedModels(_ models: [AppServerModelOption]) -> [AppServerModelOption] {
        var seenModelIDs = Set<String>()
        var deduplicated: [AppServerModelOption] = []

        for model in models {
            if seenModelIDs.insert(model.model).inserted {
                deduplicated.append(model)
            }
        }

        deduplicated.sort { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault && !rhs.isDefault
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return deduplicated
    }

    static func parseCollaborationModeOptions(_ rawResult: Any) -> [AppServerCollaborationModeOption] {
        var rawModeItems: [Any] = []
        var defaultModeID: String?

        func collect(from dictionary: [String: Any]) {
            if defaultModeID == nil {
                defaultModeID = stringValue(
                    in: dictionary,
                    keys: ["defaultMode", "default_mode", "default", "defaultId", "default_id"]
                )
            }

            for key in ["data", "modes", "items", "collaborationModes", "collaboration_modes"] {
                if let array = dictionary[key] as? [Any] {
                    rawModeItems.append(contentsOf: array)
                }
            }

            for key in ["result", "data", "modes", "items"] {
                if let nested = dictionary[key] as? [String: Any] {
                    collect(from: nested)
                }
            }
        }

        if let dictionary = rawResult as? [String: Any] {
            collect(from: dictionary)
        } else if let array = rawResult as? [Any] {
            rawModeItems = array
        } else if let modeString = rawResult as? String {
            rawModeItems = [modeString]
        }

        var seenModeIDs = Set<String>()
        var parsed: [AppServerCollaborationModeOption] = []

        func modeDisplayName(for modeID: String) -> String {
            switch modeID.lowercased() {
            case "plan":
                return "Plan"
            case "default":
                return "Default"
            default:
                return modeID.capitalized
            }
        }

        for item in rawModeItems {
            let modeID: String
            let displayName: String
            let isDefault: Bool
            let settingsModel: String?

            if let modeString = item as? String {
                modeID = modeString
                displayName = modeDisplayName(for: modeString)
                isDefault = modeString == defaultModeID
                settingsModel = nil
            } else if let modeDictionary = item as? [String: Any] {
                if let modeValue = modeDictionary["mode"] as? String {
                    modeID = modeValue
                } else if let modeValue = stringValue(
                    in: modeDictionary,
                    keys: ["id", "kind", "modeKind", "mode_kind", "name"]
                ) {
                    modeID = modeValue
                } else {
                    continue
                }

                let label = stringValue(
                    in: modeDictionary,
                    keys: ["displayName", "display_name", "title", "label"]
                ) ?? modeDisplayName(for: modeID)
                displayName = label.trimmingCharacters(in: .whitespacesAndNewlines)
                isDefault = boolValue(in: modeDictionary, keys: ["isDefault", "default", "is_default"]) ?? (modeID == defaultModeID)
                if let settings = modeDictionary["settings"] as? [String: Any] {
                    settingsModel = stringValue(in: settings, keys: ["model"])
                } else {
                    settingsModel = nil
                }
            } else {
                continue
            }

            let normalizedID = modeID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedID.isEmpty else { continue }
            if !seenModeIDs.insert(normalizedID).inserted {
                continue
            }

            parsed.append(
                AppServerCollaborationModeOption(
                    id: normalizedID,
                    mode: normalizedID,
                    displayName: displayName.isEmpty ? modeDisplayName(for: normalizedID) : displayName,
                    isDefault: isDefault,
                    settingsModel: settingsModel
                )
            )
        }

        parsed.sort { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault && !rhs.isDefault
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        return parsed
    }

    static func parseThread(_ raw: [String: Any]) -> AppThread? {
        guard let threadID = stringValue(in: raw, keys: ["id", "threadId", "thread_id"]) else { return nil }
        let cwd = stringValue(in: raw, keys: ["cwd", "workingDirectory", "working_directory"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preview = stringValue(in: raw, keys: ["preview", "title", "name"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = preview.isEmpty ? "Thread \(threadID.prefix(8))" : preview
        let updatedAt = dateFromUnixSeconds(raw["updatedAt"] ?? raw["updated_at"]) ?? Date()
        return AppThread(
            id: threadID,
            cwd: cwd,
            title: title,
            subtitle: String(threadID.prefix(8)),
            updatedAt: updatedAt
        )
    }

    static func normalizedThreadIDs(from rawIDs: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for rawID in rawIDs {
            let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                normalized.append(trimmed)
            }
        }
        return normalized
    }

    static func extractThreadListPayload(from resultAny: Any?) -> (threads: [[String: Any]], threadIDs: [String], nextCursor: String?) {
        var threadObjects: [[String: Any]] = []
        var threadIDs: [String] = []
        var nextCursor: String?

        func collectFromArray(_ array: [Any]) {
            for element in array {
                if let threadID = element as? String {
                    threadIDs.append(threadID)
                    continue
                }
                guard let dictionary = element as? [String: Any] else { continue }
                if let nestedThread = dictionary["thread"] as? [String: Any] {
                    threadObjects.append(nestedThread)
                } else {
                    threadObjects.append(dictionary)
                }
            }
        }

        func collectFromContainer(_ container: [String: Any]) {
            if nextCursor == nil {
                nextCursor = stringValue(in: container, keys: ["nextCursor", "next_cursor"])
            }

            for key in ["data", "threads", "items", "sessions"] {
                if let array = container[key] as? [Any] {
                    collectFromArray(array)
                }
            }

            for key in ["data", "result", "threads", "items", "sessions"] {
                if let nested = container[key] as? [String: Any] {
                    if nextCursor == nil {
                        nextCursor = stringValue(in: nested, keys: ["nextCursor", "next_cursor"])
                    }
                    for nestedKey in ["data", "threads", "items", "sessions"] {
                        if let nestedArray = nested[nestedKey] as? [Any] {
                            collectFromArray(nestedArray)
                        }
                    }
                }
            }
        }

        if let container = resultAny as? [String: Any] {
            collectFromContainer(container)
        } else if let array = resultAny as? [Any] {
            collectFromArray(array)
        }

        return (threadObjects, normalizedThreadIDs(from: threadIDs), nextCursor)
    }

    static func deduplicatedThreads(_ threads: [AppThread]) -> [AppThread] {
        var mergedByID: [String: AppThread] = [:]
        for thread in threads {
            if let existing = mergedByID[thread.id] {
                let existingIsPlaceholder = existing.updatedAt == .distantPast
                let incomingIsPlaceholder = thread.updatedAt == .distantPast

                if existingIsPlaceholder && !incomingIsPlaceholder {
                    mergedByID[thread.id] = thread
                } else if existing.updatedAt < thread.updatedAt {
                    mergedByID[thread.id] = thread
                } else if existing.cwd.isEmpty && !thread.cwd.isEmpty {
                    mergedByID[thread.id] = thread
                }
            } else {
                mergedByID[thread.id] = thread
            }
        }
        return Array(mergedByID.values)
    }

    static func dateFromUnixSeconds(_ raw: Any?) -> Date? {
        if let intValue = raw as? Int {
            return Date(timeIntervalSince1970: TimeInterval(intValue))
        }
        if let doubleValue = raw as? Double {
            return Date(timeIntervalSince1970: doubleValue)
        }
        if let numberValue = raw as? NSNumber {
            return Date(timeIntervalSince1970: numberValue.doubleValue)
        }
        return nil
    }

    static func parseUserMessage(_ content: [[String: Any]]) -> (text: String, imageURLs: [String], localImagePaths: [String]) {
        var lines: [String] = []
        var imageURLs: [String] = []
        var localImagePaths: [String] = []

        for input in content {
            guard let type = input["type"] as? String else { continue }
            switch type {
            case "text":
                if let text = input["text"] as? String {
                    let sanitized = sanitizeDisplayText(text).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sanitized.isEmpty {
                        lines.append(sanitized)
                    }
                }
            case "image":
                let imageURL = (input["url"] as? String) ?? (input["image_url"] as? String)
                if let imageURL, !imageURL.isEmpty {
                    imageURLs.append(imageURL)
                } else if let payload = input["data"] as? String, !payload.isEmpty {
                    imageURLs.append(payload)
                } else {
                    lines.append("[Image attachment]")
                }
            case "localImage":
                if let path = input["path"] as? String, !path.isEmpty {
                    localImagePaths.append(path)
                } else if let path = input["local_image"] as? String, !path.isEmpty {
                    localImagePaths.append(path)
                } else {
                    lines.append("[Local image attachment]")
                }
            case "skill":
                if let name = input["name"] as? String {
                    lines.append("[Skill] \(name)")
                } else {
                    lines.append("[Skill]")
                }
            case "mention":
                if let name = input["name"] as? String {
                    lines.append("[Mention] \(name)")
                } else {
                    lines.append("[Mention]")
                }
            default:
                continue
            }
        }

        return (lines.joined(separator: "\n"), imageURLs, localImagePaths)
    }

    static func sanitizeDisplayText(_ rawText: String) -> String {
        guard !rawText.isEmpty else { return "" }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawText }
        if looksLikeImageDataURI(trimmed) {
            return "[Image attachment]"
        }
        if looksLikeBase64Blob(trimmed) {
            return "[Image attachment]"
        }
        return replacingEmbeddedBase64(in: rawText)
    }

    static func parseRequestID(_ value: Any?) -> Int? {
        if let id = value as? Int {
            return id
        }
        if let idNumber = value as? NSNumber {
            return idNumber.intValue
        }
        if let idString = value as? String {
            return Int(idString)
        }
        return nil
    }

    private static func looksLikeImageDataURI(_ text: String) -> Bool {
        text.hasPrefix("data:image/")
    }

    private static func looksLikeBase64Blob(_ text: String) -> Bool {
        guard text.count >= 220 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=\n\r")
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let compact = text.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        guard compact.count >= 220 else { return false }
        return compact.count % 4 == 0
    }

    private static func replacingEmbeddedBase64(in text: String) -> String {
        let pattern = "([A-Za-z0-9+/]{180,}={0,2})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if regex.firstMatch(in: text, options: [], range: nsRange) == nil {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: nsRange,
            withTemplate: "[Image attachment]"
        )
    }

    private static func stringValue(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                return value
            }
        }
        return nil
    }

    private static func boolValue(in dictionary: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = dictionary[key] as? Bool {
                return value
            }
            if let value = dictionary[key] as? NSNumber {
                return value.boolValue
            }
            if let value = dictionary[key] as? String {
                switch value.lowercased() {
                case "true", "1", "yes":
                    return true
                case "false", "0", "no":
                    return false
                default:
                    continue
                }
            }
        }
        return nil
    }
}
