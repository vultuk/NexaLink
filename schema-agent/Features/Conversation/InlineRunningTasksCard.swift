//
//  InlineRunningTasksCard.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import SwiftUI

struct InlineRunningTasksCard: View {
    let tasks: [MergedRunningTask]
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(tasks) { task in
                    InlineRunningTaskRow(task: task)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(tasks.count == 1 ? "1 running task" : "\(tasks.count) running tasks")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                )
        )
    }
}

private struct InlineRunningTaskRow: View {
    let task: MergedRunningTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(task.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(task.startedAtText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("\(task.connectionName) • \(task.type)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.05))
        )
    }
}
