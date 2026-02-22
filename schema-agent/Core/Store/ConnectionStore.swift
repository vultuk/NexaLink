import Foundation
import Combine

final class MultiAppServerConnectionStore: ObservableObject {
    @Published private(set) var connections: [SavedAppServerConnection] = []
    @Published private(set) var connectionStatuses: [ConnectionStatus] = []
    @Published private(set) var mergedThreads: [MergedAppThread] = []
    @Published private(set) var mergedRunningTasks: [MergedRunningTask] = []
    @Published private(set) var taskStartSuccessCount = 0
    @Published private(set) var connectedEnabledCount = 0
    @Published private(set) var enabledCount = 0
    @Published private(set) var activityChangeCounter = 0

    private var serversByConnectionID: [String: AppServerConnection] = [:]
    private var serverDerivedStateSubscriptions: [String: AnyCancellable] = [:]
    private var activitySubscriptions: [String: AnyCancellable] = [:]
    private var taskStartCountSubscriptions: [String: AnyCancellable] = [:]
    private var latestTaskStartCountByConnectionID: [String: Int] = [:]
    private var latestObservedStateByConnectionID: [String: AppServerConnectionState] = [:]
    private var mergedThreadLookup: [String: (connectionID: String, rawThreadID: String)] = [:]
    private var isRecomputeScheduled = false

    init() {
        loadSavedConnections()
        reconcileConnections()
    }

    deinit {
        for server in serversByConnectionID.values {
            server.disconnect()
        }
        serverDerivedStateSubscriptions.values.forEach { $0.cancel() }
        activitySubscriptions.values.forEach { $0.cancel() }
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
        scheduleRecomputeDerivedState()
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

    func availableCollaborationModes(for selectedMergedThreadID: String?) -> [AppServerCollaborationModeOption] {
        targetContext(for: selectedMergedThreadID)?.server.availableCollaborationModes ?? []
    }

    func availableCollaborationModes(connectionID: String) -> [AppServerCollaborationModeOption] {
        guard let connection = connections.first(where: { $0.id == connectionID }),
              connection.isEnabled,
              let server = serversByConnectionID[connectionID] else {
            return []
        }
        return server.availableCollaborationModes
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

    func archiveThread(
        mergedThreadID: String,
        completion: @escaping (_ success: Bool, _ errorMessage: String?) -> Void
    ) {
        guard
            let resolved = resolvedSelectedThreadContext(for: mergedThreadID),
            let connection = connections.first(where: { $0.id == resolved.connection.id }),
            connection.isEnabled,
            let server = serversByConnectionID[resolved.connection.id]
        else {
            completion(false, "Thread is unavailable.")
            return
        }

        server.archiveThread(threadID: resolved.rawThreadID) { success, errorMessage in
            completion(success, errorMessage)
        }
    }

    @discardableResult
    func startTask(
        prompt: String,
        selectedMergedThreadID: String?,
        model: String?,
        effort: String?,
        collaborationMode: AppServerCollaborationModeSelection?
    ) -> Bool {
        guard let target = targetContext(for: selectedMergedThreadID) else { return false }
        return target.server.startTask(
            prompt: prompt,
            threadID: target.rawThreadID,
            model: model,
            effort: effort,
            collaborationMode: collaborationMode
        )
    }

    @discardableResult
    func startTaskInProject(
        prompt: String,
        connectionID: String,
        cwd: String,
        model: String?,
        effort: String?,
        collaborationMode: AppServerCollaborationModeSelection?
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
            collaborationMode: collaborationMode,
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
        let statePublisher = server.$state.map { _ in () }.eraseToAnyPublisher()
        let threadsPublisher = server.$threads.map { _ in () }.eraseToAnyPublisher()
        let runningTasksPublisher = server.$runningTasks.map { _ in () }.eraseToAnyPublisher()
        let submittingPublisher = server.$isSubmittingTask.map { _ in () }.eraseToAnyPublisher()
        let modelsPublisher = server.$availableModels.map { _ in () }.eraseToAnyPublisher()
        let collaborationModesPublisher = server.$availableCollaborationModes.map { _ in () }.eraseToAnyPublisher()

        serverDerivedStateSubscriptions[connectionID] = Publishers.MergeMany(
            statePublisher,
            threadsPublisher,
            runningTasksPublisher,
            submittingPublisher,
            modelsPublisher,
            collaborationModesPublisher
        )
        .sink { [weak self] _ in
            guard let self else { return }
            let newState = server.state
            self.latestObservedStateByConnectionID[connectionID] = newState
            self.scheduleRecomputeDerivedState()
        }

        activitySubscriptions[connectionID] = server.$activity.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.activityChangeCounter &+= 1
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
        scheduleRecomputeDerivedState()
    }

    private func reconcileConnections() {
        let activeConnectionIDs = Set(connections.map(\.id))

        let staleConnectionIDs = serversByConnectionID.keys.filter { !activeConnectionIDs.contains($0) }
        for connectionID in staleConnectionIDs {
            serversByConnectionID[connectionID]?.disconnect()
            serversByConnectionID.removeValue(forKey: connectionID)
            serverDerivedStateSubscriptions.removeValue(forKey: connectionID)?.cancel()
            activitySubscriptions.removeValue(forKey: connectionID)?.cancel()
            taskStartCountSubscriptions.removeValue(forKey: connectionID)?.cancel()
            latestTaskStartCountByConnectionID.removeValue(forKey: connectionID)
            latestObservedStateByConnectionID.removeValue(forKey: connectionID)
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

            latestObservedStateByConnectionID[connection.id] = server.state

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

        scheduleRecomputeDerivedState()
    }

    private func scheduleRecomputeDerivedState() {
        guard !isRecomputeScheduled else { return }
        isRecomputeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRecomputeScheduled = false
            self.recomputeDerivedState()
        }
    }

    private func recomputeDerivedState() {
        let derivedState = ConnectionStoreDerivedStateBuilder.build(
            connections: connections,
            serversByConnectionID: serversByConnectionID,
            mergedThreadID: { connectionID, rawThreadID in
                self.mergedThreadID(connectionID: connectionID, rawThreadID: rawThreadID)
            }
        )

        if connectionStatuses != derivedState.statuses {
            connectionStatuses = derivedState.statuses
        }
        mergedThreadLookup = derivedState.mergedThreadLookup
        if mergedThreads != derivedState.mergedThreads {
            mergedThreads = derivedState.mergedThreads
        }
        if mergedRunningTasks != derivedState.mergedRunningTasks {
            mergedRunningTasks = derivedState.mergedRunningTasks
        }
        if self.enabledCount != derivedState.enabledCount {
            self.enabledCount = derivedState.enabledCount
        }
        if connectedEnabledCount != derivedState.connectedEnabledCount {
            connectedEnabledCount = derivedState.connectedEnabledCount
        }
    }

    private func loadSavedConnections() {
        connections = ConnectionStorePersistence.load()
    }

    private func persistConnections() {
        ConnectionStorePersistence.save(connections)
    }
}
