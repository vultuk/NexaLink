//
//  ProjectIdentity.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import Foundation

let unknownProjectPath = "__unknown_project__"

func canonicalProjectPath(_ rawPath: String) -> String {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return unknownProjectPath }
    if trimmed == unknownProjectPath { return trimmed }
    let standardized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
    if standardized.isEmpty { return unknownProjectPath }
    return standardized
}

func projectSelectionID(connectionID: String, projectPath: String) -> String {
    "\(connectionID)::\(canonicalProjectPath(projectPath))"
}

func parseProjectSelectionID(_ value: String) -> (connectionID: String, projectPath: String)? {
    guard let separator = value.range(of: "::") else { return nil }
    let connectionID = String(value[..<separator.lowerBound])
    let projectPath = String(value[separator.upperBound...])
    guard !connectionID.isEmpty, !projectPath.isEmpty else { return nil }
    return (connectionID, projectPath)
}

func projectTitle(for projectPath: String) -> String {
    guard projectPath != unknownProjectPath else { return "Unknown Project" }
    let normalized = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return "Unknown Project" }
    let url = URL(fileURLWithPath: normalized)
    let basename = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    return basename.isEmpty ? normalized : basename
}
