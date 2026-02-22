import Foundation

enum ConnectionStorePersistence {
    static let savedConnectionsKey = "savedAppServerConnectionsV1"
    static let legacyURLKey = "preferredAppServerURL"
    static let legacyHostKey = "preferredConnectionIPAddress"
    static let legacyPortKey = "preferredConnectionPort"

    static func load(defaults: UserDefaults = .standard) -> [SavedAppServerConnection] {
        if
            let encoded = defaults.string(forKey: savedConnectionsKey),
            let data = encoded.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([SavedAppServerConnection].self, from: data),
            !decoded.isEmpty
        {
            return decoded
        }

        let migrated = migratedDefaultConnection(from: defaults)
        save([migrated], defaults: defaults)
        return [migrated]
    }

    static func save(_ connections: [SavedAppServerConnection], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(connections),
              let encoded = String(data: data, encoding: .utf8) else {
            return
        }
        defaults.set(encoded, forKey: savedConnectionsKey)
    }

    static func migratedDefaultConnection(from defaults: UserDefaults) -> SavedAppServerConnection {
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

    static func hostAndPort(from rawURL: String) -> (host: String, port: String)? {
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
