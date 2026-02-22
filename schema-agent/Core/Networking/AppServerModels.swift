//
//  ContentView.swift
//  NexaLink
//
//  Created by Simon Skinner on 21/02/2026.
//

import SwiftUI
import Foundation
import Combine
import Network
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
typealias PlatformImage = UIImage
#elseif os(macOS)
typealias PlatformImage = NSImage
#endif

struct RunningTask: Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let threadID: String
    let turnID: String
    let startedAt: Date

    var startedAtText: String {
        RunningTask.relativeFormatter.localizedString(for: startedAt, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

struct AppThread: Identifiable, Hashable {
    let id: String
    var cwd: String
    var title: String
    var subtitle: String
    var updatedAt: Date

    var updatedAtText: String {
        AppThread.relativeFormatter.localizedString(for: updatedAt, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

struct ActivityEntry: Identifiable {
    enum Kind {
        case system
        case user
        case assistant
    }

    let id = UUID()
    let threadID: String?
    let createdAt: Date
    let kind: Kind
    var text: String
    var imageURLs: [String] = []
    var localImagePaths: [String] = []
}

struct AppServerReasoningEffortOption: Identifiable, Hashable {
    let id: String
    let reasoningEffort: String
    let description: String
}

struct AppServerModelOption: Identifiable, Hashable {
    let id: String
    let model: String
    let displayName: String
    let isDefault: Bool
    let defaultReasoningEffort: String
    let supportedReasoningEfforts: [AppServerReasoningEffortOption]
}

struct AppServerCollaborationModeOption: Identifiable, Hashable {
    let id: String
    let mode: String
    let displayName: String
    let isDefault: Bool
    let settingsModel: String?
}

struct AppServerCollaborationModeSelection {
    let mode: String
    let model: String
    let reasoningEffort: String?
}

enum AppServerConnectionState: Hashable {
    case disconnected
    case connecting
    case connected
    case failed
}
