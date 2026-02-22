//
//  ConversationActivityRow.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import SwiftUI

struct ConversationActivityRow: View {
    let entry: ActivityEntry

    private enum Layout {
        static let messageCornerRadius: CGFloat = 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entry.kind != .assistant {
                Text(label(for: entry.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !entry.text.isEmpty {
                ConversationMarkdownContentView(source: entry.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !entry.imageURLs.isEmpty || !entry.localImagePaths.isEmpty {
                ConversationAttachmentStripView(
                    imageURLs: entry.imageURLs,
                    localImagePaths: entry.localImagePaths
                )
            }
        }
        .padding(rowPadding(for: entry.kind))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(for: entry.kind), in: RoundedRectangle(cornerRadius: Layout.messageCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.messageCornerRadius)
                .stroke(rowStroke(for: entry.kind), lineWidth: rowStroke(for: entry.kind) == .clear ? 0 : 1)
        )
    }

    private func label(for kind: ActivityEntry.Kind) -> String {
        switch kind {
        case .system:
            return "System"
        case .user:
            return "You"
        case .assistant:
            return "Assistant"
        }
    }

    private func rowBackground(for kind: ActivityEntry.Kind) -> Color {
        switch kind {
        case .system:
            return Color.clear
        case .user:
            return Color.secondary.opacity(0.07)
        case .assistant:
            return Color.clear
        }
    }

    private func rowStroke(for kind: ActivityEntry.Kind) -> Color {
        switch kind {
        case .system:
            return Color.clear
        case .user:
            return Color.secondary.opacity(0.16)
        case .assistant:
            return Color.clear
        }
    }

    private func rowPadding(for kind: ActivityEntry.Kind) -> CGFloat {
        switch kind {
        case .assistant, .system:
            return 0
        case .user:
            return 14
        }
    }
}
