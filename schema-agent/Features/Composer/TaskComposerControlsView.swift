//
//  TaskComposerControlsView.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import SwiftUI

struct TaskComposerControlsView: View {
    let modelChoices: [ComposerChoice]
    let selectedModelValue: String?
    let selectedModelLabel: String
    let onSelectModel: (String?) -> Void
    let effortChoices: [ComposerChoice]
    let selectedEffortValue: String?
    let selectedEffortLabel: String
    let onSelectEffort: (String?) -> Void
    let areModelChoicesDisabled: Bool
    let isPlanModeEnabled: Bool
    let canTogglePlanMode: Bool
    let onTogglePlanMode: () -> Void
    let isSubmitting: Bool
    let canStartTask: Bool
    let onStartTask: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(modelChoices) { choice in
                    Button {
                        onSelectModel(choice.value)
                    } label: {
                        if selectedModelValue == choice.value {
                            Label(choice.label, systemImage: "checkmark")
                        } else {
                            Text(choice.label)
                        }
                    }
                }
            } label: {
                composerChoiceLabel(selectedModelLabel)
            }
            .disabled(areModelChoicesDisabled)

            Menu {
                ForEach(effortChoices) { choice in
                    Button {
                        onSelectEffort(choice.value)
                    } label: {
                        if selectedEffortValue == choice.value {
                            Label(choice.label, systemImage: "checkmark")
                        } else {
                            Text(choice.label)
                        }
                    }
                }
            } label: {
                composerChoiceLabel(selectedEffortLabel)
            }
            .disabled(areModelChoicesDisabled)

            Button(action: onTogglePlanMode) {
                Image(systemName: isPlanModeEnabled ? "list.bullet.clipboard.fill" : "list.bullet.clipboard")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(isPlanModeEnabled ? Color.accentColor : Color.secondary)
                    .background(
                        Circle()
                            .fill(Color.secondary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canTogglePlanMode)
            .help("Toggle plan mode")

            Spacer()

            if isSubmitting {
                ProgressView()
                    .controlSize(.small)
            }

            Button(action: onStartTask) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(canStartTask ? Color.white : Color.secondary)
                    .background(
                        Circle()
                            .fill(canStartTask ? Color.black : Color.secondary.opacity(0.18))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canStartTask)
        }
    }

    private func composerChoiceLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.subheadline)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.secondary.opacity(0.08))
        )
    }
}
