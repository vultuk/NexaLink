//
//  ConnectionSettingsViews.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import SwiftUI

struct ConnectionSettingsCard: View {
    let connection: ConnectionStatus
    @Binding var isEnabled: Bool
    @Binding var color: Color
    let statusColor: Color
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(connection.name)
                    .font(.headline)
                Spacer()
                Toggle(isOn: $isEnabled) {
                    Text(connection.isEnabled ? "Enabled" : "Disabled")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(Color.secondary.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(Color.secondary.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Text(connection.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("•")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Port \(connection.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text("Color")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ColorPicker("", selection: $color)
                    .labelsHidden()
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(connection.stateLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}

struct CompactConnectionSettingsRow: View {
    let connection: ConnectionStatus
    @Binding var isEnabled: Bool
    let statusColor: Color
    let colorHex: String
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(connection.name)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(Color.secondary.opacity(0.14))
                        )
                }
                .buttonStyle(.plain)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(Color.secondary.opacity(0.14))
                        )
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(connection.stateLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }

            Text("\(connection.host)  •  Port \(connection.port)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(isOn: $isEnabled) {
                Text(connection.isEnabled ? "Enabled" : "Disabled")
                    .font(.subheadline.weight(.medium))
            }
            .toggleStyle(.switch)

            HStack(spacing: 8) {
                Text("Color")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Circle()
                    .fill(colorFromHex(colorHex))
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.vertical, 6)
    }
}
