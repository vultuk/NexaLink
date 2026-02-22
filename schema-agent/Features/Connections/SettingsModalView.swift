//
//  SettingsModalView.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import SwiftUI

struct SettingsModalView<CompactContent: View, ConnectionsContent: View>: View {
    let usesCompactLayout: Bool
    @Binding var selectedSection: SettingsSection?
    let onClose: () -> Void
    let onAdd: () -> Void
    @ViewBuilder let compactContent: () -> CompactContent
    @ViewBuilder let connectionsContent: () -> ConnectionsContent

    var body: some View {
        Group {
            if usesCompactLayout {
                NavigationStack {
                    compactContent()
                        .navigationTitle("Connections")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close", action: onClose)
                            }
                            ToolbarItem(placement: .primaryAction) {
                                Button(action: onAdd) {
                                    Image(systemName: "plus")
                                }
                            }
                        }
                }
            } else {
                NavigationStack {
                    HStack(spacing: 0) {
                        settingsSidebar
                            .frame(width: 220)

                        Divider()

                        Group {
                            switch selectedSection ?? .connections {
                            case .connections:
                                connectionsContent()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .navigationTitle("Settings")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", action: onClose)
                        }
                    }
                }
                .frame(minWidth: 780, minHeight: 500)
            }
        }
    }

    private var settingsSidebar: some View {
        List(SettingsSection.allCases, selection: $selectedSection) { section in
            Label(section.title, systemImage: section.systemImage)
                .tag(section)
        }
        .listStyle(.sidebar)
    }
}
