//
//  ConversationMarkdownRenderer.swift
//  NexaLink
//
//  Created by Codex on 22/02/2026.
//

import SwiftUI
import Foundation

enum ConversationMarkdownRenderer {
    struct RenderBlock: Identifiable {
        enum Kind {
            case paragraph(String)
            case heading(level: Int, text: String)
            case unordered(String)
            case ordered(number: String, text: String)
            case quote(String)
            case divider
            case code(language: String?, code: String)
        }

        let id: Int
        let kind: Kind
    }

    private final class MarkdownBlockCacheEntry: NSObject {
        let blocks: [RenderBlock]

        init(blocks: [RenderBlock]) {
            self.blocks = blocks
        }
    }

    private final class MarkdownInlineCacheEntry: NSObject {
        let attributed: AttributedString

        init(attributed: AttributedString) {
            self.attributed = attributed
        }
    }

    private static let markdownBlockCache: NSCache<NSString, MarkdownBlockCacheEntry> = {
        let cache = NSCache<NSString, MarkdownBlockCacheEntry>()
        cache.countLimit = 400
        return cache
    }()

    private static let markdownInlineCache: NSCache<NSString, MarkdownInlineCacheEntry> = {
        let cache = NSCache<NSString, MarkdownInlineCacheEntry>()
        cache.countLimit = 1000
        return cache
    }()

    static func blocks(from source: String) -> [RenderBlock] {
        let key = source as NSString
        if let cached = markdownBlockCache.object(forKey: key) {
            return cached.blocks
        }

        let parsedBlocks = markdownBlocks(from: source)
        markdownBlockCache.setObject(MarkdownBlockCacheEntry(blocks: parsedBlocks), forKey: key)
        return parsedBlocks
    }

    static func inlineAttributedString(from source: String) -> AttributedString? {
        if source.count > 2000 {
            return nil
        }

        let markdownSignals = ["*", "_", "`", "[", "]", "~", "#", ">"]
        if !markdownSignals.contains(where: { source.contains($0) }) {
            return nil
        }

        let key = source as NSString
        if let cached = markdownInlineCache.object(forKey: key) {
            return cached.attributed
        }

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let parsed = try? AttributedString(markdown: source, options: options) {
            markdownInlineCache.setObject(MarkdownInlineCacheEntry(attributed: parsed), forKey: key)
            return parsed
        }
        return nil
    }

    private static func markdownBlocks(from source: String) -> [RenderBlock] {
        var blocks: [RenderBlock] = []
        var nextBlockID = 0
        var proseLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCodeFence = false

        func appendBlock(_ kind: RenderBlock.Kind) {
            let id = nextBlockID
            nextBlockID += 1
            blocks.append(RenderBlock(id: id, kind: kind))
        }

        func flushProse() {
            let prose = proseLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            proseLines.removeAll()
            guard !prose.isEmpty else { return }
            appendBlock(.paragraph(prose))
        }

        func flushCode() {
            let code = codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            codeLines.removeAll()
            guard !code.isEmpty else {
                codeLanguage = nil
                return
            }
            appendBlock(.code(language: codeLanguage, code: code))
            codeLanguage = nil
        }

        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        for lineSlice in lines {
            let line = String(lineSlice)
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if trimmedLine.hasPrefix("```") {
                let languageHint = String(trimmedLine.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                if inCodeFence {
                    flushCode()
                    inCodeFence = false
                } else {
                    flushProse()
                    inCodeFence = true
                    codeLanguage = languageHint.isEmpty ? nil : languageHint
                }
                continue
            }

            if inCodeFence {
                codeLines.append(line)
                continue
            }

            let fullyTrimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if fullyTrimmed.isEmpty {
                flushProse()
                continue
            }

            if isMarkdownDivider(fullyTrimmed) {
                flushProse()
                appendBlock(.divider)
                continue
            }

            if let heading = parseHeading(from: line) {
                flushProse()
                appendBlock(.heading(level: heading.level, text: heading.text))
                continue
            }

            if let ordered = parseOrderedItem(from: line) {
                flushProse()
                appendBlock(.ordered(number: ordered.number, text: ordered.text))
                continue
            }

            if let unordered = parseUnorderedItem(from: line) {
                flushProse()
                appendBlock(.unordered(unordered))
                continue
            }

            if let quote = parseQuote(from: line) {
                flushProse()
                appendBlock(.quote(quote))
                continue
            }

            proseLines.append(line)
        }

        if inCodeFence {
            flushCode()
        }
        flushProse()

        if blocks.isEmpty {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                appendBlock(.paragraph(trimmed))
            }
        }

        return blocks
    }

    private static func parseHeading(from line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var level = 0
        for character in trimmed {
            if character == "#" {
                level += 1
            } else {
                break
            }
        }
        guard level > 0, level <= 6 else { return nil }
        let startIndex = trimmed.index(trimmed.startIndex, offsetBy: level)
        let body = String(trimmed[startIndex...]).trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        return (level, body)
    }

    private static func parseUnorderedItem(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return nil }
        let first = trimmed[trimmed.startIndex]
        guard first == "-" || first == "*" || first == "+" else { return nil }
        let secondIndex = trimmed.index(after: trimmed.startIndex)
        guard trimmed[secondIndex] == " " else { return nil }
        let textStart = trimmed.index(after: secondIndex)
        let text = String(trimmed[textStart...]).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func parseOrderedItem(from line: String) -> (number: String, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let dotIndex = trimmed.firstIndex(of: ".") else { return nil }
        let numberPart = String(trimmed[..<dotIndex])
        guard !numberPart.isEmpty, numberPart.allSatisfy(\.isNumber) else { return nil }
        let afterDot = trimmed.index(after: dotIndex)
        guard afterDot < trimmed.endIndex, trimmed[afterDot] == " " else { return nil }
        let textStart = trimmed.index(after: afterDot)
        let text = String(trimmed[textStart...]).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (numberPart, text)
    }

    private static func parseQuote(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { return nil }
        let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }

    private static func isMarkdownDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        let first = compact.first ?? "-"
        guard first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }
}
