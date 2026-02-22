import Foundation

struct ConnectionStoreDerivedState {
    let statuses: [ConnectionStatus]
    let mergedThreads: [MergedAppThread]
    let mergedRunningTasks: [MergedRunningTask]
    let mergedThreadLookup: [String: (connectionID: String, rawThreadID: String)]
    let enabledCount: Int
    let connectedEnabledCount: Int
}

enum ConnectionStoreDerivedStateBuilder {
    static func build(
        connections: [SavedAppServerConnection],
        serversByConnectionID: [String: AppServerConnection],
        mergedThreadID: (_ connectionID: String, _ rawThreadID: String) -> String
    ) -> ConnectionStoreDerivedState {
        var statuses: [ConnectionStatus] = []
        var mergedThreads: [MergedAppThread] = []
        var mergedRunningTasks: [MergedRunningTask] = []
        var mergedThreadLookup: [String: (connectionID: String, rawThreadID: String)] = [:]
        var enabledCount = 0
        var connectedEnabledCount = 0

        for connection in connections {
            let server = serversByConnectionID[connection.id]
            let serverState = server?.state ?? .disconnected
            if connection.isEnabled {
                enabledCount += 1
                if serverState == .connected {
                    connectedEnabledCount += 1
                }
            }

            statuses.append(
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
                let mergedID = mergedThreadID(connection.id, thread.id)
                mergedThreadLookup[mergedID] = (connection.id, thread.id)
                mergedThreads.append(
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
                mergedRunningTasks.append(
                    MergedRunningTask(
                        id: "\(connection.id)::\(task.id)",
                        connectionID: connection.id,
                        connectionName: connection.name,
                        mergedThreadID: mergedThreadID(connection.id, task.threadID),
                        task: task
                    )
                )
            }
        }

        mergedThreads.sort { $0.updatedAt > $1.updatedAt }
        mergedRunningTasks.sort { $0.startedAt > $1.startedAt }

        return ConnectionStoreDerivedState(
            statuses: statuses,
            mergedThreads: mergedThreads,
            mergedRunningTasks: mergedRunningTasks,
            mergedThreadLookup: mergedThreadLookup,
            enabledCount: enabledCount,
            connectedEnabledCount: connectedEnabledCount
        )
    }
}
