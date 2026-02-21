//
//  ContentView.swift
//  schema-agent
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

enum AppServerConnectionState: Hashable {
    case disconnected
    case connecting
    case connected
    case failed
}

private enum SocketPhase {
    case idle
    case connecting
    case handshaking
    case open
    case closed
}

final class AppServerConnection: ObservableObject {
    @Published var serverURLString = "ws://127.0.0.1:9281"
    @Published private(set) var state: AppServerConnectionState = .disconnected
    @Published private(set) var statusMessage = "Not connected"
    @Published private(set) var runningTasks: [RunningTask] = []
    @Published private(set) var threads: [AppThread] = []
    @Published private(set) var activity: [ActivityEntry] = []
    @Published private(set) var isSubmittingTask = false
    @Published private(set) var taskStartSuccessCount = 0
    @Published private(set) var availableModels: [AppServerModelOption] = []

    private var connection: NWConnection?
    private let connectionQueue = DispatchQueue(label: "AppServerConnection.Socket")
    private var pendingRequests: [Int: String] = [:]
    private var nextRequestID = 0
    private var queuedMessages: [String] = []
    private var candidateURLs: [URL] = []
    private var currentCandidateIndex = 0
    private var didReceiveInitializeResponse = false
    private var receiveBuffer = Data()
    private var activeHandshakeKey: String?
    private var isUserInitiatedDisconnect = false
    private var phase: SocketPhase = .idle
    private var connectedURL: URL?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var threadStartPromptsByRequestID: [Int: PendingThreadStartContext] = [:]
    private var threadResumePromptsByRequestID: [Int: PendingThreadResumeContext] = [:]
    private var passiveThreadResumeRequestIDs: Set<Int> = []
    private var turnStartContextsByRequestID: [Int: PendingTurnStartContext] = [:]
    private var threadReadThreadIDByRequestID: [Int: String] = [:]
    private var threadCreateCompletionsByRequestID: [Int: (_ threadID: String?, _ errorMessage: String?) -> Void] = [:]
    private var commandExecCompletionsByRequestID: [Int: (_ result: [String: Any]?, _ errorMessage: String?) -> Void] = [:]
    private var currentThreadID: String?
    private var assistantEntryIDByItemID: [String: UUID] = [:]
    private var modelListAccumulator: [AppServerModelOption] = []
    private var threadIDByTurnID: [String: String] = [:]
    private var threadIDByItemID: [String: String] = [:]
    private var turnIDByItemID: [String: String] = [:]

    private struct PendingThreadStartContext {
        let prompt: String
        let model: String?
        let effort: String?
    }

    private struct PendingThreadResumeContext {
        let prompt: String
        let requestedThreadID: String
        let model: String?
        let effort: String?
    }

    private struct PendingTurnStartContext {
        let prompt: String
        let threadID: String
    }

    func connect() {
        guard let url = normalizedWebSocketURL(from: serverURLString) else {
            state = .failed
            statusMessage = "Invalid server URL."
            return
        }

        state = .connecting
        statusMessage = "Connecting (raw WS) to \(url.host ?? url.absoluteString)..."
        runningTasks = []
        activity = []
        threads = []
        availableModels = []

        connectionQueue.sync {
            self.isUserInitiatedDisconnect = false
            self.teardownConnectionLocked()
            self.pendingRequests.removeAll()
            self.queuedMessages.removeAll()
            self.didReceiveInitializeResponse = false
            self.receiveBuffer.removeAll()
            self.threadStartPromptsByRequestID.removeAll()
            self.threadResumePromptsByRequestID.removeAll()
            self.passiveThreadResumeRequestIDs.removeAll()
            self.turnStartContextsByRequestID.removeAll()
            self.threadReadThreadIDByRequestID.removeAll()
            self.threadCreateCompletionsByRequestID.removeAll()
            self.commandExecCompletionsByRequestID.removeAll()
            self.assistantEntryIDByItemID.removeAll()
            self.modelListAccumulator.removeAll()
            self.threadIDByTurnID.removeAll()
            self.threadIDByItemID.removeAll()
            self.turnIDByItemID.removeAll()
            self.currentThreadID = nil
            self.prepareCandidateURLs(from: url)
            self.currentCandidateIndex = 0
            self.connectToCurrentCandidate()
        }

        isSubmittingTask = false
        taskStartSuccessCount = 0
    }

    func disconnect() {
        connectionQueue.sync {
            self.isUserInitiatedDisconnect = true
            self.pendingRequests.removeAll()
            self.queuedMessages.removeAll()
            self.didReceiveInitializeResponse = false
            self.threadStartPromptsByRequestID.removeAll()
            self.threadResumePromptsByRequestID.removeAll()
            self.passiveThreadResumeRequestIDs.removeAll()
            self.turnStartContextsByRequestID.removeAll()
            self.threadReadThreadIDByRequestID.removeAll()
            self.threadCreateCompletionsByRequestID.removeAll()
            self.commandExecCompletionsByRequestID.removeAll()
            self.assistantEntryIDByItemID.removeAll()
            self.modelListAccumulator.removeAll()
            self.threadIDByTurnID.removeAll()
            self.threadIDByItemID.removeAll()
            self.turnIDByItemID.removeAll()
            self.currentThreadID = nil
            self.teardownConnectionLocked()
        }

        runningTasks = []
        availableModels = []
        isSubmittingTask = false
        if state != .failed {
            state = .disconnected
            statusMessage = "Not connected"
        }
    }

    @discardableResult
    func startTask(
        prompt: String,
        threadID: String?,
        model: String?,
        effort: String?,
        cwd: String? = nil
    ) -> Bool {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            statusMessage = "Enter a task prompt."
            return false
        }

        guard state == .connected else {
            statusMessage = "Connect to the app server before starting a task."
            return false
        }

        isSubmittingTask = true
        connectionQueue.async {
            if let threadID {
                let requestID = self.sendRequestLocked(
                    method: "thread/resume",
                    params: ["threadId": threadID]
                )
                self.threadResumePromptsByRequestID[requestID] = PendingThreadResumeContext(
                    prompt: trimmedPrompt,
                    requestedThreadID: threadID,
                    model: model,
                    effort: effort
                )
                DispatchQueue.main.async {
                    self.statusMessage = "Resuming thread..."
                }
            } else {
                var params: [String: Any] = [:]
                let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let trimmedCwd, !trimmedCwd.isEmpty {
                    params["cwd"] = trimmedCwd
                }
                let requestID = self.sendRequestLocked(method: "thread/start", params: params)
                self.threadStartPromptsByRequestID[requestID] = PendingThreadStartContext(
                    prompt: trimmedPrompt,
                    model: model,
                    effort: effort
                )
                DispatchQueue.main.async {
                    self.statusMessage = "Creating thread..."
                }
            }
        }
        return true
    }

    func loadThreadHistory(threadID: String) {
        guard state == .connected else { return }
        let trimmed = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        connectionQueue.async {
            self.currentThreadID = trimmed
            let resumeRequestID = self.sendRequestLocked(
                method: "thread/resume",
                params: ["threadId": trimmed]
            )
            self.passiveThreadResumeRequestIDs.insert(resumeRequestID)
            let requestID = self.sendRequestLocked(
                method: "thread/read",
                params: [
                    "threadId": trimmed,
                    "includeTurns": true
                ]
            )
            self.threadReadThreadIDByRequestID[requestID] = trimmed
        }
    }

    func createThread(cwd: String?, completion: @escaping (_ threadID: String?, _ errorMessage: String?) -> Void) {
        guard state == .connected else {
            completion(nil, "Connection is not ready.")
            return
        }

        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        connectionQueue.async {
            var params: [String: Any] = [:]
            if let trimmedCwd, !trimmedCwd.isEmpty {
                params["cwd"] = trimmedCwd
            }
            let requestID = self.sendRequestLocked(method: "thread/start", params: params)
            self.threadCreateCompletionsByRequestID[requestID] = completion
            DispatchQueue.main.async {
                self.statusMessage = "Creating thread..."
            }
        }
    }

    func listDirectories(
        cwd: String?,
        completion: @escaping (_ basePath: String?, _ directories: [String], _ errorMessage: String?) -> Void
    ) {
        guard state == .connected else {
            completion(nil, [], "Connection is not ready.")
            return
        }

        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandTimeoutMs = 8_000

        let resolveBasePath: (@escaping (_ basePath: String?, _ errorMessage: String?) -> Void) -> Void = { [weak self] callback in
            guard let self else { return }
            if let trimmedCwd, !trimmedCwd.isEmpty {
                callback(trimmedCwd, nil)
                return
            }

            self.executeCommand(
                command: ["pwd"],
                cwd: nil,
                timeoutMs: commandTimeoutMs
            ) { result, errorMessage in
                guard let result else {
                    callback(nil, errorMessage ?? "Failed to resolve current folder.")
                    return
                }

                let exitCode = result["exitCode"] as? Int ?? -1
                let stdout = (result["stdout"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stderr = (result["stderr"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                guard exitCode == 0, !stdout.isEmpty else {
                    let message = !stderr.isEmpty ? stderr : "Failed to resolve current folder."
                    callback(nil, message)
                    return
                }

                callback(stdout, nil)
            }
        }

        resolveBasePath { [weak self] basePath, baseError in
            guard let self else { return }
            guard let basePath, !basePath.isEmpty else {
                completion(nil, [], baseError ?? "Failed to resolve current folder.")
                return
            }

            self.executeCommand(
                command: ["find", ".", "-maxdepth", "1", "-mindepth", "1", "-type", "d"],
                cwd: basePath,
                timeoutMs: commandTimeoutMs
            ) { result, errorMessage in
                guard let result else {
                    completion(basePath, [], errorMessage ?? "Failed to list folders.")
                    return
                }

                let exitCode = result["exitCode"] as? Int ?? -1
                let stdout = (result["stdout"] as? String) ?? ""
                let stderr = (result["stderr"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                guard exitCode == 0 else {
                    let message = !stderr.isEmpty ? stderr : "Failed to list folders."
                    completion(basePath, [], message)
                    return
                }

                var seen = Set<String>()
                var directories: [String] = []
                for rawLine in stdout.split(whereSeparator: \.isNewline) {
                    var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { continue }
                    if line == "." { continue }
                    if line.hasPrefix("./") {
                        line.removeFirst(2)
                    }

                    let fullPath: String
                    if line.hasPrefix("/") {
                        fullPath = Self.normalizedPath(line)
                    } else {
                        fullPath = Self.normalizedPath(basePath + "/" + line)
                    }

                    if seen.insert(fullPath).inserted {
                        directories.append(fullPath)
                    }
                }

                directories.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                completion(basePath, directories, nil)
            }
        }
    }

    private func normalizedWebSocketURL(from input: String) -> URL? {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        if !raw.contains("://") {
            raw = "ws://\(raw)"
        }

        guard var components = URLComponents(string: raw) else { return nil }
        if components.scheme == "http" { components.scheme = "ws" }
        if components.scheme == "https" { components.scheme = "wss" }

        guard let scheme = components.scheme?.lowercased(), scheme == "ws" || scheme == "wss" else {
            return nil
        }

        return components.url
    }

    private func sendInitializeRequest() {
        sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "schema-agent",
                    "title": "Schema Agent",
                    "version": "0.1.0"
                ]
            ]
        )
    }

    private func handleIncomingText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        handleIncomingData(data)
    }

    private func handleIncomingData(_ data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let payload = object as? [String: Any]
        else { return }

        if let method = payload["method"] as? String {
            let params = payload["params"] as? [String: Any] ?? payload
            handleNotification(method: method, params: params)
            return
        }

        if let id = parseRequestID(payload["id"]) {
            handleResponse(id: id, payload: payload)
        }
    }

    private func handleResponse(id: Int, payload: [String: Any]) {
        let method = pendingRequests.removeValue(forKey: id)

        if let error = payload["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "Unknown server error"
            if method == "thread/start" {
                threadStartPromptsByRequestID.removeValue(forKey: id)
                if let completion = threadCreateCompletionsByRequestID.removeValue(forKey: id) {
                    DispatchQueue.main.async {
                        completion(nil, message)
                    }
                }
                DispatchQueue.main.async {
                    self.isSubmittingTask = false
                }
            } else if method == "thread/resume" {
                if passiveThreadResumeRequestIDs.remove(id) == nil {
                    threadResumePromptsByRequestID.removeValue(forKey: id)
                    DispatchQueue.main.async {
                        self.isSubmittingTask = false
                    }
                }
            } else if method == "turn/start" {
                turnStartContextsByRequestID.removeValue(forKey: id)
                DispatchQueue.main.async {
                    self.isSubmittingTask = false
                }
            } else if method == "thread/read" {
                threadReadThreadIDByRequestID.removeValue(forKey: id)
            } else if method == "model/list" {
                modelListAccumulator.removeAll()
            } else if method == "command/exec" {
                if let completion = commandExecCompletionsByRequestID.removeValue(forKey: id) {
                    DispatchQueue.main.async {
                        completion(nil, message)
                    }
                }
            }
            DispatchQueue.main.async {
                if method == "initialize" {
                    self.state = .failed
                    self.statusMessage = "Server error: \(message)"
                } else {
                    let methodLabel = method ?? "request"
                    self.statusMessage = "Request \(methodLabel) failed: \(message)"
                }
            }
            return
        }

        guard let method else { return }

        if method == "initialize" {
            let userAgent = ((payload["result"] as? [String: Any])?["userAgent"] as? String) ?? "unknown server"
            DispatchQueue.main.async {
                self.didReceiveInitializeResponse = true
                self.state = .connected
                self.statusMessage = "Connected (raw WS, \(userAgent))"
                self.sendNotification(method: "initialized", params: [:])
            }
            sendRequest(method: "thread/list", params: ["limit": 50, "sortKey": "updated_at"])
            sendRequest(method: "model/list", params: ["limit": 100, "includeHidden": false])
        } else if method == "thread/start" {
            handleThreadStartResponse(id: id, payload: payload)
        } else if method == "thread/resume" {
            handleThreadResumeResponse(id: id, payload: payload)
        } else if method == "turn/start" {
            handleTurnStartResponse(id: id, payload: payload)
        } else if method == "thread/list" {
            handleThreadListResponse(payload: payload)
        } else if method == "thread/read" {
            handleThreadReadResponse(id: id, payload: payload)
        } else if method == "model/list" {
            handleModelListResponse(payload: payload)
        } else if method == "command/exec" {
            handleCommandExecResponse(id: id, payload: payload)
        }
    }

    private func handleCommandExecResponse(id: Int, payload: [String: Any]) {
        guard let completion = commandExecCompletionsByRequestID.removeValue(forKey: id) else { return }
        guard let result = payload["result"] as? [String: Any] else {
            DispatchQueue.main.async {
                completion(nil, "command/exec returned unexpected payload.")
            }
            return
        }
        DispatchQueue.main.async {
            completion(result, nil)
        }
    }

    private func handleThreadResumeResponse(id: Int, payload: [String: Any]) {
        let result = payload["result"] as? [String: Any]
        let thread = result?["thread"] as? [String: Any]
        let resumedThreadID = (thread?["id"] as? String)
            ?? stringValue(in: result ?? [:], keys: ["threadId", "thread_id"])
        if let thread {
            upsertThread(from: thread)
        }

        if let resumedThreadID {
            currentThreadID = resumedThreadID
        }

        if passiveThreadResumeRequestIDs.remove(id) != nil {
            if let resumedThreadID {
                touchThread(threadID: resumedThreadID)
            }
            return
        }

        guard let context = threadResumePromptsByRequestID.removeValue(forKey: id) else { return }
        let resolvedThreadID = resumedThreadID ?? context.requestedThreadID
        sendTurnStartLocked(
            threadID: resolvedThreadID,
            prompt: context.prompt,
            model: context.model,
            effort: context.effort
        )
        DispatchQueue.main.async {
            self.statusMessage = "Thread resumed. Starting task..."
        }
    }

    private func handleThreadStartResponse(id: Int, payload: [String: Any]) {
        guard
            let result = payload["result"] as? [String: Any],
            let thread = result["thread"] as? [String: Any],
            let threadID = thread["id"] as? String
        else {
            threadStartPromptsByRequestID.removeValue(forKey: id)
            if let completion = threadCreateCompletionsByRequestID.removeValue(forKey: id) {
                DispatchQueue.main.async {
                    completion(nil, "thread/start succeeded but response was missing thread id.")
                }
            }
            DispatchQueue.main.async {
                self.statusMessage = "thread/start succeeded but response was missing thread id."
            }
            return
        }

        currentThreadID = threadID
        upsertThread(from: thread)

        if let completion = threadCreateCompletionsByRequestID.removeValue(forKey: id) {
            DispatchQueue.main.async {
                self.statusMessage = "Thread created: \(threadID)"
                completion(threadID, nil)
            }
            return
        }

        guard let context = threadStartPromptsByRequestID.removeValue(forKey: id) else {
            DispatchQueue.main.async {
                self.statusMessage = "Thread created: \(threadID)"
            }
            return
        }

        sendTurnStartLocked(
            threadID: threadID,
            prompt: context.prompt,
            model: context.model,
            effort: context.effort
        )
        DispatchQueue.main.async {
            self.statusMessage = "Thread created. Starting task..."
        }
    }

    private func handleTurnStartResponse(id: Int, payload: [String: Any]) {
        let turnID = ((payload["result"] as? [String: Any])?["turn"] as? [String: Any])?["id"] as? String
        let responseThreadID = ((payload["result"] as? [String: Any])?["threadId"] as? String)
        if let context = turnStartContextsByRequestID.removeValue(forKey: id) {
            let threadID = responseThreadID ?? currentThreadID ?? context.threadID
            cacheThreadMappings(threadID: threadID, turnID: turnID, itemID: nil)
            appendActivity(text: context.prompt, kind: .user, threadID: threadID)
        } else {
            cacheThreadMappings(threadID: responseThreadID, turnID: turnID, itemID: nil)
        }
        let shortTurnID = turnID.map { String($0.prefix(8)) } ?? "unknown"
        DispatchQueue.main.async {
            self.isSubmittingTask = false
            self.taskStartSuccessCount += 1
            self.statusMessage = "Task started (turn \(shortTurnID))."
        }
    }

    private func handleThreadListResponse(payload: [String: Any]) {
        guard
            let result = payload["result"] as? [String: Any],
            let data = result["data"] as? [[String: Any]]
        else { return }

        let parsed = data.compactMap(parseThread)

        DispatchQueue.main.async {
            self.threads = parsed
        }
    }

    private func handleThreadReadResponse(id: Int, payload: [String: Any]) {
        let requestedThreadID = threadReadThreadIDByRequestID.removeValue(forKey: id)
        guard
            let result = payload["result"] as? [String: Any],
            let thread = result["thread"] as? [String: Any]
        else {
            DispatchQueue.main.async {
                self.statusMessage = "thread/read returned unexpected payload."
            }
            return
        }

        upsertThread(from: thread)
        let threadID = (thread["id"] as? String) ?? requestedThreadID
        guard let threadID else { return }

        let turns = thread["turns"] as? [[String: Any]] ?? []
        cacheThreadMappingsFromTurns(turns, threadID: threadID)
        let rebuiltActivity = activityEntriesFromTurns(turns, threadID: threadID)
        DispatchQueue.main.async {
            self.activity.removeAll { $0.threadID == threadID }
            self.activity.append(contentsOf: rebuiltActivity)
            self.statusMessage = rebuiltActivity.isEmpty
                ? "Connected. No messages in selected thread."
                : "Loaded \(rebuiltActivity.count) messages from thread."
        }
    }

    private func handleModelListResponse(payload: [String: Any]) {
        guard
            let result = payload["result"] as? [String: Any],
            let data = result["data"] as? [[String: Any]]
        else { return }

        modelListAccumulator.append(contentsOf: data.compactMap(parseModelOption))

        if let nextCursor = stringValue(in: result, keys: ["nextCursor", "next_cursor"]),
           !nextCursor.isEmpty {
            _ = sendRequestLocked(
                method: "model/list",
                params: [
                    "cursor": nextCursor,
                    "limit": 100,
                    "includeHidden": false
                ]
            )
            return
        }

        let deduplicated = deduplicatedModels(modelListAccumulator)
        modelListAccumulator.removeAll()
        DispatchQueue.main.async {
            self.availableModels = deduplicated
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "thread/started", "thread_started":
            if let thread = params["thread"] as? [String: Any] {
                upsertThread(from: thread)
            }

        case "thread/name/updated", "thread_name_updated":
            guard
                let threadID = stringValue(in: params, keys: ["threadId", "thread_id"]),
                let threadName = stringValue(in: params, keys: ["threadName", "thread_name"])
            else { return }
            DispatchQueue.main.async {
                if let index = self.threads.firstIndex(where: { $0.id == threadID }) {
                    self.threads[index].title = threadName
                }
            }

        case "item/started", "item_started":
            guard
                let item = params["item"] as? [String: Any]
            else { return }
            let turnID = resolveTurnID(in: params, item: item)
            let itemID = stringValue(in: item, keys: ["id", "itemId", "item_id"])
            let threadID = resolveThreadID(in: params, item: item)
            cacheThreadMappings(threadID: threadID, turnID: turnID, itemID: itemID)

            guard let task = runningTask(from: item, params: params) else { return }

            DispatchQueue.main.async {
                self.runningTasks.removeAll { $0.id == task.id }
                self.runningTasks.insert(task, at: 0)
            }
            touchThread(threadID: task.threadID)

        case "item/completed", "item_completed":
            guard
                let item = params["item"] as? [String: Any],
                let itemID = stringValue(in: item, keys: ["id", "itemId", "item_id"])
            else { return }
            let turnID = resolveTurnID(in: params, item: item)
            let threadID = resolveThreadID(in: params, item: item)
            cacheThreadMappings(threadID: threadID, turnID: turnID, itemID: itemID)
            DispatchQueue.main.async {
                self.runningTasks.removeAll { $0.id == itemID }
                self.assistantEntryIDByItemID.removeValue(forKey: itemID)
            }
            if let threadID {
                touchThread(threadID: threadID)
            }

        case "item/agentMessage/delta", "agent_message_delta", "agent_message_content_delta":
            guard
                let itemID = stringValue(in: params, keys: ["itemId", "item_id"]),
                let delta = stringValue(in: params, keys: ["delta"])
            else { return }
            let turnID = resolveTurnID(in: params, item: nil)
            let threadID = resolveThreadID(in: params, item: nil)
            cacheThreadMappings(threadID: threadID, turnID: turnID, itemID: itemID)
            guard let threadID else { return }
            appendAssistantDelta(itemID: itemID, threadID: threadID, delta: delta)
            touchThread(threadID: threadID)

        case "agent_message":
            guard
                let message = stringValue(in: params, keys: ["message", "text"]),
                let threadID = resolveThreadID(in: params, item: nil)
            else { return }
            appendActivity(text: message, kind: .assistant, threadID: threadID)
            touchThread(threadID: threadID)

        case "turn/started", "turn_started", "task_started":
            let turn = params["turn"] as? [String: Any]
            guard
                let turnID = stringValue(in: turn ?? params, keys: ["id", "turnId", "turn_id"])
            else { return }
            let threadID = resolveThreadID(in: params, item: nil) ?? "unknown"
            cacheThreadMappings(threadID: threadID, turnID: turnID, itemID: nil)
            let task = RunningTask(
                id: "turn:\(turnID)",
                name: "Turn \(turnID.prefix(8))",
                type: "turn",
                threadID: threadID,
                turnID: turnID,
                startedAt: Date()
            )
            DispatchQueue.main.async {
                self.runningTasks.removeAll { $0.id == task.id }
                self.runningTasks.insert(task, at: 0)
            }
            appendActivity(text: "Turn started: \(String(turnID.prefix(8)))", kind: .system, threadID: threadID)
            touchThread(threadID: threadID)

        case "turn/completed", "turn_complete", "task_complete":
            let turn = params["turn"] as? [String: Any]
            guard
                let turnID = stringValue(in: turn ?? params, keys: ["id", "turnId", "turn_id"])
            else { return }
            let threadID = resolveThreadID(in: params, item: nil)
            cacheThreadMappings(threadID: threadID, turnID: turnID, itemID: nil)
            DispatchQueue.main.async {
                self.runningTasks.removeAll { $0.id == "turn:\(turnID)" }
                if let threadID {
                    self.runningTasks.removeAll { $0.threadID == threadID }
                }
            }
            appendActivity(text: "Turn completed: \(String(turnID.prefix(8)))", kind: .system, threadID: threadID)
            if let message = stringValue(in: params, keys: ["last_agent_message", "lastAgentMessage"]) {
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    appendActivity(text: message, kind: .assistant, threadID: threadID)
                }
            }
            if let threadID {
                touchThread(threadID: threadID)
            }

        default:
            if let legacyType = stringValue(in: params, keys: ["type"]) {
                handleLegacyEvent(type: legacyType, event: params, fallbackThreadID: nil)
            }
        }
    }

    private func handleLegacyEvent(type: String, event: [String: Any], fallbackThreadID: String?) {
        var normalizedEvent = event
        if stringValue(in: normalizedEvent, keys: ["thread_id", "threadId"]) == nil,
           let fallbackThreadID {
            normalizedEvent["threadId"] = fallbackThreadID
        }
        let threadID = resolveThreadID(in: normalizedEvent, item: normalizedEvent["item"] as? [String: Any])

        switch type {
        case "item_started":
            guard
                let item = normalizedEvent["item"] as? [String: Any]
            else { return }
            let turnID = resolveTurnID(in: normalizedEvent, item: item)
            let itemID = stringValue(in: item, keys: ["id", "itemId", "item_id"])
            let resolvedThreadID = resolveThreadID(in: normalizedEvent, item: item)
            cacheThreadMappings(threadID: resolvedThreadID, turnID: turnID, itemID: itemID)
            guard let task = runningTask(from: item, params: normalizedEvent) else { return }
            DispatchQueue.main.async {
                self.runningTasks.removeAll { $0.id == task.id }
                self.runningTasks.insert(task, at: 0)
            }
            touchThread(threadID: task.threadID)

        case "item_completed":
            guard
                let item = normalizedEvent["item"] as? [String: Any],
                let itemID = stringValue(in: item, keys: ["id", "item_id", "itemId"])
            else { return }
            let turnID = resolveTurnID(in: normalizedEvent, item: item)
            let resolvedThreadID = resolveThreadID(in: normalizedEvent, item: item)
            cacheThreadMappings(threadID: resolvedThreadID, turnID: turnID, itemID: itemID)
            DispatchQueue.main.async {
                self.runningTasks.removeAll { $0.id == itemID }
                self.assistantEntryIDByItemID.removeValue(forKey: itemID)
            }
            if let resolvedThreadID {
                touchThread(threadID: resolvedThreadID)
            } else if let threadID {
                touchThread(threadID: threadID)
            }

        case "agent_message_content_delta", "agent_message_delta":
            guard
                let itemID = stringValue(in: normalizedEvent, keys: ["item_id", "itemId"]),
                let delta = stringValue(in: normalizedEvent, keys: ["delta"])
            else { return }
            let turnID = resolveTurnID(in: normalizedEvent, item: nil)
            let resolvedThreadID = resolveThreadID(in: normalizedEvent, item: nil)
            cacheThreadMappings(threadID: resolvedThreadID, turnID: turnID, itemID: itemID)
            guard let resolvedThreadID else { return }
            appendAssistantDelta(itemID: itemID, threadID: resolvedThreadID, delta: delta)
            touchThread(threadID: resolvedThreadID)

        case "agent_message":
            guard
                let threadID,
                let message = stringValue(in: normalizedEvent, keys: ["message", "text"])
            else { return }
            appendActivity(text: message, kind: .assistant, threadID: threadID)
            touchThread(threadID: threadID)

        case "task_started", "turn_started":
            guard let turnID = stringValue(in: normalizedEvent, keys: ["turn_id", "turnId", "id"]) else { return }
            let resolvedThreadID = threadID ?? "unknown"
            cacheThreadMappings(threadID: resolvedThreadID, turnID: turnID, itemID: nil)
            let task = RunningTask(
                id: "turn:\(turnID)",
                name: "Turn \(turnID.prefix(8))",
                type: "turn",
                threadID: resolvedThreadID,
                turnID: turnID,
                startedAt: Date()
            )
            DispatchQueue.main.async {
                self.runningTasks.removeAll { $0.id == task.id }
                self.runningTasks.insert(task, at: 0)
            }
            appendActivity(text: "Turn started: \(String(turnID.prefix(8)))", kind: .system, threadID: resolvedThreadID)
            touchThread(threadID: resolvedThreadID)

        case "task_complete", "turn_complete":
            guard let turnID = stringValue(in: normalizedEvent, keys: ["turn_id", "turnId", "id"]) else { return }
            cacheThreadMappings(threadID: threadID, turnID: turnID, itemID: nil)
            DispatchQueue.main.async {
                self.runningTasks.removeAll { $0.id == "turn:\(turnID)" }
                if let threadID {
                    self.runningTasks.removeAll { $0.threadID == threadID }
                }
            }
            appendActivity(text: "Turn completed: \(String(turnID.prefix(8)))", kind: .system, threadID: threadID)
            if let message = stringValue(in: normalizedEvent, keys: ["last_agent_message", "lastAgentMessage"]) {
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    appendActivity(text: message, kind: .assistant, threadID: threadID)
                }
            }
            if let threadID {
                touchThread(threadID: threadID)
            }

        case "thread_name_updated":
            guard
                let threadID,
                let threadName = stringValue(in: normalizedEvent, keys: ["thread_name", "threadName"])
            else { return }
            DispatchQueue.main.async {
                if let index = self.threads.firstIndex(where: { $0.id == threadID }) {
                    self.threads[index].title = threadName
                }
            }

        case "session_configured":
            let sessionID = stringValue(in: event, keys: ["session_id", "sessionId"]) ?? threadID
            if let initialMessages = (event["initial_messages"] as? [[String: Any]]) ?? (event["initialMessages"] as? [[String: Any]]) {
                for message in initialMessages {
                    guard let nestedType = stringValue(in: message, keys: ["type"]) else { continue }
                    handleLegacyEvent(type: nestedType, event: message, fallbackThreadID: sessionID)
                }
            }

        default:
            break
        }
    }

    private func cacheThreadMappings(threadID: String?, turnID: String?, itemID: String?) {
        guard let threadID, !threadID.isEmpty else { return }
        if let turnID, !turnID.isEmpty {
            threadIDByTurnID[turnID] = threadID
        }
        if let itemID, !itemID.isEmpty {
            threadIDByItemID[itemID] = threadID
            if let turnID, !turnID.isEmpty {
                turnIDByItemID[itemID] = turnID
            }
        }
    }

    private func cacheThreadMappingsFromTurns(_ turns: [[String: Any]], threadID: String) {
        for turn in turns {
            let turnID = stringValue(in: turn, keys: ["id", "turnId", "turn_id"])
            cacheThreadMappings(threadID: threadID, turnID: turnID, itemID: nil)
            guard let items = turn["items"] as? [[String: Any]] else { continue }
            for item in items {
                let itemID = stringValue(in: item, keys: ["id", "itemId", "item_id"])
                cacheThreadMappings(threadID: threadID, turnID: turnID, itemID: itemID)
            }
        }
    }

    private func resolveTurnID(in params: [String: Any], item: [String: Any]? = nil) -> String? {
        if let direct = stringValue(in: params, keys: ["turnId", "turn_id"]) {
            return direct
        }
        if let turn = params["turn"] as? [String: Any],
           let nested = stringValue(in: turn, keys: ["id", "turnId", "turn_id"]) {
            return nested
        }
        let itemID = stringValue(in: item ?? [:], keys: ["id", "itemId", "item_id"])
            ?? stringValue(in: params, keys: ["itemId", "item_id"])
        if let itemID, let mapped = turnIDByItemID[itemID] {
            return mapped
        }
        return nil
    }

    private func resolveThreadID(in params: [String: Any], item: [String: Any]? = nil) -> String? {
        if let direct = stringValue(in: params, keys: ["threadId", "thread_id"]) {
            return direct
        }
        if let turn = params["turn"] as? [String: Any],
           let nested = stringValue(in: turn, keys: ["threadId", "thread_id"]) {
            return nested
        }

        if let turnID = resolveTurnID(in: params, item: item),
           let mapped = threadIDByTurnID[turnID] {
            return mapped
        }

        let itemID = stringValue(in: item ?? [:], keys: ["id", "itemId", "item_id"])
            ?? stringValue(in: params, keys: ["itemId", "item_id"])
        if let itemID, let mapped = threadIDByItemID[itemID] {
            return mapped
        }

        return currentThreadID
    }

    private func stringValue(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String {
                return value
            }
        }
        return nil
    }

    private func executeCommand(
        command: [String],
        cwd: String?,
        timeoutMs: Int?,
        completion: @escaping (_ result: [String: Any]?, _ errorMessage: String?) -> Void
    ) {
        guard state == .connected else {
            completion(nil, "Connection is not ready.")
            return
        }

        connectionQueue.async {
            var params: [String: Any] = ["command": command]
            if let cwd, !cwd.isEmpty {
                params["cwd"] = cwd
            }
            if let timeoutMs {
                params["timeoutMs"] = timeoutMs
            }
            let requestID = self.sendRequestLocked(method: "command/exec", params: params)
            self.commandExecCompletionsByRequestID[requestID] = completion
        }
    }

    private static func normalizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let standardized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        if standardized.count > 1 && standardized.hasSuffix("/") {
            return String(standardized.dropLast())
        }
        return standardized
    }

    private func runningTask(from item: [String: Any], params: [String: Any]) -> RunningTask? {
        guard
            let id = item["id"] as? String,
            let type = item["type"] as? String
        else { return nil }

        let turnID = resolveTurnID(in: params, item: item) ?? "unknown"
        let threadID = resolveThreadID(in: params, item: item) ?? "unknown"
        cacheThreadMappings(
            threadID: threadID == "unknown" ? nil : threadID,
            turnID: turnID == "unknown" ? nil : turnID,
            itemID: id
        )

        let name: String
        switch type {
        case "commandExecution":
            let command = (item["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Command execution"
            name = command.isEmpty ? "Command execution" : command
        case "fileChange":
            name = "File change"
        case "mcpToolCall":
            let tool = (item["tool"] as? String) ?? "tool"
            name = "MCP \(tool)"
        case "collabAgentToolCall":
            let tool = (item["tool"] as? String) ?? "tool"
            name = "Collab \(tool)"
        case "webSearch":
            let query = (item["query"] as? String) ?? "Web search"
            name = "Web search: \(query)"
        default:
            name = type
        }

        return RunningTask(
            id: id,
            name: name,
            type: type,
            threadID: threadID,
            turnID: turnID,
            startedAt: Date()
        )
    }

    private func sendTurnStartLocked(threadID: String, prompt: String, model: String?, effort: String?) {
        currentThreadID = threadID
        var turnParams: [String: Any] = [
            "threadId": threadID,
            "input": [
                [
                    "type": "text",
                    "text": prompt
                ]
            ]
        ]
        if let model, !model.isEmpty {
            turnParams["model"] = model
        }
        if let effort, !effort.isEmpty {
            turnParams["effort"] = effort
        }
        let requestID = sendRequestLocked(method: "turn/start", params: turnParams)
        turnStartContextsByRequestID[requestID] = PendingTurnStartContext(prompt: prompt, threadID: threadID)
        DispatchQueue.main.async {
            self.statusMessage = "Starting task..."
        }
    }

    private func parseModelOption(_ raw: [String: Any]) -> AppServerModelOption? {
        guard
            let id = raw["id"] as? String,
            let model = raw["model"] as? String
        else { return nil }

        let rawDisplayName = (raw["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = rawDisplayName.isEmpty ? model : rawDisplayName
        let isDefault = raw["isDefault"] as? Bool ?? false
        let defaultReasoningEffort = (raw["defaultReasoningEffort"] as? String) ?? ""
        let supportedRaw = raw["supportedReasoningEfforts"] as? [[String: Any]] ?? []
        var supported = supportedRaw.compactMap { option -> AppServerReasoningEffortOption? in
            guard let reasoningEffort = option["reasoningEffort"] as? String else { return nil }
            let description = (option["description"] as? String) ?? ""
            return AppServerReasoningEffortOption(
                id: "\(model)-\(reasoningEffort)",
                reasoningEffort: reasoningEffort,
                description: description
            )
        }

        if !defaultReasoningEffort.isEmpty && !supported.contains(where: { $0.reasoningEffort == defaultReasoningEffort }) {
            supported.insert(
                AppServerReasoningEffortOption(
                    id: "\(model)-\(defaultReasoningEffort)",
                    reasoningEffort: defaultReasoningEffort,
                    description: ""
                ),
                at: 0
            )
        }

        return AppServerModelOption(
            id: id,
            model: model,
            displayName: displayName,
            isDefault: isDefault,
            defaultReasoningEffort: defaultReasoningEffort,
            supportedReasoningEfforts: supported
        )
    }

    private func deduplicatedModels(_ models: [AppServerModelOption]) -> [AppServerModelOption] {
        var seenModelIDs = Set<String>()
        var deduplicated: [AppServerModelOption] = []

        for model in models {
            if seenModelIDs.insert(model.model).inserted {
                deduplicated.append(model)
            }
        }

        deduplicated.sort { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault && !rhs.isDefault
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return deduplicated
    }

    private func parseThread(_ raw: [String: Any]) -> AppThread? {
        guard let threadID = raw["id"] as? String else { return nil }
        let cwd = (raw["cwd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preview = (raw["preview"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = preview.isEmpty ? "Thread \(threadID.prefix(8))" : preview
        let updatedAt = dateFromUnixSeconds(raw["updatedAt"]) ?? Date()
        return AppThread(
            id: threadID,
            cwd: cwd,
            title: title,
            subtitle: String(threadID.prefix(8)),
            updatedAt: updatedAt
        )
    }

    private func upsertThread(from raw: [String: Any]) {
        guard let thread = parseThread(raw) else { return }
        DispatchQueue.main.async {
            if let existingIndex = self.threads.firstIndex(where: { $0.id == thread.id }) {
                self.threads[existingIndex].cwd = thread.cwd
                self.threads[existingIndex].title = thread.title
                self.threads[existingIndex].subtitle = thread.subtitle
                self.threads[existingIndex].updatedAt = thread.updatedAt
            } else {
                self.threads.insert(thread, at: 0)
            }
        }
    }

    private func touchThread(threadID: String) {
        DispatchQueue.main.async {
            guard let existingIndex = self.threads.firstIndex(where: { $0.id == threadID }) else { return }
            self.threads[existingIndex].updatedAt = Date()
        }
    }

    private func dateFromUnixSeconds(_ raw: Any?) -> Date? {
        if let intValue = raw as? Int {
            return Date(timeIntervalSince1970: TimeInterval(intValue))
        }
        if let doubleValue = raw as? Double {
            return Date(timeIntervalSince1970: doubleValue)
        }
        if let numberValue = raw as? NSNumber {
            return Date(timeIntervalSince1970: numberValue.doubleValue)
        }
        return nil
    }

    private func appendActivity(text: String, kind: ActivityEntry.Kind, threadID: String?) {
        let trimmed = sanitizeDisplayText(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        DispatchQueue.main.async {
            self.activity.append(
                ActivityEntry(
                    threadID: threadID,
                    createdAt: Date(),
                    kind: kind,
                    text: trimmed
                )
            )
        }
    }

    private func appendAssistantDelta(itemID: String, threadID: String, delta: String) {
        DispatchQueue.main.async {
            if let entryID = self.assistantEntryIDByItemID[itemID],
               let index = self.activity.firstIndex(where: { $0.id == entryID }) {
                let updatedText = self.activity[index].text + delta
                self.activity[index].text = self.sanitizeDisplayText(updatedText)
                return
            }

            let entry = ActivityEntry(
                threadID: threadID,
                createdAt: Date(),
                kind: .assistant,
                text: self.sanitizeDisplayText(delta)
            )
            self.activity.append(entry)
            self.assistantEntryIDByItemID[itemID] = entry.id
        }
    }

    private func activityEntriesFromTurns(_ turns: [[String: Any]], threadID: String) -> [ActivityEntry] {
        var entries: [ActivityEntry] = []

        for turn in turns {
            guard let items = turn["items"] as? [[String: Any]] else { continue }
            for item in items {
                guard let itemType = item["type"] as? String else { continue }
                switch itemType {
                case "userMessage":
                    guard let content = item["content"] as? [[String: Any]] else { continue }
                    let parsedUserMessage = parseUserMessage(content)
                    let text = parsedUserMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty || !parsedUserMessage.imageURLs.isEmpty || !parsedUserMessage.localImagePaths.isEmpty else { continue }
                    entries.append(
                        ActivityEntry(
                            threadID: threadID,
                            createdAt: Date(),
                            kind: .user,
                            text: text,
                            imageURLs: parsedUserMessage.imageURLs,
                            localImagePaths: parsedUserMessage.localImagePaths
                        )
                    )

                case "agentMessage":
                    let text = sanitizeDisplayText((item["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    entries.append(
                        ActivityEntry(
                            threadID: threadID,
                            createdAt: Date(),
                            kind: .assistant,
                            text: text
                        )
                    )

                default:
                    continue
                }
            }
        }

        return entries
    }

    private func parseUserMessage(_ content: [[String: Any]]) -> (text: String, imageURLs: [String], localImagePaths: [String]) {
        var lines: [String] = []
        var imageURLs: [String] = []
        var localImagePaths: [String] = []

        for input in content {
            guard let type = input["type"] as? String else { continue }
            switch type {
            case "text":
                if let text = input["text"] as? String {
                    let sanitized = sanitizeDisplayText(text).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sanitized.isEmpty {
                        lines.append(sanitized)
                    }
                }
            case "image":
                let imageURL = (input["url"] as? String) ?? (input["image_url"] as? String)
                if let imageURL, !imageURL.isEmpty {
                    imageURLs.append(imageURL)
                } else if let payload = input["data"] as? String, !payload.isEmpty {
                    imageURLs.append(payload)
                } else {
                    lines.append("[Image attachment]")
                }
            case "localImage":
                if let path = input["path"] as? String, !path.isEmpty {
                    localImagePaths.append(path)
                } else if let path = input["local_image"] as? String, !path.isEmpty {
                    localImagePaths.append(path)
                } else {
                    lines.append("[Local image attachment]")
                }
            case "skill":
                if let name = input["name"] as? String {
                    lines.append("[Skill] \(name)")
                } else {
                    lines.append("[Skill]")
                }
            case "mention":
                if let name = input["name"] as? String {
                    lines.append("[Mention] \(name)")
                } else {
                    lines.append("[Mention]")
                }
            default:
                continue
            }
        }

        return (lines.joined(separator: "\n"), imageURLs, localImagePaths)
    }

    private func sanitizeDisplayText(_ rawText: String) -> String {
        guard !rawText.isEmpty else { return "" }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawText }
        if looksLikeImageDataURI(trimmed) {
            return "[Image attachment]"
        }
        if looksLikeBase64Blob(trimmed) {
            return "[Image attachment]"
        }
        return replacingEmbeddedBase64(in: rawText)
    }

    private func looksLikeImageDataURI(_ text: String) -> Bool {
        text.hasPrefix("data:image/")
    }

    private func looksLikeBase64Blob(_ text: String) -> Bool {
        guard text.count >= 220 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=\n\r")
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let compact = text.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        guard compact.count >= 220 else { return false }
        return compact.count % 4 == 0
    }

    private func replacingEmbeddedBase64(in text: String) -> String {
        let pattern = "([A-Za-z0-9+/]{180,}={0,2})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if regex.firstMatch(in: text, options: [], range: nsRange) == nil {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: nsRange,
            withTemplate: "[Image attachment]"
        )
    }

    @discardableResult
    private func sendRequestLocked(method: String, params: [String: Any]) -> Int {
        let id = nextRequestID
        nextRequestID += 1
        pendingRequests[id] = method

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]

        send(payload: payload)
        return id
    }

    private func sendRequest(method: String, params: [String: Any]) {
        connectionQueue.async {
            _ = self.sendRequestLocked(method: method, params: params)
        }
    }

    private func sendNotification(method: String, params: [String: Any]?) {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]

        if let params {
            payload["params"] = params
        }

        send(payload: payload)
    }

    private func send(payload: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let text = String(data: data, encoding: .utf8)
        else { return }

        let line = text.hasSuffix("\n") ? text : text + "\n"
        sendText(line)
    }

    private func sendText(_ text: String) {
        connectionQueue.async {
            guard self.phaseIsOpenLocked() else {
                self.queuedMessages.append(text)
                return
            }
            self.sendFrameLocked(opcode: 0x1, payload: Data(text.utf8))
        }
    }

    private func parseRequestID(_ value: Any?) -> Int? {
        if let id = value as? Int {
            return id
        }
        if let idNumber = value as? NSNumber {
            return idNumber.intValue
        }
        if let idString = value as? String {
            return Int(idString)
        }
        return nil
    }

    private func connectionErrorText(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (code: \(nsError.code))"
    }

    private func prepareCandidateURLs(from baseURL: URL) {
        candidateURLs = [baseURL]

        if (baseURL.path.isEmpty || baseURL.path == "/"), var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) {
            components.path = "/ws"
            if let wsURL = components.url {
                candidateURLs.append(wsURL)
            }
        }
    }

    private func connectToCurrentCandidate() {
        guard currentCandidateIndex < candidateURLs.count else {
            DispatchQueue.main.async {
                self.state = .failed
                self.statusMessage = "Unable to connect to any endpoint."
            }
            return
        }

        let url = candidateURLs[currentCandidateIndex]
        queuedMessages.removeAll()
        pendingRequests.removeAll()
        threadStartPromptsByRequestID.removeAll()
        threadResumePromptsByRequestID.removeAll()
        passiveThreadResumeRequestIDs.removeAll()
        turnStartContextsByRequestID.removeAll()
        threadReadThreadIDByRequestID.removeAll()
        threadCreateCompletionsByRequestID.removeAll()
        commandExecCompletionsByRequestID.removeAll()
        assistantEntryIDByItemID.removeAll()
        modelListAccumulator.removeAll()
        threadIDByTurnID.removeAll()
        threadIDByItemID.removeAll()
        turnIDByItemID.removeAll()
        didReceiveInitializeResponse = false
        connectedURL = url
        phase = .connecting
        receiveBuffer.removeAll()
        activeHandshakeKey = nil
        DispatchQueue.main.async {
            self.statusMessage = "Connecting (raw WS) to \(url.absoluteString)..."
        }

        guard let host = url.host else {
            DispatchQueue.main.async {
                self.state = .failed
                self.statusMessage = "Missing host in URL."
            }
            return
        }

        let defaultPort = url.scheme?.lowercased() == "wss" ? 443 : 80
        let rawPort = url.port ?? defaultPort
        guard let port = NWEndpoint.Port(rawValue: UInt16(rawPort)) else {
            DispatchQueue.main.async {
                self.state = .failed
                self.statusMessage = "Invalid port in URL."
            }
            return
        }

        let parameters: NWParameters = (url.scheme?.lowercased() == "wss") ? .tls : .tcp
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] nwState in
            guard let self else { return }
            self.connectionQueue.async {
                guard self.connection === connection else { return }
                switch nwState {
                case .ready:
                    DispatchQueue.main.async {
                        self.statusMessage = "TCP connected (raw WS), sending handshake..."
                    }
                    self.beginHandshakeLocked()
                case .failed(let error):
                    self.handleConnectionFailureLocked(error)
                case .cancelled:
                    if !self.isUserInitiatedDisconnect {
                        self.handleConnectionFailureLocked(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))
                    }
                default:
                    break
                }
            }
        }

        connection.start(queue: connectionQueue)
        scheduleConnectTimeoutLocked(seconds: 6)
        receiveLoopLocked(for: connection)
    }

    private func handleConnectionFailureLocked(_ error: Error) {
        cancelConnectTimeoutLocked()
        let wasOpen = phaseIsOpenLocked() || didReceiveInitializeResponse
        let attemptedURL = currentCandidateIndex < candidateURLs.count ? candidateURLs[currentCandidateIndex].absoluteString : serverURLString
        let message = connectionErrorText(error)
        teardownConnectionLocked()

        if !wasOpen && currentCandidateIndex + 1 < candidateURLs.count {
            currentCandidateIndex += 1
            let retryURL = candidateURLs[currentCandidateIndex].absoluteString
            DispatchQueue.main.async {
                self.statusMessage = "Failed at \(attemptedURL). Retrying \(retryURL)..."
            }
            connectToCurrentCandidate()
            return
        }

        DispatchQueue.main.async {
            self.state = .failed
            self.statusMessage = "Connection failed at \(attemptedURL): \(message)"
        }
    }

    private func receiveLoopLocked(for connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.connectionQueue.async {
                guard self.connection === connection else { return }
                if let data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    self.processIncomingBufferLocked()
                }

                if let error {
                    self.handleConnectionFailureLocked(error)
                    return
                }

                if isComplete {
                    let closeError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
                    self.handleConnectionFailureLocked(closeError)
                    return
                }

                self.receiveLoopLocked(for: connection)
            }
        }
    }

    private func beginHandshakeLocked() {
        guard let url = connectedURL else { return }
        guard let connection else { return }
        phase = .handshaking

        let keyData = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = keyData.base64EncodedString()
        activeHandshakeKey = key

        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            path += "?\(query)"
        }

        let defaultPort = url.scheme?.lowercased() == "wss" ? 443 : 80
        let hostPart = url.host ?? "127.0.0.1"
        let hostHeader = (url.port != nil && url.port != defaultPort) ? "\(hostPart):\(url.port!)" : hostPart

        let requestLines = [
            "GET \(path) HTTP/1.1",
            "Host: \(hostHeader)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
            "User-Agent: schema-agent/0.1.0"
        ]
        let request = requestLines.joined(separator: "\r\n") + "\r\n\r\n"

        connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.connectionQueue.async {
                guard self.connection === connection else { return }
                self.handleConnectionFailureLocked(error)
            }
        })

        DispatchQueue.main.async {
            self.statusMessage = "Handshake sent (raw WS), waiting for 101..."
        }

        // If any handshake bytes were buffered before we entered handshaking, parse them now.
        processIncomingBufferLocked()
    }

    private func processIncomingBufferLocked() {
        if phaseIsHandshakingLocked() {
            guard processHandshakeResponseLocked() else { return }
        }

        guard phaseIsOpenLocked() else { return }
        processFramesLocked()
    }

    private func processHandshakeResponseLocked() -> Bool {
        guard let delimiterRange = handshakeDelimiterRange(in: receiveBuffer) else {
            return false
        }

        let headerData = receiveBuffer.subdata(in: 0..<delimiterRange.upperBound)
        receiveBuffer.removeSubrange(0..<delimiterRange.upperBound)

        let headerText = String(data: headerData, encoding: .utf8) ?? String(decoding: headerData, as: UTF8.self)
        let normalizedHeader = headerText.replacingOccurrences(of: "\r\n", with: "\n")
        guard let rawStatusLine = normalizedHeader.split(separator: "\n", omittingEmptySubsequences: false).first else {
            handleConnectionFailureLocked(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotParseResponse))
            return false
        }
        let statusLine = String(rawStatusLine).trimmingCharacters(in: .whitespacesAndNewlines)

        guard statusLine.contains("101") else {
            let bodyPreview = String(data: receiveBuffer.prefix(200), encoding: .utf8) ?? ""
            let error = NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCannotParseResponse,
                userInfo: [NSLocalizedDescriptionKey: "Handshake rejected: \(statusLine). \(bodyPreview)"]
            )
            handleConnectionFailureLocked(error)
            return false
        }

        phase = .open
        cancelConnectTimeoutLocked()
        DispatchQueue.main.async {
            self.statusMessage = "Socket open (raw WS), sending initialize..."
            self.sendInitializeRequest()
        }

        if !queuedMessages.isEmpty {
            let buffered = queuedMessages
            queuedMessages.removeAll()
            for message in buffered {
                sendFrameLocked(opcode: 0x1, payload: Data(message.utf8))
            }
        }

        return true
    }

    private func handshakeDelimiterRange(in data: Data) -> Range<Data.Index>? {
        if let range = data.range(of: Data("\r\n\r\n".utf8)) {
            return range
        }
        return data.range(of: Data("\n\n".utf8))
    }

    private func processFramesLocked() {
        while let frame = decodeNextFrameLocked() {
            switch frame.opcode {
            case 0x1:
                if let text = String(data: frame.payload, encoding: .utf8) {
                    handleIncomingText(text)
                }
            case 0x8:
                var closeCode = 1000
                var reason = ""
                if frame.payload.count >= 2 {
                    closeCode = Int((UInt16(frame.payload[0]) << 8) | UInt16(frame.payload[1]))
                    if frame.payload.count > 2 {
                        reason = String(data: frame.payload.dropFirst(2), encoding: .utf8) ?? ""
                    }
                }
                let error = NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorNetworkConnectionLost,
                    userInfo: [NSLocalizedDescriptionKey: "Server closed socket (\(closeCode)): \(reason)"]
                )
                handleConnectionFailureLocked(error)
                return
            case 0x9:
                sendFrameLocked(opcode: 0xA, payload: frame.payload)
            default:
                break
            }
        }
    }

    private func decodeNextFrameLocked() -> (opcode: UInt8, payload: Data)? {
        guard receiveBuffer.count >= 2 else { return nil }

        let first = receiveBuffer[0]
        let second = receiveBuffer[1]
        let opcode = first & 0x0F
        let isMasked = (second & 0x80) != 0
        var length = Int(second & 0x7F)
        var index = 2

        if length == 126 {
            guard receiveBuffer.count >= index + 2 else { return nil }
            let b0 = UInt16(receiveBuffer[index])
            let b1 = UInt16(receiveBuffer[index + 1])
            length = Int((b0 << 8) | b1)
            index += 2
        } else if length == 127 {
            guard receiveBuffer.count >= index + 8 else { return nil }
            var value: UInt64 = 0
            for offset in 0..<8 {
                value = (value << 8) | UInt64(receiveBuffer[index + offset])
            }
            guard value <= UInt64(Int.max) else { return nil }
            length = Int(value)
            index += 8
        }

        var maskKey = Data()
        if isMasked {
            guard receiveBuffer.count >= index + 4 else { return nil }
            maskKey = receiveBuffer[index..<index + 4]
            index += 4
        }

        guard receiveBuffer.count >= index + length else { return nil }
        var payload = receiveBuffer[index..<index + length]
        receiveBuffer.removeSubrange(0..<index + length)

        if isMasked {
            var unmasked = Data(count: payload.count)
            for i in 0..<payload.count {
                unmasked[i] = payload[payload.startIndex + i] ^ maskKey[maskKey.startIndex + (i % 4)]
            }
            payload = unmasked[...]
        }

        return (opcode, Data(payload))
    }

    private func sendFrameLocked(opcode: UInt8, payload: Data) {
        guard phaseIsOpenLocked() else { return }
        guard let connection else { return }

        var frame = Data()
        frame.append(0x80 | opcode)

        let length = payload.count
        if length < 126 {
            frame.append(0x80 | UInt8(length))
        } else if length <= 0xFFFF {
            frame.append(0x80 | 126)
            var len16 = UInt16(length).bigEndian
            withUnsafeBytes(of: &len16) { frame.append(contentsOf: $0) }
        } else {
            frame.append(0x80 | 127)
            var len64 = UInt64(length).bigEndian
            withUnsafeBytes(of: &len64) { frame.append(contentsOf: $0) }
        }

        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)

        var maskedPayload = Data(capacity: payload.count)
        for i in 0..<payload.count {
            maskedPayload.append(payload[i] ^ mask[i % 4])
        }
        frame.append(maskedPayload)

        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.connectionQueue.async {
                guard self.connection === connection else { return }
                self.handleConnectionFailureLocked(error)
            }
        })
    }

    private func teardownConnectionLocked() {
        cancelConnectTimeoutLocked()
        phase = .closed
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
        activeHandshakeKey = nil
        connectedURL = nil
    }

    private func scheduleConnectTimeoutLocked(seconds: TimeInterval) {
        cancelConnectTimeoutLocked()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.phaseIsOpenLocked() else { return }
            let preview = String(data: self.receiveBuffer.prefix(160), encoding: .utf8) ?? ""
            let description = preview.isEmpty
                ? "Handshake timeout after \(Int(seconds))s (no response bytes)."
                : "Handshake timeout after \(Int(seconds))s. Partial response: \(preview)"
            let error = NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorTimedOut,
                userInfo: [NSLocalizedDescriptionKey: description]
            )
            self.handleConnectionFailureLocked(error)
        }
        connectionTimeoutWorkItem = workItem
        connectionQueue.asyncAfter(deadline: .now() + seconds, execute: workItem)
    }

    private func cancelConnectTimeoutLocked() {
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
    }

    private func phaseIsOpenLocked() -> Bool {
        if case .open = phase {
            return true
        }
        return false
    }

    private func phaseIsHandshakingLocked() -> Bool {
        if case .handshaking = phase {
            return true
        }
        return false
    }
}

#if os(iOS)
private typealias PlatformImage = UIImage
#elseif os(macOS)
private typealias PlatformImage = NSImage
#endif

private func normalizedHexColor(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let prefixed = trimmed.hasPrefix("#") ? trimmed : "#\(trimmed)"
    guard prefixed.count == 7 else { return SavedAppServerConnection.defaultColorHex }
    let hex = prefixed.dropFirst()
    guard hex.allSatisfy({ $0.isHexDigit }) else { return SavedAppServerConnection.defaultColorHex }
    return prefixed
}

private func colorFromHex(_ hex: String) -> Color {
    let normalized = normalizedHexColor(hex)
    let raw = String(normalized.dropFirst())
    guard let value = UInt64(raw, radix: 16) else {
        return Color.accentColor
    }
    let red = Double((value & 0xFF0000) >> 16) / 255.0
    let green = Double((value & 0x00FF00) >> 8) / 255.0
    let blue = Double(value & 0x0000FF) / 255.0
    return Color(red: red, green: green, blue: blue)
}

private func hexString(from color: Color) -> String {
    #if os(iOS)
    let uiColor = UIColor(color)
    var redComponent: CGFloat = 0
    var greenComponent: CGFloat = 0
    var blueComponent: CGFloat = 0
    var alpha: CGFloat = 0
    guard uiColor.getRed(&redComponent, green: &greenComponent, blue: &blueComponent, alpha: &alpha) else {
        return SavedAppServerConnection.defaultColorHex
    }
    #else
    guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
        return SavedAppServerConnection.defaultColorHex
    }
    let redComponent = converted.redComponent
    let greenComponent = converted.greenComponent
    let blueComponent = converted.blueComponent
    #endif

    let r = Int(round(redComponent * 255))
    let g = Int(round(greenComponent * 255))
    let b = Int(round(blueComponent * 255))
    return String(format: "#%02X%02X%02X", r, g, b)
}

struct SavedAppServerConnection: Identifiable, Codable, Hashable {
    static let defaultColorHex = "#4A8DFF"

    var id: String
    var name: String
    var host: String
    var port: String
    var isEnabled: Bool
    var colorHex: String

    init(
        id: String = UUID().uuidString,
        name: String,
        host: String,
        port: String,
        isEnabled: Bool = true,
        colorHex: String = SavedAppServerConnection.defaultColorHex
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.isEnabled = isEnabled
        self.colorHex = normalizedHexColor(colorHex)
    }

    var normalizedHost: String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "127.0.0.1" : trimmed
    }

    var normalizedPort: String {
        let digits = port.trimmingCharacters(in: .whitespacesAndNewlines).filter(\.isNumber)
        return digits.isEmpty ? "9281" : digits
    }

    var urlString: String {
        "ws://\(normalizedHost):\(normalizedPort)"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case port
        case isEnabled
        case colorHex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(String.self, forKey: .port)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        let decodedColorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        colorHex = normalizedHexColor(decodedColorHex ?? SavedAppServerConnection.defaultColorHex)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(normalizedHexColor(colorHex), forKey: .colorHex)
    }
}

struct MergedAppThread: Identifiable, Hashable {
    let id: String
    let connectionID: String
    let connectionName: String
    let connectionColorHex: String
    let thread: AppThread

    var rawThreadID: String { thread.id }
    var cwd: String { thread.cwd }
    var title: String { thread.title }
    var updatedAt: Date { thread.updatedAt }
    var updatedAtText: String { thread.updatedAtText }
}

struct MergedRunningTask: Identifiable, Hashable {
    let id: String
    let connectionID: String
    let connectionName: String
    let mergedThreadID: String
    let task: RunningTask

    var name: String { task.name }
    var type: String { task.type }
    var startedAt: Date { task.startedAt }
    var startedAtText: String { task.startedAtText }
}

struct ConnectionStatus: Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let port: String
    let isEnabled: Bool
    let colorHex: String
    let state: AppServerConnectionState

    var urlString: String {
        "ws://\(host):\(port)"
    }

    var stateLabel: String {
        switch state {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting"
        case .failed:
            return "Failed"
        case .disconnected:
            return "Disconnected"
        }
    }
}

final class MultiAppServerConnectionStore: ObservableObject {
    @Published private(set) var connections: [SavedAppServerConnection] = []
    @Published private(set) var connectionStatuses: [ConnectionStatus] = []
    @Published private(set) var mergedThreads: [MergedAppThread] = []
    @Published private(set) var mergedRunningTasks: [MergedRunningTask] = []
    @Published private(set) var taskStartSuccessCount = 0
    @Published private(set) var connectedEnabledCount = 0
    @Published private(set) var enabledCount = 0

    private var serversByConnectionID: [String: AppServerConnection] = [:]
    private var serverChangeSubscriptions: [String: AnyCancellable] = [:]
    private var taskStartCountSubscriptions: [String: AnyCancellable] = [:]
    private var latestTaskStartCountByConnectionID: [String: Int] = [:]
    private var mergedThreadLookup: [String: (connectionID: String, rawThreadID: String)] = [:]

    private let savedConnectionsKey = "savedAppServerConnectionsV1"
    private let legacyURLKey = "preferredAppServerURL"
    private let legacyHostKey = "preferredConnectionIPAddress"
    private let legacyPortKey = "preferredConnectionPort"

    init() {
        loadSavedConnections()
        reconcileConnections()
    }

    deinit {
        for server in serversByConnectionID.values {
            server.disconnect()
        }
        serverChangeSubscriptions.values.forEach { $0.cancel() }
        taskStartCountSubscriptions.values.forEach { $0.cancel() }
    }

    func addConnection(name: String, host: String, port: String, colorHex: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = port.trimmingCharacters(in: .whitespacesAndNewlines).filter(\.isNumber)
        guard !trimmedName.isEmpty, !trimmedHost.isEmpty, !digits.isEmpty else { return }

        connections.append(
            SavedAppServerConnection(
                name: trimmedName,
                host: trimmedHost,
                port: digits,
                isEnabled: true,
                colorHex: colorHex
            )
        )
        persistConnections()
        reconcileConnections()
    }

    func setConnectionEnabled(_ isEnabled: Bool, connectionID: String) {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else { return }
        guard connections[index].isEnabled != isEnabled else { return }
        connections[index].isEnabled = isEnabled
        persistConnections()
        reconcileConnections()
    }

    func deleteConnection(connectionID: String) {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else { return }
        connections.remove(at: index)
        persistConnections()
        reconcileConnections()
    }

    func updateConnection(
        connectionID: String,
        name: String,
        host: String,
        port: String,
        colorHex: String
    ) {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else { return }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = port.trimmingCharacters(in: .whitespacesAndNewlines).filter(\.isNumber)
        guard !trimmedName.isEmpty, !trimmedHost.isEmpty, !digits.isEmpty else { return }

        connections[index].name = trimmedName
        connections[index].host = trimmedHost
        connections[index].port = digits
        connections[index].colorHex = normalizedHexColor(colorHex)
        persistConnections()
        reconcileConnections()
    }

    func setConnectionColor(_ colorHex: String, connectionID: String) {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else { return }
        let normalized = normalizedHexColor(colorHex)
        guard connections[index].colorHex != normalized else { return }
        connections[index].colorHex = normalized
        persistConnections()
        recomputeDerivedState()
    }

    func availableModels(for selectedMergedThreadID: String?) -> [AppServerModelOption] {
        targetContext(for: selectedMergedThreadID)?.server.availableModels ?? []
    }

    func availableModels(connectionID: String) -> [AppServerModelOption] {
        guard let connection = connections.first(where: { $0.id == connectionID }),
              connection.isEnabled,
              let server = serversByConnectionID[connectionID] else {
            return []
        }
        return server.availableModels
    }

    func canStartTask(for selectedMergedThreadID: String?) -> Bool {
        guard let target = targetContext(for: selectedMergedThreadID) else { return false }
        return target.server.state == .connected && !target.server.isSubmittingTask
    }

    func canStartTask(connectionID: String) -> Bool {
        guard let connection = connections.first(where: { $0.id == connectionID }),
              connection.isEnabled,
              let server = serversByConnectionID[connectionID] else {
            return false
        }
        return server.state == .connected && !server.isSubmittingTask
    }

    func isTargetSubmittingTask(for selectedMergedThreadID: String?) -> Bool {
        targetContext(for: selectedMergedThreadID)?.server.isSubmittingTask ?? false
    }

    func isSubmittingTask(connectionID: String) -> Bool {
        guard let connection = connections.first(where: { $0.id == connectionID }),
              connection.isEnabled,
              let server = serversByConnectionID[connectionID] else {
            return false
        }
        return server.isSubmittingTask
    }

    func selectedThreadTitle(for selectedMergedThreadID: String?) -> String {
        guard let selectedMergedThreadID else {
            return "New thread"
        }

        if let thread = mergedThreads.first(where: { $0.id == selectedMergedThreadID }) {
            return thread.title
        }

        if let resolved = resolvedSelectedThreadContext(for: selectedMergedThreadID),
           let thread = resolved.server.threads.first(where: { $0.id == resolved.rawThreadID }) {
            return thread.title
        }

        if let parsed = parseMergedThreadID(selectedMergedThreadID) {
            return "Thread \(parsed.rawThreadID.prefix(8))"
        }

        return "New thread"
    }

    func activityEntries(for selectedMergedThreadID: String?) -> [ActivityEntry] {
        guard
            let selectedMergedThreadID,
            let resolved = resolvedSelectedThreadContext(for: selectedMergedThreadID)
        else {
            return []
        }

        return resolved.server.activity.filter { entry in
            entry.threadID == nil || entry.threadID == resolved.rawThreadID
        }
    }

    func loadThreadHistory(for mergedThreadID: String) {
        guard
            let resolved = resolvedSelectedThreadContext(for: mergedThreadID),
            let connection = connections.first(where: { $0.id == resolved.connection.id }),
            connection.isEnabled,
            let server = serversByConnectionID[resolved.connection.id]
        else {
            return
        }
        server.loadThreadHistory(threadID: resolved.rawThreadID)
    }

    @discardableResult
    func startTask(
        prompt: String,
        selectedMergedThreadID: String?,
        model: String?,
        effort: String?
    ) -> Bool {
        guard let target = targetContext(for: selectedMergedThreadID) else { return false }
        return target.server.startTask(
            prompt: prompt,
            threadID: target.rawThreadID,
            model: model,
            effort: effort
        )
    }

    @discardableResult
    func startTaskInProject(
        prompt: String,
        connectionID: String,
        cwd: String,
        model: String?,
        effort: String?
    ) -> Bool {
        guard let connection = connections.first(where: { $0.id == connectionID }),
              connection.isEnabled,
              let server = serversByConnectionID[connectionID] else {
            return false
        }

        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCwd.isEmpty else { return false }

        return server.startTask(
            prompt: prompt,
            threadID: nil,
            model: model,
            effort: effort,
            cwd: trimmedCwd
        )
    }

    func knownProjectFolders(connectionID: String) -> [String] {
        guard let server = serversByConnectionID[connectionID] else { return [] }
        var seen: Set<String> = []
        var folders: [String] = []

        let sortedThreads = server.threads.sorted { $0.updatedAt > $1.updatedAt }
        for thread in sortedThreads {
            let trimmed = thread.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                folders.append(trimmed)
            }
        }

        return folders
    }

    func listRemoteFolders(
        connectionID: String,
        cwd: String?,
        completion: @escaping (_ basePath: String?, _ folders: [String], _ errorMessage: String?) -> Void
    ) {
        guard let connection = connections.first(where: { $0.id == connectionID }) else {
            completion(nil, [], "Connection not found.")
            return
        }
        guard connection.isEnabled else {
            completion(nil, [], "Connection is disabled. Enable it in Settings first.")
            return
        }
        guard let server = serversByConnectionID[connectionID] else {
            completion(nil, [], "Connection server is unavailable.")
            return
        }
        guard server.state == .connected else {
            completion(nil, [], "Connection is not connected yet.")
            return
        }

        server.listDirectories(cwd: cwd) { basePath, folders, errorMessage in
            completion(basePath, folders, errorMessage)
        }
    }

    func createThread(
        connectionID: String,
        cwd: String,
        completion: @escaping (_ mergedThreadID: String?, _ errorMessage: String?) -> Void
    ) {
        guard let connection = connections.first(where: { $0.id == connectionID }) else {
            completion(nil, "Connection not found.")
            return
        }
        guard connection.isEnabled else {
            completion(nil, "Connection is disabled. Enable it in Settings first.")
            return
        }
        guard let server = serversByConnectionID[connectionID] else {
            completion(nil, "Connection server is unavailable.")
            return
        }

        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCwd.isEmpty else {
            completion(nil, "Choose a folder path first.")
            return
        }

        server.createThread(cwd: trimmedCwd) { [weak self] rawThreadID, errorMessage in
            guard let self else { return }
            if let rawThreadID {
                self.recomputeDerivedState()
                completion(self.mergedThreadID(connectionID: connectionID, rawThreadID: rawThreadID), nil)
            } else {
                completion(nil, errorMessage ?? "Failed to create thread.")
            }
        }
    }

    var connectionSummaryLabel: String {
        if enabledCount == 0 {
            return "No Connections Enabled"
        }
        return "\(connectedEnabledCount)/\(enabledCount) Connected"
    }

    private func targetContext(
        for selectedMergedThreadID: String?
    ) -> (connection: SavedAppServerConnection, server: AppServerConnection, rawThreadID: String?)? {
        if
            let selectedMergedThreadID,
            let resolved = resolvedSelectedThreadContext(for: selectedMergedThreadID)
        {
            return (resolved.connection, resolved.server, resolved.rawThreadID)
        }

        let enabledConnections = connections.filter(\.isEnabled)
        if
            let connectedConnection = enabledConnections.first(where: { connection in
                serversByConnectionID[connection.id]?.state == .connected
            }),
            let connectedServer = serversByConnectionID[connectedConnection.id]
        {
            return (connectedConnection, connectedServer, nil)
        }

        if
            let fallbackConnection = enabledConnections.first,
            let fallbackServer = serversByConnectionID[fallbackConnection.id]
        {
            return (fallbackConnection, fallbackServer, nil)
        }

        return nil
    }

    private func resolvedSelectedThreadContext(
        for mergedThreadID: String
    ) -> (connection: SavedAppServerConnection, server: AppServerConnection, rawThreadID: String)? {
        if
            let lookup = mergedThreadLookup[mergedThreadID],
            let connection = connections.first(where: { $0.id == lookup.connectionID }),
            connection.isEnabled,
            let server = serversByConnectionID[lookup.connectionID]
        {
            return (connection, server, lookup.rawThreadID)
        }

        guard
            let parsed = parseMergedThreadID(mergedThreadID),
            let connection = connections.first(where: { $0.id == parsed.connectionID }),
            connection.isEnabled,
            let server = serversByConnectionID[parsed.connectionID]
        else {
            return nil
        }

        return (connection, server, parsed.rawThreadID)
    }

    private func mergedThreadID(connectionID: String, rawThreadID: String) -> String {
        "\(connectionID)::\(rawThreadID)"
    }

    private func parseMergedThreadID(_ mergedThreadID: String) -> (connectionID: String, rawThreadID: String)? {
        guard let separatorRange = mergedThreadID.range(of: "::") else { return nil }
        let connectionID = String(mergedThreadID[..<separatorRange.lowerBound])
        let rawThreadID = String(mergedThreadID[separatorRange.upperBound...])
        guard !connectionID.isEmpty, !rawThreadID.isEmpty else { return nil }
        return (connectionID, rawThreadID)
    }

    private func observe(server: AppServerConnection, connectionID: String) {
        serverChangeSubscriptions[connectionID] = server.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.recomputeDerivedState()
            }
        }

        latestTaskStartCountByConnectionID[connectionID] = server.taskStartSuccessCount
        taskStartCountSubscriptions[connectionID] = server.$taskStartSuccessCount.sink { [weak self] newValue in
            DispatchQueue.main.async {
                self?.handleTaskStartCountUpdate(newValue, connectionID: connectionID)
            }
        }
    }

    private func handleTaskStartCountUpdate(_ newValue: Int, connectionID: String) {
        let previous = latestTaskStartCountByConnectionID[connectionID] ?? newValue
        if newValue > previous {
            taskStartSuccessCount += (newValue - previous)
        }
        latestTaskStartCountByConnectionID[connectionID] = newValue
        recomputeDerivedState()
    }

    private func reconcileConnections() {
        let activeConnectionIDs = Set(connections.map(\.id))

        let staleConnectionIDs = serversByConnectionID.keys.filter { !activeConnectionIDs.contains($0) }
        for connectionID in staleConnectionIDs {
            serversByConnectionID[connectionID]?.disconnect()
            serversByConnectionID.removeValue(forKey: connectionID)
            serverChangeSubscriptions.removeValue(forKey: connectionID)?.cancel()
            taskStartCountSubscriptions.removeValue(forKey: connectionID)?.cancel()
            latestTaskStartCountByConnectionID.removeValue(forKey: connectionID)
        }

        for connection in connections {
            let server: AppServerConnection
            if let existing = serversByConnectionID[connection.id] {
                server = existing
            } else {
                let created = AppServerConnection()
                serversByConnectionID[connection.id] = created
                observe(server: created, connectionID: connection.id)
                server = created
            }

            let targetURL = connection.urlString
            let urlChanged = server.serverURLString != targetURL
            if urlChanged {
                server.serverURLString = targetURL
            }

            if connection.isEnabled {
                if urlChanged {
                    if server.state != .disconnected {
                        server.disconnect()
                    }
                    server.connect()
                } else if server.state == .disconnected || server.state == .failed {
                    server.connect()
                }
            } else if server.state != .disconnected {
                server.disconnect()
            }
        }

        recomputeDerivedState()
    }

    private func recomputeDerivedState() {
        var updatedStatuses: [ConnectionStatus] = []
        var updatedMergedThreads: [MergedAppThread] = []
        var updatedMergedRunningTasks: [MergedRunningTask] = []
        var updatedThreadLookup: [String: (connectionID: String, rawThreadID: String)] = [:]
        var enabledCount = 0
        var connectedCount = 0

        for connection in connections {
            let server = serversByConnectionID[connection.id]
            let serverState = server?.state ?? .disconnected
            if connection.isEnabled {
                enabledCount += 1
                if serverState == .connected {
                    connectedCount += 1
                }
            }

            updatedStatuses.append(
                ConnectionStatus(
                    id: connection.id,
                    name: connection.name,
                    host: connection.normalizedHost,
                    port: connection.normalizedPort,
                    isEnabled: connection.isEnabled,
                    colorHex: connection.colorHex,
                    state: serverState
                )
            )

            guard connection.isEnabled, let server else { continue }

            for thread in server.threads {
                let mergedID = mergedThreadID(connectionID: connection.id, rawThreadID: thread.id)
                updatedThreadLookup[mergedID] = (connection.id, thread.id)
                updatedMergedThreads.append(
                    MergedAppThread(
                        id: mergedID,
                        connectionID: connection.id,
                        connectionName: connection.name,
                        connectionColorHex: connection.colorHex,
                        thread: thread
                    )
                )
            }

            for task in server.runningTasks {
                updatedMergedRunningTasks.append(
                    MergedRunningTask(
                        id: "\(connection.id)::\(task.id)",
                        connectionID: connection.id,
                        connectionName: connection.name,
                        mergedThreadID: mergedThreadID(connectionID: connection.id, rawThreadID: task.threadID),
                        task: task
                    )
                )
            }
        }

        updatedMergedThreads.sort { $0.updatedAt > $1.updatedAt }
        updatedMergedRunningTasks.sort { $0.startedAt > $1.startedAt }

        connectionStatuses = updatedStatuses
        mergedThreadLookup = updatedThreadLookup
        mergedThreads = updatedMergedThreads
        mergedRunningTasks = updatedMergedRunningTasks
        self.enabledCount = enabledCount
        connectedEnabledCount = connectedCount
    }

    private func loadSavedConnections() {
        let defaults = UserDefaults.standard

        if
            let encoded = defaults.string(forKey: savedConnectionsKey),
            let data = encoded.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([SavedAppServerConnection].self, from: data),
            !decoded.isEmpty
        {
            connections = decoded
            return
        }

        connections = [migratedDefaultConnection(from: defaults)]
        persistConnections()
    }

    private func persistConnections() {
        guard let data = try? JSONEncoder().encode(connections),
              let encoded = String(data: data, encoding: .utf8) else {
            return
        }
        UserDefaults.standard.set(encoded, forKey: savedConnectionsKey)
    }

    private func migratedDefaultConnection(from defaults: UserDefaults) -> SavedAppServerConnection {
        var host = defaults.string(forKey: legacyHostKey) ?? "127.0.0.1"
        var port = defaults.string(forKey: legacyPortKey) ?? "9281"

        if let savedURL = defaults.string(forKey: legacyURLKey),
           let parsed = hostAndPort(from: savedURL) {
            host = parsed.host
            port = parsed.port
        }

        return SavedAppServerConnection(
            name: "Local",
            host: host,
            port: port,
            isEnabled: true
        )
    }

    private func hostAndPort(from rawURL: String) -> (host: String, port: String)? {
        var normalized = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if !normalized.contains("://") {
            normalized = "ws://\(normalized)"
        }
        guard let components = URLComponents(string: normalized),
              let host = components.host,
              !host.isEmpty
        else {
            return nil
        }
        let parsedPort = components.port.map(String.init) ?? "9281"
        return (host, parsedPort)
    }
}

struct ContentView: View {
    private struct ConnectedProject: Identifiable, Hashable {
        let id: String
        let connectionID: String
        let projectPath: String
    }

    @StateObject private var connectionStore = MultiAppServerConnectionStore()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedThreadID: String?
    @State private var selectedProjectID: String?
    @State private var connectedProjects: [ConnectedProject] = []
    @State private var didConfigureInitialVisibility = false
    @State private var isConnectProjectWizardPresented = false
    @State private var connectProjectStep: ConnectProjectWizardStep = .connection
    @State private var connectProjectConnectionID: String?
    @State private var connectProjectSelectedFolderPath: String?
    @State private var connectProjectManualFolderPath = ""
    @State private var connectProjectBrowsePath: String?
    @State private var connectProjectRemoteFolders: [String] = []
    @State private var connectProjectIsLoadingFolders = false
    @State private var connectProjectFolderLoadGeneration = 0
    @State private var connectProjectIsCreating = false
    @State private var connectProjectErrorMessage: String?
    @State private var isSettingsPresented = false
    @State private var selectedSettingsSection: SettingsSection? = .connections
    @State private var isAddConnectionPresented = false
    @State private var draftConnectionName = ""
    @State private var draftConnectionHost = "127.0.0.1"
    @State private var draftConnectionPort = "9281"
    @State private var draftConnectionColor = colorFromHex(SavedAppServerConnection.defaultColorHex)
    @State private var isEditConnectionPresented = false
    @State private var editConnectionID: String?
    @State private var editConnectionName = ""
    @State private var editConnectionHost = "127.0.0.1"
    @State private var editConnectionPort = "9281"
    @State private var editConnectionColor = colorFromHex(SavedAppServerConnection.defaultColorHex)
    @State private var pendingDeleteConnectionID: String?
    @State private var pendingDeleteConnectionName = ""
    @State private var newTaskPrompt = ""
    @State private var selectedModelOverride = ""
    @State private var selectedEffortOverride = ""
    @State private var shouldScrollConversationToBottomOnNextUpdate = true
    @State private var isConversationBottomVisible = true
    @State private var isRunningTasksExpanded = true

    private let conversationBottomAnchorID = "conversation-bottom-anchor"

    private struct ComposerChoice: Identifiable, Hashable {
        let id: String
        let label: String
        let value: String?
    }

    private struct ProjectSection: Identifiable {
        let id: String
        let connectionID: String
        let projectPath: String
        let title: String
        let subtitle: String?
        let connectionName: String
        let connectionColorHex: String
        let threads: [MergedAppThread]
        let latestUpdatedAt: Date
    }

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case connections

        var id: String { rawValue }

        var title: String {
            switch self {
            case .connections:
                return "Connections"
            }
        }

        var systemImage: String {
            switch self {
            case .connections:
                return "point.3.connected.trianglepath.dotted"
            }
        }
    }

    private enum ConnectProjectWizardStep {
        case connection
        case folder
    }

    private var trimmedTaskPrompt: String {
        newTaskPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var connectionStatusByID: [String: ConnectionStatus] {
        Dictionary(uniqueKeysWithValues: connectionStore.connectionStatuses.map { ($0.id, $0) })
    }

    private var selectedProjectContext: ConnectedProject? {
        guard let selectedProjectID else { return nil }
        if let explicit = connectedProjects.first(where: { $0.id == selectedProjectID }) {
            return explicit
        }
        guard let parsed = parseProjectSelectionID(selectedProjectID) else { return nil }
        return ConnectedProject(
            id: selectedProjectID,
            connectionID: parsed.connectionID,
            projectPath: parsed.projectPath
        )
    }

    private var selectedProjectConnectionID: String? {
        selectedProjectContext?.connectionID
    }

    private var selectedProjectPath: String? {
        selectedProjectContext?.projectPath
    }

    private var activeModelOptions: [AppServerModelOption] {
        if let selectedThreadID {
            return connectionStore.availableModels(for: selectedThreadID)
        }
        if let connectionID = selectedProjectConnectionID {
            return connectionStore.availableModels(connectionID: connectionID)
        }
        return []
    }

    private var defaultModelOption: AppServerModelOption? {
        activeModelOptions.first(where: \.isDefault) ?? activeModelOptions.first
    }

    private var defaultModelLabel: String {
        defaultModelOption?.displayName ?? "Server Default"
    }

    private var modelChoices: [ComposerChoice] {
        var choices = [ComposerChoice(id: "model-default", label: "Default (\(defaultModelLabel))", value: nil)]
        choices.append(
            contentsOf: activeModelOptions.map { model in
                ComposerChoice(id: "model-\(model.id)", label: model.displayName, value: model.model)
            }
        )
        return choices
    }

    private var selectedModelOption: AppServerModelOption? {
        if let selectedModelValue {
            return activeModelOptions.first(where: { $0.model == selectedModelValue })
        }
        return defaultModelOption
    }

    private var defaultReasoningLabel: String {
        guard let selectedModelOption else { return "Default Reasoning" }
        guard !selectedModelOption.defaultReasoningEffort.isEmpty else { return "Default Reasoning" }
        return "Default (\(reasoningLabel(for: selectedModelOption.defaultReasoningEffort)))"
    }

    private var effortChoices: [ComposerChoice] {
        var choices = [ComposerChoice(id: "effort-default", label: defaultReasoningLabel, value: nil)]
        guard let selectedModelOption else { return choices }

        var seenEfforts = Set<String>()
        for option in selectedModelOption.supportedReasoningEfforts {
            if !seenEfforts.insert(option.reasoningEffort).inserted {
                continue
            }
            choices.append(
                ComposerChoice(
                    id: "effort-\(option.id)",
                    label: reasoningLabel(for: option.reasoningEffort),
                    value: option.reasoningEffort
                )
            )
        }
        return choices
    }

    private var selectedModelValue: String? {
        guard !selectedModelOverride.isEmpty else { return nil }
        guard activeModelOptions.contains(where: { $0.model == selectedModelOverride }) else {
            return nil
        }
        return selectedModelOverride
    }

    private var selectedEffortValue: String? {
        guard !selectedEffortOverride.isEmpty else { return nil }
        guard effortChoices.contains(where: { $0.value == selectedEffortOverride }) else {
            return nil
        }
        return selectedEffortOverride
    }

    private var selectedModelLabel: String {
        if let selectedModelValue {
            return modelChoices.first(where: { $0.value == selectedModelValue })?.label ?? selectedModelValue
        }
        return defaultModelLabel
    }

    private var selectedEffortLabel: String {
        if let selectedEffortValue {
            return effortChoices.first(where: { $0.value == selectedEffortValue })?.label ?? selectedEffortValue
        }
        guard let selectedModelOption,
              !selectedModelOption.defaultReasoningEffort.isEmpty else {
            return "Reasoning"
        }
        return reasoningLabel(for: selectedModelOption.defaultReasoningEffort)
    }

    private var canStartTask: Bool {
        guard !trimmedTaskPrompt.isEmpty else { return false }
        if let selectedThreadID {
            return connectionStore.canStartTask(for: selectedThreadID)
        }
        if let connectionID = selectedProjectConnectionID,
           let selectedProjectPath,
           selectedProjectPath != "__unknown_project__" {
            return connectionStore.canStartTask(connectionID: connectionID)
        }
        return false
    }

    private var selectedThreadTitle: String {
        if let selectedThreadID {
            return connectionStore.selectedThreadTitle(for: selectedThreadID)
        }
        if let selectedProjectContext {
            return projectTitle(for: selectedProjectContext.projectPath)
        }
        return "New thread"
    }

    private var visibleActivity: [ActivityEntry] {
        connectionStore.activityEntries(for: selectedThreadID)
    }

    private var inlineRunningTasks: [MergedRunningTask] {
        guard let selectedThreadID else { return [] }
        return connectionStore.mergedRunningTasks.filter { $0.mergedThreadID == selectedThreadID }
    }

    private var connectProjectAvailableConnections: [ConnectionStatus] {
        connectionStore.connectionStatuses
    }

    private var selectedConnectProjectConnection: ConnectionStatus? {
        guard let connectProjectConnectionID else { return nil }
        return connectProjectAvailableConnections.first(where: { $0.id == connectProjectConnectionID })
    }

    private var connectProjectKnownFolders: [String] {
        guard let connectProjectConnectionID else { return [] }
        return connectionStore.knownProjectFolders(connectionID: connectProjectConnectionID)
    }

    private var connectProjectFolderOptions: [String] {
        var seen = Set<String>()
        var merged: [String] = []

        for folder in connectProjectRemoteFolders {
            let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                merged.append(trimmed)
            }
        }

        for folder in connectProjectKnownFolders {
            let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                merged.append(trimmed)
            }
        }

        return merged
    }

    private var connectProjectParentBrowsePath: String? {
        guard let browsePath = connectProjectBrowsePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !browsePath.isEmpty,
              browsePath != "/" else {
            return nil
        }

        let nsPath = (browsePath as NSString).deletingLastPathComponent
        if nsPath.isEmpty {
            return "/"
        }
        if nsPath == browsePath {
            return nil
        }
        return nsPath
    }

    private var trimmedConnectProjectManualFolderPath: String {
        connectProjectManualFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var connectProjectResolvedFolderPath: String? {
        if !trimmedConnectProjectManualFolderPath.isEmpty {
            return trimmedConnectProjectManualFolderPath
        }
        return connectProjectSelectedFolderPath?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canContinueConnectProjectWizard: Bool {
        guard let connection = selectedConnectProjectConnection else { return false }
        return connection.isEnabled
    }

    private var canCreateProjectThread: Bool {
        guard let connection = selectedConnectProjectConnection else { return false }
        guard connection.isEnabled else { return false }
        guard connection.state == .connected else { return false }
        guard let path = connectProjectResolvedFolderPath, !path.isEmpty else { return false }
        return !connectProjectIsCreating
    }

    private var visibleActivityScrollToken: Int {
        var hasher = Hasher()
        hasher.combine(selectedThreadID)
        for entry in visibleActivity {
            hasher.combine(entry.id)
            hasher.combine(entry.text.count)
            hasher.combine(entry.imageURLs.count)
            hasher.combine(entry.localImagePaths.count)
        }
        for task in inlineRunningTasks {
            hasher.combine(task.id)
            hasher.combine(task.name)
            hasher.combine(task.type)
            hasher.combine(task.startedAt.timeIntervalSince1970)
        }
        return hasher.finalize()
    }

    private var projectSections: [ProjectSection] {
        var groupedThreads: [String: [MergedAppThread]] = [:]
        var groupOrder: [String] = []

        func ensureGroup(_ key: String) {
            if groupedThreads[key] == nil {
                groupedThreads[key] = []
                groupOrder.append(key)
            }
        }

        for project in connectedProjects {
            ensureGroup(project.id)
        }

        for thread in connectionStore.mergedThreads {
            let groupKey = projectSelectionID(connectionID: thread.connectionID, projectPath: canonicalProjectPath(thread.cwd))
            ensureGroup(groupKey)
            groupedThreads[groupKey, default: []].append(thread)
        }

        var titleCounts: [String: Int] = [:]
        for key in groupOrder {
            guard let parsed = parseProjectSelectionID(key) else { continue }
            let title = projectTitle(for: parsed.projectPath)
            titleCounts["\(parsed.connectionID)::\(title)", default: 0] += 1
        }

        return groupOrder.compactMap { key in
            guard let parsed = parseProjectSelectionID(key),
                  let connectionStatus = connectionStatusByID[parsed.connectionID] else {
                return nil
            }

            let threads = (groupedThreads[key] ?? []).sorted { $0.updatedAt > $1.updatedAt }
            let title = projectTitle(for: parsed.projectPath)
            let titleKey = "\(parsed.connectionID)::\(title)"
            let subtitle: String?
            if parsed.projectPath == "__unknown_project__" {
                subtitle = nil
            } else if (titleCounts[titleKey] ?? 0) > 1 {
                subtitle = parsed.projectPath
            } else {
                subtitle = nil
            }

            return ProjectSection(
                id: key,
                connectionID: parsed.connectionID,
                projectPath: parsed.projectPath,
                title: title,
                subtitle: subtitle,
                connectionName: connectionStatus.name,
                connectionColorHex: connectionStatus.colorHex,
                threads: threads,
                latestUpdatedAt: threads.first?.updatedAt ?? .distantPast
            )
        }
    }

    private var runningThreadIDs: Set<String> {
        Set(connectionStore.mergedRunningTasks.map(\.mergedThreadID))
    }

    private var activeModelIDs: [String] {
        activeModelOptions.map(\.model)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
        } detail: {
            detailColumn
        }
        .onAppear(perform: configureInitialSidebarVisibility)
        .onChange(of: inlineRunningTasks.map(\.id)) { _, taskIDs in
            if !taskIDs.isEmpty {
                isRunningTasksExpanded = true
            }
        }
        .onChange(of: connectionStore.mergedThreads.map(\.id)) { _, threadIDs in
            if let selectedThreadID, !threadIDs.contains(selectedThreadID) {
                self.selectedThreadID = nil
            }
        }
        .onChange(of: connectionStore.connectionStatuses.map(\.id)) { _, connectionIDs in
            let validConnectionIDs = Set(connectionIDs)
            connectedProjects.removeAll { !validConnectionIDs.contains($0.connectionID) }
            if let selectedProjectID,
               let parsed = parseProjectSelectionID(selectedProjectID),
               !validConnectionIDs.contains(parsed.connectionID) {
                self.selectedProjectID = nil
            }
        }
        .onChange(of: connectionStore.taskStartSuccessCount) { _, _ in
            newTaskPrompt = ""
            if selectedThreadID == nil {
                if let selectedProjectID,
                   let matchingThread = connectionStore.mergedThreads.first(where: { thread in
                       projectSelectionID(connectionID: thread.connectionID, projectPath: canonicalProjectPath(thread.cwd)) == selectedProjectID
                   }) {
                    selectedThreadID = matchingThread.id
                } else {
                    selectedThreadID = connectionStore.mergedThreads.first?.id
                }
            }
        }
        .onChange(of: activeModelIDs) { _, models in
            if !selectedModelOverride.isEmpty && !models.contains(selectedModelOverride) {
                selectedModelOverride = ""
            }
            if !selectedEffortOverride.isEmpty && !effortChoices.contains(where: { $0.value == selectedEffortOverride }) {
                selectedEffortOverride = ""
            }
        }
        .onChange(of: selectedModelOverride) { _, _ in
            if !selectedEffortOverride.isEmpty && !effortChoices.contains(where: { $0.value == selectedEffortOverride }) {
                selectedEffortOverride = ""
            }
        }
        .onChange(of: selectedThreadID) { _, threadID in
            shouldScrollConversationToBottomOnNextUpdate = true
            if threadID != nil {
                selectedProjectID = nil
            }
            guard let threadID else { return }
            connectionStore.loadThreadHistory(for: threadID)
        }
        .sheet(isPresented: $isConnectProjectWizardPresented) {
            connectProjectWizard
        }
        .sheet(isPresented: $isSettingsPresented) {
            settingsModal
        }
    }

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                presentConnectProjectWizard()
            } label: {
                Label("Connect project", systemImage: "square.and.pencil")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Divider()
                .padding(.vertical, 10)

            HStack {
                Text("Threads")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)

            List(selection: $selectedThreadID) {
                ForEach(projectSections) { section in
                    Section {
                        Button {
                            selectedProjectID = section.id
                            selectedThreadID = nil
                            shouldScrollConversationToBottomOnNextUpdate = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.bubble")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(section.threads.isEmpty ? "No threads yet" : "Start new thread")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            (selectedThreadID == nil && selectedProjectID == section.id)
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                        )

                        ForEach(section.threads) { thread in
                            let isRunning = runningThreadIDs.contains(thread.id)
                            HStack(alignment: .center, spacing: 10) {
                                Group {
                                    if isRunning {
                                        ProgressView()
                                            .progressViewStyle(.circular)
                                            .controlSize(.small)
                                    } else {
                                        Color.clear
                                    }
                                }
                                .frame(width: 12, height: 12)

                                Text(thread.title)
                                    .font(.subheadline)
                                    .lineLimit(1)

                                Spacer(minLength: 6)

                                Text(thread.updatedAtText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .tag(thread.id)
                        }
                    } header: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(section.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(section.connectionName)
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(colorFromHex(section.connectionColorHex))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(colorFromHex(section.connectionColorHex).opacity(0.14))
                                )
                            if let subtitle = section.subtitle {
                                Text("•")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .textCase(nil)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            Button {
                selectedSettingsSection = .connections
                isSettingsPresented = true
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .navigationTitle("schema-agent")
    }

    private var detailColumn: some View {
        VStack(spacing: 0) {
            threadHeader
            Divider()
            conversationView
            Divider()
            composer
        }
    }

    private var threadHeader: some View {
        HStack(spacing: 10) {
            Text(selectedThreadTitle)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Text(connectionStore.connectionSummaryLabel)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    (connectionStore.connectedEnabledCount > 0 ? Color.green : Color.gray).opacity(0.15),
                    in: Capsule()
                )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var connectProjectWizard: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connect Project")
                            .font(.title3.weight(.semibold))
                        Text(connectProjectStep == .connection ? "Step 1 of 2: Select connection" : "Step 2 of 2: Select folder")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        dismissConnectProjectWizard()
                    } label: {
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

                Group {
                    switch connectProjectStep {
                    case .connection:
                        connectProjectConnectionStep
                    case .folder:
                        connectProjectFolderStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Divider()

                HStack(spacing: 10) {
                    Button("Cancel") {
                        dismissConnectProjectWizard()
                    }
                    .buttonStyle(.bordered)

                    if connectProjectStep == .folder {
                        Button("Back") {
                            connectProjectErrorMessage = nil
                            connectProjectStep = .connection
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    if connectProjectStep == .connection {
                        Button("Next") {
                            connectProjectErrorMessage = nil
                            connectProjectStep = .folder
                            loadConnectProjectFolders(cwd: nil)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canContinueConnectProjectWizard)
                    } else {
                        Button {
                            createProjectFromWizard()
                        } label: {
                            if connectProjectIsCreating {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Add Project")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canCreateProjectThread)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .frame(minWidth: 640, minHeight: 520)
        }
    }

    private var connectProjectConnectionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose which connection this project should use.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if connectProjectAvailableConnections.isEmpty {
                Text("No connections configured yet. Add one in Settings first.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(connectProjectAvailableConnections) { connection in
                            connectProjectConnectionRow(connection)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if let connection = selectedConnectProjectConnection, !connection.isEnabled {
                Text("This connection is disabled. Enable it in Settings before continuing.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func connectProjectConnectionRow(_ connection: ConnectionStatus) -> some View {
        let isSelected = connectProjectConnectionID == connection.id
        return Button {
            connectProjectConnectionID = connection.id
            connectProjectManualFolderPath = ""
            connectProjectSelectedFolderPath = nil
            connectProjectBrowsePath = nil
            connectProjectRemoteFolders = []
            connectProjectErrorMessage = nil
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(connection.name)
                            .font(.headline)
                        Text(connection.stateLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(connectionStatusColor(connection.state))
                    }

                    Text("\(connection.host):\(connection.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !connection.isEnabled {
                    Text("Disabled")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.12))
                        )
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.16), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var connectProjectFolderStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let selectedConnectProjectConnection {
                Text("Choose a folder for \(selectedConnectProjectConnection.name).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Choose a folder.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Browsing")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(connectProjectBrowsePath ?? "Resolving current folder...")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if connectProjectIsLoadingFolders {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    loadConnectProjectFolders(cwd: connectProjectBrowsePath)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(connectProjectIsLoadingFolders || connectProjectConnectionID == nil)

                if let parentPath = connectProjectParentBrowsePath {
                    Button {
                        loadConnectProjectFolders(cwd: parentPath)
                    } label: {
                        Image(systemName: "arrow.up.left")
                    }
                    .buttonStyle(.borderless)
                    .disabled(connectProjectIsLoadingFolders)
                }
            }

            if connectProjectFolderOptions.isEmpty {
                Text(connectProjectIsLoadingFolders
                     ? "Loading folders..."
                     : "No folders found in this location. You can still enter a full folder path below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            } else {
                Text("Folders")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(connectProjectFolderOptions, id: \.self) { folderPath in
                            HStack(spacing: 8) {
                                Button {
                                    connectProjectSelectedFolderPath = folderPath
                                    connectProjectManualFolderPath = ""
                                    connectProjectErrorMessage = nil
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: connectProjectSelectedFolderPath == folderPath ? "checkmark.circle.fill" : "folder")
                                            .foregroundStyle(connectProjectSelectedFolderPath == folderPath ? Color.accentColor : Color.secondary)
                                        Text(folderPath)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    loadConnectProjectFolders(cwd: folderPath)
                                } label: {
                                    Image(systemName: "chevron.right.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open folder")
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(connectProjectSelectedFolderPath == folderPath ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06))
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 220)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Folder Path")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("/absolute/path/to/project", text: $connectProjectManualFolderPath)
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
                    #endif
                    .onChange(of: connectProjectManualFolderPath) { _, newValue in
                        if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            connectProjectSelectedFolderPath = nil
                        }
                    }
            }

            if let connectProjectErrorMessage, !connectProjectErrorMessage.isEmpty {
                Text(connectProjectErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let connection = selectedConnectProjectConnection, connection.state != .connected {
                Text("Connection is currently \(connection.stateLabel.lowercased()). Wait until it is connected to add this project.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .onAppear {
            if connectProjectFolderOptions.isEmpty && !connectProjectIsLoadingFolders {
                loadConnectProjectFolders(cwd: connectProjectBrowsePath)
            }
        }
    }

    private var settingsModal: some View {
        NavigationStack {
            HStack(spacing: 0) {
                settingsSidebar
                    .frame(width: 220)

                Divider()

                Group {
                    switch selectedSettingsSection ?? .connections {
                    case .connections:
                        connectionsSettings
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        isSettingsPresented = false
                    }
                }
            }
        }
        .frame(minWidth: 780, minHeight: 500)
    }

    private var settingsSidebar: some View {
        List(SettingsSection.allCases, selection: $selectedSettingsSection) { section in
            Label(section.title, systemImage: section.systemImage)
                .tag(section)
        }
        .listStyle(.sidebar)
    }

    private var connectionsSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Connections")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button {
                        presentAddConnectionSheet()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }

                Text("All enabled websocket connections auto-connect on launch.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if connectionStore.connectionStatuses.isEmpty {
                    Text("No connections configured yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 10)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(connectionStore.connectionStatuses) { connection in
                            connectionCard(for: connection)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .sheet(isPresented: $isAddConnectionPresented) {
            addConnectionSheet
        }
        .sheet(isPresented: $isEditConnectionPresented) {
            editConnectionSheet
        }
        .confirmationDialog(
            "Delete Connection",
            isPresented: Binding(
                get: { pendingDeleteConnectionID != nil },
                set: { isPresented in
                    if !isPresented {
                        clearPendingConnectionDeletion()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete \"\(pendingDeleteConnectionName)\"", role: .destructive) {
                guard let connectionID = pendingDeleteConnectionID else { return }
                connectionStore.deleteConnection(connectionID: connectionID)
                clearPendingConnectionDeletion()
            }
            Button("Cancel", role: .cancel) {
                clearPendingConnectionDeletion()
            }
        } message: {
            Text("This removes the saved connection from Schema Agent.")
        }
    }

    private func connectionCard(for connection: ConnectionStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(connection.name)
                    .font(.headline)
                Spacer()
                Toggle(isOn: Binding(
                    get: { connection.isEnabled },
                    set: { isEnabled in
                        connectionStore.setConnectionEnabled(isEnabled, connectionID: connection.id)
                    }
                )) {
                    Text(connection.isEnabled ? "Enabled" : "Disabled")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)

                Button {
                    presentEditConnectionSheet(connection)
                } label: {
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

                Button(role: .destructive) {
                    pendingDeleteConnectionID = connection.id
                    pendingDeleteConnectionName = connection.name
                } label: {
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
                ColorPicker(
                    "",
                    selection: Binding(
                        get: { colorFromHex(connection.colorHex) },
                        set: { newColor in
                            connectionStore.setConnectionColor(
                                hexString(from: newColor),
                                connectionID: connection.id
                            )
                        }
                    )
                )
                .labelsHidden()
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(connectionStatusColor(connection.state))
                    .frame(width: 8, height: 8)
                Text(connection.stateLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(connectionStatusColor(connection.state))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var addConnectionSheet: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add Connection")
                        .font(.title3.weight(.semibold))
                    Text("Add a websocket endpoint for merged thread data.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    isAddConnectionPresented = false
                } label: {
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
                addConnectionField(
                    title: "Name",
                    placeholder: "Remote",
                    text: $draftConnectionName
                )
                addConnectionField(
                    title: "IP Address",
                    placeholder: "127.0.0.1",
                    text: $draftConnectionHost
                )
                addConnectionField(
                    title: "Port",
                    placeholder: "9281",
                    text: $draftConnectionPort,
                    numericOnly: true
                )

                HStack(spacing: 10) {
                    Text("Color")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ColorPicker("", selection: $draftConnectionColor)
                        .labelsHidden()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Spacer(minLength: 0)

            Divider()

            HStack(spacing: 10) {
                Spacer()

                Button("Cancel") {
                    isAddConnectionPresented = false
                }
                .buttonStyle(.bordered)

                Button("Add") {
                    connectionStore.addConnection(
                        name: draftConnectionName,
                        host: normalizedDraftConnectionHost,
                        port: normalizedDraftConnectionPort,
                        colorHex: hexString(from: draftConnectionColor)
                    )
                    isAddConnectionPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAddDraftConnection)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 500, minHeight: 360)
    }

    private var editConnectionSheet: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Edit Connection")
                        .font(.title3.weight(.semibold))
                    Text("Update websocket endpoint settings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    clearEditConnectionDraft()
                } label: {
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
                addConnectionField(
                    title: "Name",
                    placeholder: "Remote",
                    text: $editConnectionName
                )
                addConnectionField(
                    title: "IP Address",
                    placeholder: "127.0.0.1",
                    text: $editConnectionHost
                )
                addConnectionField(
                    title: "Port",
                    placeholder: "9281",
                    text: $editConnectionPort,
                    numericOnly: true
                )

                HStack(spacing: 10) {
                    Text("Color")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ColorPicker("", selection: $editConnectionColor)
                        .labelsHidden()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Spacer(minLength: 0)

            Divider()

            HStack(spacing: 10) {
                Spacer()

                Button("Cancel") {
                    clearEditConnectionDraft()
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    guard let connectionID = editConnectionID else { return }
                    connectionStore.updateConnection(
                        connectionID: connectionID,
                        name: editConnectionName,
                        host: normalizedEditConnectionHost,
                        port: normalizedEditConnectionPort,
                        colorHex: hexString(from: editConnectionColor)
                    )
                    clearEditConnectionDraft()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSaveEditedConnection)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 500, minHeight: 360)
    }

    private func addConnectionField(
        title: String,
        placeholder: String,
        text: Binding<String>,
        numericOnly: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: text)
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
                .onChange(of: text.wrappedValue) { _, newValue in
                    guard numericOnly else { return }
                    let digits = newValue.filter(\.isNumber)
                    if digits != newValue {
                        text.wrappedValue = digits
                    }
                }
        }
    }

    private var conversationView: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if !inlineRunningTasks.isEmpty {
                            inlineRunningTasksCard
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
                                activityRow(for: entry)
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
            .onAppear {
                shouldScrollConversationToBottomOnNextUpdate = true
                scrollConversationToBottom(using: scrollProxy, animated: false)
            }
            .onChange(of: visibleActivityScrollToken) { _, _ in
                guard !visibleActivity.isEmpty || !inlineRunningTasks.isEmpty else { return }
                if shouldScrollConversationToBottomOnNextUpdate {
                    scrollConversationToBottom(using: scrollProxy, animated: false)
                    shouldScrollConversationToBottomOnNextUpdate = false
                    return
                }
                if isConversationBottomVisible {
                    scrollConversationToBottom(using: scrollProxy, animated: true)
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $newTaskPrompt)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 86, maxHeight: 140)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)

                    if newTaskPrompt.isEmpty {
                        Text("Ask for follow-up changes")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }

                HStack(spacing: 8) {
                    Menu {
                        ForEach(modelChoices) { choice in
                            Button {
                                selectedModelOverride = choice.value ?? ""
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
                    .disabled(activeModelOptions.isEmpty)

                    Menu {
                        ForEach(effortChoices) { choice in
                            Button {
                                selectedEffortOverride = choice.value ?? ""
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
                    .disabled(activeModelOptions.isEmpty)

                    Spacer()

                    if selectedThreadID != nil {
                        if connectionStore.isTargetSubmittingTask(for: selectedThreadID) {
                            ProgressView()
                                .controlSize(.small)
                        }
                    } else if let selectedProjectConnectionID,
                              connectionStore.isSubmittingTask(connectionID: selectedProjectConnectionID) {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button {
                        if let selectedThreadID {
                            _ = connectionStore.startTask(
                                prompt: newTaskPrompt,
                                selectedMergedThreadID: selectedThreadID,
                                model: selectedModelValue,
                                effort: selectedEffortValue
                            )
                        } else if let selectedProjectContext,
                                  selectedProjectContext.projectPath != "__unknown_project__" {
                            _ = connectionStore.startTaskInProject(
                                prompt: newTaskPrompt,
                                connectionID: selectedProjectContext.connectionID,
                                cwd: selectedProjectContext.projectPath,
                                model: selectedModelValue,
                                effort: selectedEffortValue
                            )
                        }
                    } label: {
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
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.secondary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    )
            )

            HStack {
                if let selectedThreadID {
                    Text("Continuing selected thread")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let selectedProjectContext {
                    Text("New thread in \(projectTitle(for: selectedProjectContext.projectPath))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Select a project to start a new thread")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

    private func newThreadLanding(context: ConnectedProject) -> some View {
        let title = projectTitle(for: context.projectPath)
        let connectionName = connectionStatusByID[context.connectionID]?.name ?? context.connectionID
        let projectSubtitle: String = {
            if context.projectPath == "__unknown_project__" {
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

    private func scrollConversationToBottom(using scrollProxy: ScrollViewProxy, animated _: Bool) {
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                scrollProxy.scrollTo(conversationBottomAnchorID, anchor: .bottom)
            }
        }
    }

    private func reasoningLabel(for reasoningEffort: String) -> String {
        switch reasoningEffort {
        case "none":
            return "No Reasoning"
        case "minimal":
            return "Minimal"
        case "low":
            return "Low"
        case "medium":
            return "Medium"
        case "high":
            return "High"
        case "xhigh":
            return "Extra High"
        default:
            return reasoningEffort.capitalized
        }
    }

    private func activityRow(for entry: ActivityEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if entry.kind != .assistant {
                Text(label(for: entry.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !entry.text.isEmpty {
                markdownText(entry.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !entry.imageURLs.isEmpty || !entry.localImagePaths.isEmpty {
                attachmentStrip(for: entry)
            }
        }
        .padding(rowPadding(for: entry.kind))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(for: entry.kind), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(rowStroke(for: entry.kind), lineWidth: rowStroke(for: entry.kind) == .clear ? 0 : 1)
        )
    }

    private var inlineRunningTasksCard: some View {
        DisclosureGroup(isExpanded: $isRunningTasksExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(inlineRunningTasks) { task in
                    inlineRunningTaskRow(task)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(inlineRunningTasks.count == 1 ? "1 running task" : "\(inlineRunningTasks.count) running tasks")
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

    private func inlineRunningTaskRow(_ task: MergedRunningTask) -> some View {
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

    private func attachmentStrip(for entry: ActivityEntry) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(entry.imageURLs.enumerated()), id: \.offset) { _, url in
                    attachmentPreview(remoteURLString: url)
                }
                ForEach(Array(entry.localImagePaths.enumerated()), id: \.offset) { _, path in
                    attachmentPreview(localPath: path)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private struct MarkdownRenderBlock: Identifiable {
        enum Kind {
            case paragraph(String)
            case heading(level: Int, text: String)
            case unordered(String)
            case ordered(number: String, text: String)
            case quote(String)
            case divider
            case code(language: String?, code: String)
        }

        let id = UUID()
        let kind: Kind
    }

    @ViewBuilder
    private func markdownText(_ source: String) -> some View {
        let blocks = markdownBlocks(from: source)
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

    private func markdownBlocks(from source: String) -> [MarkdownRenderBlock] {
        var blocks: [MarkdownRenderBlock] = []
        var proseLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCodeFence = false

        func flushProse() {
            let prose = proseLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            proseLines.removeAll()
            guard !prose.isEmpty else { return }
            blocks.append(MarkdownRenderBlock(kind: .paragraph(prose)))
        }

        func flushCode() {
            let code = codeLines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            codeLines.removeAll()
            guard !code.isEmpty else {
                codeLanguage = nil
                return
            }
            blocks.append(MarkdownRenderBlock(kind: .code(language: codeLanguage, code: code)))
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
            } else {
                let fullyTrimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

                if fullyTrimmed.isEmpty {
                    flushProse()
                    continue
                }

                if isMarkdownDivider(fullyTrimmed) {
                    flushProse()
                    blocks.append(MarkdownRenderBlock(kind: .divider))
                    continue
                }

                if let heading = parseHeading(from: line) {
                    flushProse()
                    blocks.append(MarkdownRenderBlock(kind: .heading(level: heading.level, text: heading.text)))
                    continue
                }

                if let ordered = parseOrderedItem(from: line) {
                    flushProse()
                    blocks.append(MarkdownRenderBlock(kind: .ordered(number: ordered.number, text: ordered.text)))
                    continue
                }

                if let unordered = parseUnorderedItem(from: line) {
                    flushProse()
                    blocks.append(MarkdownRenderBlock(kind: .unordered(unordered)))
                    continue
                }

                if let quote = parseQuote(from: line) {
                    flushProse()
                    blocks.append(MarkdownRenderBlock(kind: .quote(quote)))
                    continue
                }

                proseLines.append(line)
            }
        }

        if inCodeFence {
            flushCode()
        }
        flushProse()

        if blocks.isEmpty {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                blocks.append(MarkdownRenderBlock(kind: .paragraph(trimmed)))
            }
        }

        return blocks
    }

    private func markdownInlineText(_ source: String) -> Text {
        if let attributed = markdownAttributedString(from: source) {
            return Text(attributed)
        }
        return Text(source)
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

    private func parseHeading(from line: String) -> (level: Int, text: String)? {
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

    private func parseUnorderedItem(from line: String) -> String? {
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

    private func parseOrderedItem(from line: String) -> (number: String, text: String)? {
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

    private func parseQuote(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(">") else { return nil }
        let body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }

    private func isMarkdownDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        let first = compact.first ?? "-"
        guard first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
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

    private func markdownAttributedString(from source: String) -> AttributedString? {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return try? AttributedString(markdown: source, options: options)
    }

    @ViewBuilder
    private func attachmentPreview(remoteURLString: String) -> some View {
        if let image = imageFromDataURI(remoteURLString) {
            platformImageView(image)
        } else if let remoteURL = URL(string: remoteURLString), remoteURL.scheme != nil {
            AsyncImage(url: remoteURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure(_):
                    attachmentPlaceholder(title: "Image")
                case .empty:
                    ZStack {
                        attachmentPlaceholder(title: "Loading image")
                        ProgressView()
                    }
                @unknown default:
                    attachmentPlaceholder(title: "Image")
                }
            }
            .frame(width: 180, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            attachmentPlaceholder(title: "Image")
        }
    }

    @ViewBuilder
    private func attachmentPreview(localPath: String) -> some View {
        if let image = imageFromFile(path: localPath) {
            platformImageView(image)
        } else {
            attachmentPlaceholder(title: URL(fileURLWithPath: localPath).lastPathComponent)
        }
    }

    private func attachmentPlaceholder(title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "photo")
            Text(title)
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .frame(width: 180, height: 120)
        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func platformImageView(_ image: PlatformImage) -> some View {
        #if os(iOS)
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 180, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        #else
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 180, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        #endif
    }

    private func imageFromDataURI(_ value: String) -> PlatformImage? {
        guard value.hasPrefix("data:image/") else { return nil }
        guard let commaIndex = value.firstIndex(of: ",") else { return nil }
        let meta = String(value[..<commaIndex]).lowercased()
        guard meta.contains(";base64") else { return nil }
        let encoded = String(value[value.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]) else { return nil }
        #if os(iOS)
        return UIImage(data: data)
        #else
        return NSImage(data: data)
        #endif
    }

    private func imageFromFile(path: String) -> PlatformImage? {
        #if os(iOS)
        return UIImage(contentsOfFile: path)
        #else
        return NSImage(contentsOfFile: path)
        #endif
    }

    private func configureInitialSidebarVisibility() {
        guard !didConfigureInitialVisibility else { return }
        didConfigureInitialVisibility = true

        if isIPhone {
            columnVisibility = .detailOnly
        } else {
            columnVisibility = .all
        }
    }

    private func presentConnectProjectWizard() {
        connectProjectStep = .connection
        connectProjectIsCreating = false
        connectProjectIsLoadingFolders = false
        connectProjectErrorMessage = nil
        connectProjectManualFolderPath = ""
        connectProjectBrowsePath = nil
        connectProjectRemoteFolders = []
        connectProjectFolderLoadGeneration = 0

        let preferredConnection = connectionStore.connectionStatuses.first(where: { $0.isEnabled && $0.state == .connected })
            ?? connectionStore.connectionStatuses.first(where: \.isEnabled)
            ?? connectionStore.connectionStatuses.first

        connectProjectConnectionID = preferredConnection?.id
        connectProjectSelectedFolderPath = nil

        isConnectProjectWizardPresented = true
    }

    private func dismissConnectProjectWizard() {
        isConnectProjectWizardPresented = false
        connectProjectStep = .connection
        connectProjectIsCreating = false
        connectProjectIsLoadingFolders = false
        connectProjectErrorMessage = nil
        connectProjectManualFolderPath = ""
        connectProjectBrowsePath = nil
        connectProjectRemoteFolders = []
        connectProjectFolderLoadGeneration = 0
        connectProjectSelectedFolderPath = nil
    }

    private func loadConnectProjectFolders(cwd: String?) {
        guard let connectionID = connectProjectConnectionID else {
            connectProjectErrorMessage = "Choose a connection first."
            return
        }

        connectProjectFolderLoadGeneration += 1
        let loadGeneration = connectProjectFolderLoadGeneration
        let expectedConnectionID = connectionID
        connectProjectIsLoadingFolders = true
        connectProjectErrorMessage = nil

        connectionStore.listRemoteFolders(connectionID: connectionID, cwd: cwd) { basePath, folders, errorMessage in
            guard connectProjectFolderLoadGeneration == loadGeneration else { return }
            guard connectProjectConnectionID == expectedConnectionID else { return }

            connectProjectIsLoadingFolders = false
            if let basePath, !basePath.isEmpty {
                connectProjectBrowsePath = basePath
            } else if let cwd, !cwd.isEmpty {
                connectProjectBrowsePath = cwd
            }
            connectProjectRemoteFolders = folders

            if let errorMessage, !errorMessage.isEmpty {
                connectProjectErrorMessage = errorMessage
            } else {
                connectProjectErrorMessage = nil
            }

            if trimmedConnectProjectManualFolderPath.isEmpty {
                if let selected = connectProjectSelectedFolderPath,
                   connectProjectFolderOptions.contains(selected) {
                    // Keep prior selection when still visible.
                } else {
                    connectProjectSelectedFolderPath = connectProjectFolderOptions.first
                }
            }
        }
    }

    private func createProjectFromWizard() {
        guard let connectionID = connectProjectConnectionID else {
            connectProjectErrorMessage = "Choose a connection first."
            return
        }
        guard let folderPath = connectProjectResolvedFolderPath, !folderPath.isEmpty else {
            connectProjectErrorMessage = "Choose a folder path first."
            return
        }

        connectProjectIsCreating = true
        connectProjectErrorMessage = nil

        let normalizedPath = canonicalProjectPath(folderPath)
        let projectID = projectSelectionID(connectionID: connectionID, projectPath: normalizedPath)

        if !connectedProjects.contains(where: { $0.id == projectID }) {
            connectedProjects.insert(
                ConnectedProject(
                    id: projectID,
                    connectionID: connectionID,
                    projectPath: normalizedPath
                ),
                at: 0
            )
        }

        selectedProjectID = projectID
        selectedThreadID = nil
        shouldScrollConversationToBottomOnNextUpdate = true
        connectProjectIsCreating = false
        dismissConnectProjectWizard()
    }

    private func presentAddConnectionSheet() {
        draftConnectionName = ""
        draftConnectionHost = "127.0.0.1"
        draftConnectionPort = "9281"
        draftConnectionColor = colorFromHex(SavedAppServerConnection.defaultColorHex)
        isAddConnectionPresented = true
    }

    private func presentEditConnectionSheet(_ connection: ConnectionStatus) {
        editConnectionID = connection.id
        editConnectionName = connection.name
        editConnectionHost = connection.host
        editConnectionPort = connection.port
        editConnectionColor = colorFromHex(connection.colorHex)
        isEditConnectionPresented = true
    }

    private func clearEditConnectionDraft() {
        isEditConnectionPresented = false
        editConnectionID = nil
        editConnectionName = ""
        editConnectionHost = "127.0.0.1"
        editConnectionPort = "9281"
        editConnectionColor = colorFromHex(SavedAppServerConnection.defaultColorHex)
    }

    private func clearPendingConnectionDeletion() {
        pendingDeleteConnectionID = nil
        pendingDeleteConnectionName = ""
    }

    private var normalizedDraftConnectionHost: String {
        let trimmed = draftConnectionHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "127.0.0.1" : trimmed
    }

    private var normalizedDraftConnectionPort: String {
        let digits = draftConnectionPort.trimmingCharacters(in: .whitespacesAndNewlines).filter(\.isNumber)
        return digits.isEmpty ? "9281" : digits
    }

    private var normalizedEditConnectionHost: String {
        let trimmed = editConnectionHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "127.0.0.1" : trimmed
    }

    private var normalizedEditConnectionPort: String {
        let digits = editConnectionPort.trimmingCharacters(in: .whitespacesAndNewlines).filter(\.isNumber)
        return digits.isEmpty ? "9281" : digits
    }

    private var canAddDraftConnection: Bool {
        let trimmedName = draftConnectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = draftConnectionHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty && !trimmedHost.isEmpty && !normalizedDraftConnectionPort.isEmpty
    }

    private var canSaveEditedConnection: Bool {
        guard editConnectionID != nil else { return false }
        let trimmedName = editConnectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = editConnectionHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty && !trimmedHost.isEmpty && !normalizedEditConnectionPort.isEmpty
    }

    private func connectionStatusColor(_ state: AppServerConnectionState) -> Color {
        switch state {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .failed:
            return .red
        case .disconnected:
            return .secondary
        }
    }

    private func canonicalProjectPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "__unknown_project__" }
        if trimmed == "__unknown_project__" { return trimmed }
        let standardized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        if standardized.isEmpty { return "__unknown_project__" }
        return standardized
    }

    private func projectSelectionID(connectionID: String, projectPath: String) -> String {
        "\(connectionID)::\(canonicalProjectPath(projectPath))"
    }

    private func parseProjectSelectionID(_ value: String) -> (connectionID: String, projectPath: String)? {
        guard let separator = value.range(of: "::") else { return nil }
        let connectionID = String(value[..<separator.lowerBound])
        let projectPath = String(value[separator.upperBound...])
        guard !connectionID.isEmpty, !projectPath.isEmpty else { return nil }
        return (connectionID, projectPath)
    }

    private func projectTitle(for projectPath: String) -> String {
        guard projectPath != "__unknown_project__" else { return "Unknown Project" }
        let normalized = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Unknown Project" }
        let url = URL(fileURLWithPath: normalized)
        let basename = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return basename.isEmpty ? normalized : basename
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
        case .assistant:
            return 0
        case .system:
            return 0
        case .user:
            return 14
        }
    }

    private var isIPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
