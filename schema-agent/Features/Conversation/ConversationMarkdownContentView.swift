//
//  ConversationMarkdownContentView.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import SwiftUI

struct ConversationMarkdownContentView: View {
    let source: String

    var body: some View {
        let blocks = ConversationMarkdownRenderer.blocks(from: source)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block.kind {
                case .paragraph(let prose):
                    markdownInlineText(prose)
                        .font(.body)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .heading(let level, let text):
                    markdownInlineText(text)
                        .font(headingFont(level))
                        .fontWeight(.semibold)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .unordered(let item):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        markdownInlineText(item)
                            .font(.body)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .ordered(let number, let item):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(number).")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        markdownInlineText(item)
                            .font(.body)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .quote(let quoted):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 3)
                        markdownInlineText(quoted)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .divider:
                    Divider()
                case .code(let language, let code):
                    markdownCodeBlock(language: language, code: code)
                }
            }
        }
    }

    private func markdownInlineText(_ value: String) -> Text {
        if let attributed = ConversationMarkdownRenderer.inlineAttributedString(from: value) {
            return Text(attributed)
        }
        return Text(value)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:
            return .title2
        case 2:
            return .title3
        case 3:
            return .headline
        default:
            return .subheadline
        }
    }

    private func markdownCodeBlock(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
                    )
            )
        }
    }
}
