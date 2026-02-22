//
//  ConnectionEditorSheetView.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import SwiftUI

struct ConnectionEditorSheetView: View {
    let title: String
    let subtitle: String
    let actionTitle: String
    let usesCompactLayout: Bool
    let canSubmit: Bool
    @Binding var name: String
    @Binding var host: String
    @Binding var port: String
    @Binding var color: Color
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(Color.secondary.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                ConnectionEditorField(
                    title: "Name",
                    placeholder: "Remote",
                    text: $name
                )
                ConnectionEditorField(
                    title: "IP Address",
                    placeholder: "127.0.0.1",
                    text: $host
                )
                ConnectionEditorField(
                    title: "Port",
                    placeholder: "9281",
                    text: $port,
                    numericOnly: true
                )

                HStack(spacing: 10) {
                    Text("Color")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ColorPicker("", selection: $color)
                        .labelsHidden()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            if !usesCompactLayout {
                Spacer(minLength: 0)
            }

            Divider()

            HStack(spacing: 10) {
                Spacer()

                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)

                Button(actionTitle, action: onSubmit)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(
            minWidth: usesCompactLayout ? nil : 500,
            idealWidth: nil,
            maxWidth: .infinity,
            minHeight: usesCompactLayout ? nil : 360,
            idealHeight: nil,
            maxHeight: usesCompactLayout ? .infinity : nil,
            alignment: .topLeading
        )
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }
}

private struct ConnectionEditorField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var numericOnly: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.secondary.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                )
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(numericOnly ? .numberPad : .default)
                #endif
                .onChange(of: text) { _, newValue in
                    guard numericOnly else { return }
                    let digits = newValue.filter(\.isNumber)
                    if digits != newValue {
                        text = digits
                    }
                }
        }
    }
}
