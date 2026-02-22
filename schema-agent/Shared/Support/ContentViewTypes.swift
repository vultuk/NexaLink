//
//  ContentViewTypes.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import Foundation

struct ConnectedProject: Identifiable, Hashable {
    let id: String
    let connectionID: String
    let projectPath: String
}

struct ComposerChoice: Identifiable, Hashable {
    let id: String
    let label: String
    let value: String?
}

struct ProjectSection: Identifiable {
    let id: String
    let connectionID: String
    let projectPath: String
    let title: String
    let subtitle: String?
    let connectionName: String
    let connectionColorHex: String
    let threads: [MergedAppThread]
    let latestUpdatedAt: Date
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case connections

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connections:
            return "Connections"
        }
    }

    var systemImage: String {
        switch self {
        case .connections:
            return "point.3.connected.trianglepath.dotted"
        }
    }
}

enum ConnectProjectWizardStep {
    case connection
    case folder
}
