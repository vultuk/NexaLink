import Foundation
import Combine
import Network

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
    @Published private(set) var availableCollaborationModes: [AppServerCollaborationModeOption] = []

    private var connection: NWConnection?
    private let connectionQueue = DispatchQueue(label: "AppServerConnection.Socket")
    private var pendingRequests: [Int: String] = [:]
    private var nextRequestID = 0
    private var queuedMessages: [String] = []
    private var candidateURLs: [URL] = []
    private var currentCandidateIndex = 0
    private var didReceiveInitializeResponse = false
    private var receiveBuffer = Data()
    private var fragmentedMessageOpcode: UInt8?
    private var fragmentedMessageBuffer = Data()
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
    private var threadReadSummaryRequestIDs: Set<Int> = []
    private var threadListRequestContextsByRequestID: [Int: PendingThreadListContext] = [:]
    private var threadListAccumulator: [AppThread] = []
    private var threadListRetryCount = 0
    private let maxThreadListPagesPerRefresh = 0
    private let threadListPageSize = 50
    private var threadArchiveThreadIDByRequestID: [Int: String] = [:]
    private var threadCreateCompletionsByRequestID: [Int: (_ threadID: String?, _ errorMessage: String?) -> Void] = [:]
    private var threadArchiveCompletionsByRequestID: [Int: (_ success: Bool, _ errorMessage: String?) -> Void] = [:]
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
        let collaborationMode: AppServerCollaborationModeSelection?
    }

    private struct PendingThreadResumeContext {
        let prompt: String
        let requestedThreadID: String
        let model: String?
        let effort: String?
        let collaborationMode: AppServerCollaborationModeSelection?
    }

    private struct PendingTurnStartContext {
        let prompt: String
        let threadID: String
    }

    private struct PendingThreadListContext {
        let replace: Bool
        let cursor: String?
        let page: Int
        let includeSortKey: Bool
        let includeAllSourceKinds: Bool
        let minimalParams: Bool
    }

    private enum ThreadListRetryProfile {
        case transportError
        case emptyList

        func delay(forAttempt attempt: Int) -> TimeInterval {
            switch self {
            case .transportError:
                return attempt == 1 ? 0.6 : 1.2
            case .emptyList:
                return attempt == 1 ? 0.8 : 1.6
            }
        }
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
        availableCollaborationModes = []

        connectionQueue.sync {
            self.isUserInitiatedDisconnect = false
            self.teardownConnectionLocked()
            self.clearRequestTrackingLocked(
                clearQueuedMessages: true,
                clearReceiveBuffer: false,
                clearCurrentThreadID: true
            )
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
            self.clearRequestTrackingLocked(
                clearQueuedMessages: true,
                clearReceiveBuffer: false,
                clearCurrentThreadID: true
            )
            self.teardownConnectionLocked()
        }

        runningTasks = []
        availableModels = []
        availableCollaborationModes = []
        isSubmittingTask = false
        if state != .failed {
            state = .disconnected
            statusMessage = "Not connected"
        }
    }

    private func clearRequestTrackingLocked(
        clearQueuedMessages: Bool,
        clearReceiveBuffer: Bool,
        clearCurrentThreadID: Bool
    ) {
        if clearQueuedMessages {
            queuedMessages.removeAll()
        }
        pendingRequests.removeAll()
        didReceiveInitializeResponse = false

        if clearReceiveBuffer {
            receiveBuffer.removeAll()
        }
        fragmentedMessageOpcode = nil
        fragmentedMessageBuffer.removeAll()

        threadStartPromptsByRequestID.removeAll()
        threadResumePromptsByRequestID.removeAll()
        passiveThreadResumeRequestIDs.removeAll()
        turnStartContextsByRequestID.removeAll()
        threadReadThreadIDByRequestID.removeAll()
        threadReadSummaryRequestIDs.removeAll()
        threadListRequestContextsByRequestID.removeAll()
        threadListAccumulator.removeAll()
        threadListRetryCount = 0
        threadArchiveThreadIDByRequestID.removeAll()
        threadCreateCompletionsByRequestID.removeAll()
        threadArchiveCompletionsByRequestID.removeAll()
        commandExecCompletionsByRequestID.removeAll()
        assistantEntryIDByItemID.removeAll()
        modelListAccumulator.removeAll()
        threadIDByTurnID.removeAll()
        threadIDByItemID.removeAll()
        turnIDByItemID.removeAll()
        if clearCurrentThreadID {
            currentThreadID = nil
        }
    }

    @discardableResult
    func startTask(
        prompt: String,
        threadID: String?,
        model: String?,
        effort: String?,
        collaborationMode: AppServerCollaborationModeSelection? = nil,
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
                    effort: effort,
                    collaborationMode: collaborationMode
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
                    effort: effort,
                    collaborationMode: collaborationMode
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

    func refreshThreadList() {
        connectionQueue.async {
            guard self.didReceiveInitializeResponse, self.phaseIsOpenLocked() else { return }
            self.requestThreadListLocked(replace: true, cursor: nil, includeSortKey: false)
        }
    }

    func archiveThread(
        threadID: String,
        completion: @escaping (_ success: Bool, _ errorMessage: String?) -> Void
    ) {
        guard state == .connected else {
            completion(false, "Connection is not ready.")
            return
        }

        let trimmedThreadID = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedThreadID.isEmpty else {
            completion(false, "Thread ID is missing.")
            return
        }

        connectionQueue.async {
            let requestID = self.sendRequestLocked(
                method: "thread/archive",
                params: ["threadId": trimmedThreadID]
            )
            self.threadArchiveThreadIDByRequestID[requestID] = trimmedThreadID
            self.threadArchiveCompletionsByRequestID[requestID] = completion
            DispatchQueue.main.async {
                self.statusMessage = "Archiving thread..."
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

    private func sendInitializeRequestLocked() {
        _ = sendRequestLocked(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "NexaLink",
                    "title": "NexaLink",
                    "version": "0.1.0"
                ],
                "capabilities": [
                    "experimentalApi": true
                ]
            ]
        )
    }

    private func handleIncomingText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var handled = false
        if let data = trimmed.data(using: .utf8) {
            handled = handleIncomingData(data)
        }
        if handled { return }

        for line in text.split(whereSeparator: \.isNewline) {
            let lineText = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lineText.isEmpty, let lineData = lineText.data(using: .utf8) else { continue }
            _ = handleIncomingData(lineData)
        }
    }

    @discardableResult
    private func handleIncomingData(_ data: Data) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let payload = object as? [String: Any]
        else { return false }

        if let method = payload["method"] as? String {
            let params = payload["params"] as? [String: Any] ?? payload
            handleNotification(method: method, params: params)
            return true
        }

        if let id = parseRequestID(payload["id"]) {
            handleResponse(id: id, payload: payload)
            return true
        }

        return false
    }

    private func handleResponse(id: Int, payload: [String: Any]) {
        let method = pendingRequests.removeValue(forKey: id)

        if let error = payload["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "Unknown server error"
            var shouldSkipGenericFailureStatus = false
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
                threadReadSummaryRequestIDs.remove(id)
            } else if method == "thread/list" {
                if let context = threadListRequestContextsByRequestID.removeValue(forKey: id) {
                    if context.cursor != nil && !threadListAccumulator.isEmpty {
                        let fallbackThreads = threadListAccumulator.sorted { $0.updatedAt > $1.updatedAt }
                        threadListAccumulator.removeAll()
                        DispatchQueue.main.async {
                            self.threads = fallbackThreads
                        }
                        shouldSkipGenericFailureStatus = true
                    } else if context.cursor == nil,
                              scheduleThreadListRetryLocked(profile: .transportError) {
                        shouldSkipGenericFailureStatus = true
                    }
                }
            } else if method == "thread/archive" {
                threadArchiveThreadIDByRequestID.removeValue(forKey: id)
                if let completion = threadArchiveCompletionsByRequestID.removeValue(forKey: id) {
                    DispatchQueue.main.async {
                        completion(false, message)
                    }
                }
            } else if method == "model/list" {
                modelListAccumulator.removeAll()
            } else if method == "collaborationMode/list" {
                DispatchQueue.main.async {
                    self.availableCollaborationModes = []
                }
                shouldSkipGenericFailureStatus = true
            } else if method == "command/exec" {
                if let completion = commandExecCompletionsByRequestID.removeValue(forKey: id) {
                    DispatchQueue.main.async {
                        completion(nil, message)
                    }
                }
            }
            if shouldSkipGenericFailureStatus {
                return
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
            didReceiveInitializeResponse = true
            DispatchQueue.main.async {
                self.state = .connected
                self.statusMessage = "Connected (raw WS, \(userAgent))"
            }
            sendNotificationLocked(method: "initialized", params: [:])
            requestThreadListLocked(replace: true, cursor: nil, includeSortKey: false, includeAllSourceKinds: false)
            _ = sendRequestLocked(method: "model/list", params: ["limit": 100, "includeHidden": false])
            _ = sendRequestLocked(method: "collaborationMode/list", params: [:])
        } else if method == "thread/start" {
            handleThreadStartResponse(id: id, payload: payload)
        } else if method == "thread/resume" {
            handleThreadResumeResponse(id: id, payload: payload)
        } else if method == "turn/start" {
            handleTurnStartResponse(id: id, payload: payload)
        } else if method == "thread/list" {
            handleThreadListResponse(id: id, payload: payload)
        } else if method == "thread/read" {
            handleThreadReadResponse(id: id, payload: payload)
        } else if method == "thread/archive" {
            handleThreadArchiveResponse(id: id)
        } else if method == "model/list" {
            handleModelListResponse(payload: payload)
        } else if method == "collaborationMode/list" {
            handleCollaborationModeListResponse(payload: payload)
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
            effort: context.effort,
            collaborationMode: context.collaborationMode
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
            effort: context.effort,
            collaborationMode: context.collaborationMode
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

    private func handleThreadListResponse(id: Int, payload: [String: Any]) {
        let context = threadListRequestContextsByRequestID.removeValue(forKey: id)
        let extracted = extractThreadListPayload(from: payload["result"])
        let rawThreadIDs = extracted.threadIDs
        let rawThreads = extracted.threads

        var parsed = rawThreads.compactMap { raw in
            parseThread(raw) ?? (raw["thread"] as? [String: Any]).flatMap(parseThread)
        }
        let normalizedThreadIDs = normalizedThreadIDs(from: rawThreadIDs)
        if !normalizedThreadIDs.isEmpty {
            let existingByID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
            let placeholders = normalizedThreadIDs.map { threadID in
                existingByID[threadID] ?? AppThread(
                    id: threadID,
                    cwd: "",
                    title: "Thread \(threadID.prefix(8))",
                    subtitle: String(threadID.prefix(8)),
                    updatedAt: .distantPast
                )
            }
            parsed.append(contentsOf: placeholders)
            requestThreadSummariesIfNeededLocked(threadIDs: normalizedThreadIDs)
        }

        parsed = deduplicatedThreads(parsed)
#if DEBUG
        print(
            "NexaLink thread/list parsed objects=\(rawThreads.count) ids=\(normalizedThreadIDs.count) parsed=\(parsed.count) nextCursor=\(extracted.nextCursor ?? "nil") includeSort=\(context?.includeSortKey == true) includeAllSources=\(context?.includeAllSourceKinds == true) minimal=\(context?.minimalParams == true)"
        )
#endif

        guard let context else {
            DispatchQueue.main.async {
                self.threads = parsed
            }
            return
        }

        if context.replace && context.cursor == nil {
            threadListAccumulator.removeAll()
        }

        for thread in parsed {
            if let existingIndex = threadListAccumulator.firstIndex(where: { $0.id == thread.id }) {
                threadListAccumulator[existingIndex] = thread
            } else {
                threadListAccumulator.append(thread)
            }
        }

        if let nextCursor = extracted.nextCursor,
           !nextCursor.isEmpty,
           context.page < maxThreadListPagesPerRefresh {
            requestThreadListLocked(
                replace: context.replace,
                cursor: nextCursor,
                page: context.page + 1,
                includeSortKey: context.includeSortKey,
                includeAllSourceKinds: context.includeAllSourceKinds,
                minimalParams: context.minimalParams
            )
            return
        }

        let finalized = threadListAccumulator.sorted { $0.updatedAt > $1.updatedAt }
        threadListAccumulator.removeAll()
        DispatchQueue.main.async {
            self.threads = finalized
        }

        if finalized.isEmpty, context.replace, context.cursor == nil {
            _ = scheduleThreadListRetryLocked(profile: .emptyList)
        } else if !finalized.isEmpty {
            threadListRetryCount = 0
        }
    }

    private func handleThreadReadResponse(id: Int, payload: [String: Any]) {
        let isSummaryRequest = threadReadSummaryRequestIDs.remove(id) != nil
        let requestedThreadID = threadReadThreadIDByRequestID.removeValue(forKey: id)
        guard
            let result = payload["result"] as? [String: Any],
            let thread = result["thread"] as? [String: Any]
        else {
            if isSummaryRequest { return }
            DispatchQueue.main.async {
                self.statusMessage = "thread/read returned unexpected payload."
            }
            return
        }

        upsertThread(from: thread)
        let threadID = (thread["id"] as? String) ?? requestedThreadID
        guard let threadID else { return }
        guard !isSummaryRequest else { return }

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

    private func handleThreadArchiveResponse(id: Int) {
        let archivedThreadID = threadArchiveThreadIDByRequestID.removeValue(forKey: id)
        if let archivedThreadID {
            removeThreadLocally(threadID: archivedThreadID)
        } else {
            requestThreadList()
        }

        if let completion = threadArchiveCompletionsByRequestID.removeValue(forKey: id) {
            DispatchQueue.main.async {
                completion(true, nil)
            }
        }

        DispatchQueue.main.async {
            self.statusMessage = "Thread archived."
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

    private func handleCollaborationModeListResponse(payload: [String: Any]) {
        guard let result = payload["result"] else { return }
        let parsedModes = parseCollaborationModeOptions(result)
        DispatchQueue.main.async {
            self.availableCollaborationModes = parsedModes
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "thread/started", "thread_started":
            if let thread = params["thread"] as? [String: Any] {
                upsertThread(from: thread)
            }

        case "thread/archived", "thread_archived":
            guard let threadID = stringValue(in: params, keys: ["threadId", "thread_id"]) else { return }
            removeThreadLocally(threadID: threadID)

        case "thread/unarchived", "thread_unarchived":
            requestThreadList()

        case "thread/name/updated", "thread_name_updated":
            guard
                let threadID = stringValue(in: params, keys: ["threadId", "thread_id"]),
                let threadName = stringValue(in: params, keys: ["threadName", "thread_name"])
            else { return }
            handleThreadNameUpdatedEvent(threadID: threadID, threadName: threadName)

        case "item/started", "item_started":
            handleItemStartedEvent(params: params, fallbackThreadID: nil)

        case "item/completed", "item_completed":
            handleItemCompletedEvent(params: params, fallbackThreadID: nil)

        case "item/agentMessage/delta", "agent_message_delta", "agent_message_content_delta":
            handleAgentMessageDeltaEvent(params: params, fallbackThreadID: nil)

        case "agent_message":
            handleAgentMessageEvent(params: params, fallbackThreadID: nil)

        case "turn/started", "turn_started", "task_started":
            handleTurnStartedEvent(params: params, fallbackThreadID: nil)

        case "turn/completed", "turn_complete", "task_complete":
            handleTurnCompletedEvent(params: params, fallbackThreadID: nil)

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
            handleItemStartedEvent(params: normalizedEvent, fallbackThreadID: threadID)

        case "item_completed":
            handleItemCompletedEvent(params: normalizedEvent, fallbackThreadID: threadID)

        case "agent_message_content_delta", "agent_message_delta":
            handleAgentMessageDeltaEvent(params: normalizedEvent, fallbackThreadID: threadID)

        case "agent_message":
            handleAgentMessageEvent(params: normalizedEvent, fallbackThreadID: threadID)

        case "task_started", "turn_started":
            handleTurnStartedEvent(params: normalizedEvent, fallbackThreadID: threadID)

        case "task_complete", "turn_complete":
            handleTurnCompletedEvent(params: normalizedEvent, fallbackThreadID: threadID)

        case "thread_name_updated":
            guard
                let threadID,
                let threadName = stringValue(in: normalizedEvent, keys: ["thread_name", "threadName"])
            else { return }
            handleThreadNameUpdatedEvent(threadID: threadID, threadName: threadName)

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

    private func handleThreadNameUpdatedEvent(threadID: String, threadName: String) {
        DispatchQueue.main.async {
            if let index = self.threads.firstIndex(where: { $0.id == threadID }) {
                self.threads[index].title = threadName
            }
        }
    }

    private func handleItemStartedEvent(params: [String: Any], fallbackThreadID: String?) {
        guard let item = params["item"] as? [String: Any] else { return }

        let turnID = resolveTurnID(in: params, item: item)
        let itemID = stringValue(in: item, keys: ["id", "itemId", "item_id"])
        let resolvedThreadID = resolveThreadID(in: params, item: item) ?? fallbackThreadID
        cacheThreadMappings(threadID: resolvedThreadID, turnID: turnID, itemID: itemID)

        var normalizedParams = params
        if stringValue(in: normalizedParams, keys: ["threadId", "thread_id"]) == nil,
           let resolvedThreadID {
            normalizedParams["threadId"] = resolvedThreadID
        }

        guard let task = runningTask(from: item, params: normalizedParams) else { return }
        DispatchQueue.main.async {
            self.runningTasks.removeAll { $0.id == task.id }
            self.runningTasks.insert(task, at: 0)
        }
        touchThread(threadID: task.threadID)
    }

    private func handleItemCompletedEvent(params: [String: Any], fallbackThreadID: String?) {
        guard
            let item = params["item"] as? [String: Any],
            let itemID = stringValue(in: item, keys: ["id", "itemId", "item_id"])
        else { return }

        let turnID = resolveTurnID(in: params, item: item)
        let resolvedThreadID = resolveThreadID(in: params, item: item) ?? fallbackThreadID
        cacheThreadMappings(threadID: resolvedThreadID, turnID: turnID, itemID: itemID)
        DispatchQueue.main.async {
            self.runningTasks.removeAll { $0.id == itemID }
            self.assistantEntryIDByItemID.removeValue(forKey: itemID)
        }
        if let resolvedThreadID {
            touchThread(threadID: resolvedThreadID)
        }
    }

    private func handleAgentMessageDeltaEvent(params: [String: Any], fallbackThreadID: String?) {
        guard
            let itemID = stringValue(in: params, keys: ["itemId", "item_id"]),
            let delta = stringValue(in: params, keys: ["delta"])
        else { return }

        let turnID = resolveTurnID(in: params, item: nil)
        let resolvedThreadID = resolveThreadID(in: params, item: nil) ?? fallbackThreadID
        cacheThreadMappings(threadID: resolvedThreadID, turnID: turnID, itemID: itemID)
        guard let resolvedThreadID else { return }
        appendAssistantDelta(itemID: itemID, threadID: resolvedThreadID, delta: delta)
        touchThread(threadID: resolvedThreadID)
    }

    private func handleAgentMessageEvent(params: [String: Any], fallbackThreadID: String?) {
        guard let message = stringValue(in: params, keys: ["message", "text"]) else { return }
        guard let resolvedThreadID = resolveThreadID(in: params, item: nil) ?? fallbackThreadID else { return }
        appendActivity(text: message, kind: .assistant, threadID: resolvedThreadID)
        touchThread(threadID: resolvedThreadID)
    }

    private func handleTurnStartedEvent(params: [String: Any], fallbackThreadID: String?) {
        let turn = params["turn"] as? [String: Any]
        guard let turnID = stringValue(in: turn ?? params, keys: ["id", "turnId", "turn_id"]) else { return }

        let resolvedThreadID = resolveThreadID(in: params, item: nil) ?? fallbackThreadID ?? "unknown"
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
    }

    private func handleTurnCompletedEvent(params: [String: Any], fallbackThreadID: String?) {
        let turn = params["turn"] as? [String: Any]
        guard let turnID = stringValue(in: turn ?? params, keys: ["id", "turnId", "turn_id"]) else { return }

        let resolvedThreadID = resolveThreadID(in: params, item: nil) ?? fallbackThreadID
        cacheThreadMappings(threadID: resolvedThreadID, turnID: turnID, itemID: nil)
        DispatchQueue.main.async {
            self.runningTasks.removeAll { $0.id == "turn:\(turnID)" }
            if let resolvedThreadID {
                self.runningTasks.removeAll { $0.threadID == resolvedThreadID }
            }
        }
        appendActivity(text: "Turn completed: \(String(turnID.prefix(8)))", kind: .system, threadID: resolvedThreadID)
        if let message = stringValue(in: params, keys: ["last_agent_message", "lastAgentMessage"]) {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                appendActivity(text: message, kind: .assistant, threadID: resolvedThreadID)
            }
        }
        if let resolvedThreadID {
            touchThread(threadID: resolvedThreadID)
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

    private func boolValue(in dictionary: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = dictionary[key] as? Bool {
                return value
            }
            if let value = dictionary[key] as? NSNumber {
                return value.boolValue
            }
            if let value = dictionary[key] as? String {
                switch value.lowercased() {
                case "true", "1", "yes":
                    return true
                case "false", "0", "no":
                    return false
                default:
                    continue
                }
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

    private func sendTurnStartLocked(
        threadID: String,
        prompt: String,
        model: String?,
        effort: String?,
        collaborationMode: AppServerCollaborationModeSelection?
    ) {
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
        if let collaborationMode {
            var settings: [String: Any] = [
                "model": collaborationMode.model
            ]
            if let reasoningEffort = collaborationMode.reasoningEffort, !reasoningEffort.isEmpty {
                settings["reasoning_effort"] = reasoningEffort
            }
            turnParams["collaborationMode"] = [
                "mode": collaborationMode.mode,
                "settings": settings
            ]
        }
        let requestID = sendRequestLocked(method: "turn/start", params: turnParams)
        turnStartContextsByRequestID[requestID] = PendingTurnStartContext(prompt: prompt, threadID: threadID)
        DispatchQueue.main.async {
            self.statusMessage = "Starting task..."
        }
    }

    private func parseModelOption(_ raw: [String: Any]) -> AppServerModelOption? {
        AppServerConnectionParser.parseModelOption(raw)
    }

    private func deduplicatedModels(_ models: [AppServerModelOption]) -> [AppServerModelOption] {
        AppServerConnectionParser.deduplicatedModels(models)
    }

    private func parseCollaborationModeOptions(_ rawResult: Any) -> [AppServerCollaborationModeOption] {
        AppServerConnectionParser.parseCollaborationModeOptions(rawResult)
    }

    private func parseThread(_ raw: [String: Any]) -> AppThread? {
        AppServerConnectionParser.parseThread(raw)
    }

    private func normalizedThreadIDs(from rawIDs: [String]) -> [String] {
        AppServerConnectionParser.normalizedThreadIDs(from: rawIDs)
    }

    private func extractThreadListPayload(from resultAny: Any?) -> (threads: [[String: Any]], threadIDs: [String], nextCursor: String?) {
        AppServerConnectionParser.extractThreadListPayload(from: resultAny)
    }

    private func requestThreadSummariesIfNeededLocked(threadIDs: [String]) {
        let knownThreadIDs = Set(threads.map(\.id))
        let pendingThreadIDs = Set(threadReadThreadIDByRequestID.values)
        for threadID in threadIDs {
            if knownThreadIDs.contains(threadID) || pendingThreadIDs.contains(threadID) {
                continue
            }
            let requestID = sendRequestLocked(
                method: "thread/read",
                params: [
                    "threadId": threadID,
                    "includeTurns": false
                ]
            )
            threadReadThreadIDByRequestID[requestID] = threadID
            threadReadSummaryRequestIDs.insert(requestID)
        }
    }

    private func deduplicatedThreads(_ threads: [AppThread]) -> [AppThread] {
        AppServerConnectionParser.deduplicatedThreads(threads)
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

    private func requestThreadList() {
        connectionQueue.async {
            self.requestThreadListLocked(
                replace: true,
                cursor: nil,
                page: 0,
                includeSortKey: false,
                includeAllSourceKinds: false
            )
        }
    }

    private func requestThreadListLocked(
        replace: Bool,
        cursor: String?,
        page: Int = 0,
        includeSortKey: Bool,
        includeAllSourceKinds: Bool = false,
        minimalParams: Bool = false
    ) {
        var params: [String: Any] = minimalParams ? [:] : ["limit": threadListPageSize]
        if let cursor, !cursor.isEmpty {
            params["cursor"] = cursor
        }
        if includeSortKey && !minimalParams {
            params["sortKey"] = "updated_at"
        }
        if includeAllSourceKinds && !minimalParams {
            params["sourceKinds"] = [
                "cli",
                "vscode",
                "exec",
                "appServer",
                "subAgent",
                "subAgentReview",
                "subAgentCompact",
                "subAgentThreadSpawn",
                "subAgentOther",
                "unknown"
            ]
        }

        let requestID = sendRequestLocked(method: "thread/list", params: params)
        threadListRequestContextsByRequestID[requestID] = PendingThreadListContext(
            replace: replace,
            cursor: cursor,
            page: page,
            includeSortKey: includeSortKey,
            includeAllSourceKinds: includeAllSourceKinds,
            minimalParams: minimalParams
        )
    }

    @discardableResult
    private func scheduleThreadListRetryLocked(profile: ThreadListRetryProfile) -> Bool {
        guard threadListRetryCount < 2 else { return false }

        threadListRetryCount += 1
        let attempt = threadListRetryCount
        let useMinimalRetry = attempt == 1
        let retryDelay = profile.delay(forAttempt: attempt)
        scheduleThreadListRefreshRetryLocked(
            delay: retryDelay,
            useMinimalRetry: useMinimalRetry
        )
        return true
    }

    private func scheduleThreadListRefreshRetryLocked(
        delay: TimeInterval,
        useMinimalRetry: Bool
    ) {
        let retryIncludeAllSources = !useMinimalRetry
        let retryIncludeSortKey = !useMinimalRetry
        connectionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.didReceiveInitializeResponse, self.phaseIsOpenLocked() else { return }
            self.requestThreadListLocked(
                replace: true,
                cursor: nil,
                includeSortKey: retryIncludeSortKey,
                includeAllSourceKinds: retryIncludeAllSources,
                minimalParams: useMinimalRetry
            )
        }
    }

    private func removeThreadLocally(threadID: String) {
        if currentThreadID == threadID {
            currentThreadID = nil
        }
        threadIDByTurnID = threadIDByTurnID.filter { $0.value != threadID }

        let removedItemIDs = threadIDByItemID.compactMap { key, value -> String? in
            value == threadID ? key : nil
        }
        for itemID in removedItemIDs {
            threadIDByItemID.removeValue(forKey: itemID)
            turnIDByItemID.removeValue(forKey: itemID)
        }

        DispatchQueue.main.async {
            self.threads.removeAll { $0.id == threadID }
            self.runningTasks.removeAll { $0.threadID == threadID }
            self.activity.removeAll { $0.threadID == threadID }
            for itemID in removedItemIDs {
                self.assistantEntryIDByItemID.removeValue(forKey: itemID)
            }
        }
    }

    private func touchThread(threadID: String) {
        DispatchQueue.main.async {
            guard let existingIndex = self.threads.firstIndex(where: { $0.id == threadID }) else { return }
            self.threads[existingIndex].updatedAt = Date()
        }
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
        AppServerConnectionParser.parseUserMessage(content)
    }

    private func sanitizeDisplayText(_ rawText: String) -> String {
        AppServerConnectionParser.sanitizeDisplayText(rawText)
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

        sendPayloadLocked(payload)
        return id
    }

    private func sendRequest(method: String, params: [String: Any]) {
        connectionQueue.async {
            _ = self.sendRequestLocked(method: method, params: params)
        }
    }

    private func sendNotification(method: String, params: [String: Any]?) {
        connectionQueue.async {
            self.sendNotificationLocked(method: method, params: params)
        }
    }

    private func sendNotificationLocked(method: String, params: [String: Any]?) {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]

        if let params {
            payload["params"] = params
        }

        sendPayloadLocked(payload)
    }

    private func sendPayloadLocked(_ payload: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let text = String(data: data, encoding: .utf8)
        else { return }

        let line = text.hasSuffix("\n") ? text : text + "\n"
        guard phaseIsOpenLocked() else {
            queuedMessages.append(line)
            return
        }
        sendFrameLocked(opcode: 0x1, payload: Data(line.utf8))
    }

    private func parseRequestID(_ value: Any?) -> Int? {
        AppServerConnectionParser.parseRequestID(value)
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
        clearRequestTrackingLocked(
            clearQueuedMessages: true,
            clearReceiveBuffer: true,
            clearCurrentThreadID: false
        )
        connectedURL = url
        phase = .connecting
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
            "User-Agent: NexaLink/0.1.0"
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
        }
        sendInitializeRequestLocked()

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
                if frame.fin {
                    if let text = String(data: frame.payload, encoding: .utf8) {
                        handleIncomingText(text)
                    }
                } else {
                    fragmentedMessageOpcode = 0x1
                    fragmentedMessageBuffer = frame.payload
                }
            case 0x0:
                guard let fragmentedOpcode = fragmentedMessageOpcode else { continue }
                fragmentedMessageBuffer.append(frame.payload)
                guard frame.fin else { continue }
                if fragmentedOpcode == 0x1,
                   let text = String(data: fragmentedMessageBuffer, encoding: .utf8) {
                    handleIncomingText(text)
                }
                fragmentedMessageOpcode = nil
                fragmentedMessageBuffer.removeAll(keepingCapacity: true)
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

    private func decodeNextFrameLocked() -> (fin: Bool, opcode: UInt8, payload: Data)? {
        guard receiveBuffer.count >= 2 else { return nil }

        let first = receiveBuffer[0]
        let second = receiveBuffer[1]
        let fin = (first & 0x80) != 0
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

        return (fin, opcode, Data(payload))
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
        fragmentedMessageOpcode = nil
        fragmentedMessageBuffer.removeAll()
        threadReadSummaryRequestIDs.removeAll()
        threadListRequestContextsByRequestID.removeAll()
        threadListAccumulator.removeAll()
        threadListRetryCount = 0
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
