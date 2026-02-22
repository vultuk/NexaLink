//
//  ConversationPaneView.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import SwiftUI

struct ConversationPaneView: View {
    let selectedThreadID: String?
    let selectedProjectContext: ConnectedProject?
    let selectedProjectConnectionName: String?
    let visibleActivity: [ActivityEntry]
    let inlineRunningTasks: [MergedRunningTask]
    let visibleActivityScrollToken: Int
    let conversationBottomAnchorID: String
    @Binding var isRunningTasksExpanded: Bool
    @Binding var shouldScrollConversationToBottomOnNextUpdate: Bool
    @Binding var isConversationBottomVisible: Bool
    let onDismissComposerFocus: () -> Void

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if !inlineRunningTasks.isEmpty {
                            InlineRunningTasksCard(tasks: inlineRunningTasks, isExpanded: $isRunningTasksExpanded)
                        }

                        if visibleActivity.isEmpty && inlineRunningTasks.isEmpty {
                            if selectedThreadID == nil, let selectedProjectContext {
                                newThreadLanding(context: selectedProjectContext)
                                    .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
                                    .padding(.top, 28)
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("No activity yet")
                                        .font(.title3.weight(.semibold))
                                    Text("Start a task below to stream updates in this thread.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 28)
                            }
                        } else {
                            ForEach(visibleActivity) { entry in
                                ConversationActivityRow(entry: entry)
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(conversationBottomAnchorID)
                            .onAppear {
                                isConversationBottomVisible = true
                            }
                            .onDisappear {
                                isConversationBottomVisible = false
                            }
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .frame(maxWidth: .infinity)
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                TapGesture().onEnded {
                    onDismissComposerFocus()
                }
            )
            #endif
            .onAppear {
                shouldScrollConversationToBottomOnNextUpdate = true
                scrollConversationToBottom(using: scrollProxy)
            }
            .onChange(of: visibleActivityScrollToken) { _, _ in
                guard !visibleActivity.isEmpty || !inlineRunningTasks.isEmpty else { return }
                if shouldScrollConversationToBottomOnNextUpdate {
                    scrollConversationToBottom(using: scrollProxy)
                    shouldScrollConversationToBottomOnNextUpdate = false
                    return
                }
                if isConversationBottomVisible {
                    scrollConversationToBottom(using: scrollProxy)
                }
            }
        }
    }

    private func newThreadLanding(context: ConnectedProject) -> some View {
        let title = projectTitle(for: context.projectPath)
        let connectionName = selectedProjectConnectionName ?? context.connectionID
        let projectSubtitle: String = {
            if context.projectPath == unknownProjectPath {
                return connectionName
            }
            return "\(connectionName) • \(context.projectPath)"
        }()

        return VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Let's build")
                .font(.title2.weight(.semibold))
            Text(title)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text(projectSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private func scrollConversationToBottom(using scrollProxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                scrollProxy.scrollTo(conversationBottomAnchorID, anchor: .bottom)
            }
        }
    }
}
