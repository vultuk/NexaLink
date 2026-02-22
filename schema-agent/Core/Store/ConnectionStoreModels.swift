import SwiftUI
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

func normalizedHexColor(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let prefixed = trimmed.hasPrefix("#") ? trimmed : "#\(trimmed)"
    guard prefixed.count == 7 else { return SavedAppServerConnection.defaultColorHex }
    let hex = prefixed.dropFirst()
    guard hex.allSatisfy({ $0.isHexDigit }) else { return SavedAppServerConnection.defaultColorHex }
    return prefixed
}

func colorFromHex(_ hex: String) -> Color {
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

func hexString(from color: Color) -> String {
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
        case ipAddress
        case connectionIPAddress
        case url
        case serverURLString
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let decodedID = (try? container.decode(String.self, forKey: .id))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        id = (decodedID?.isEmpty == false) ? decodedID! : UUID().uuidString

        let decodedName = (try? container.decode(String.self, forKey: .name))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        name = (decodedName?.isEmpty == false) ? decodedName! : "Connection"

        let decodedHost = (try? container.decode(String.self, forKey: .host))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let decodedLegacyIP = (
            (try? container.decode(String.self, forKey: .ipAddress))
                ?? (try? container.decode(String.self, forKey: .connectionIPAddress))
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        let decodedPort = (try? container.decode(String.self, forKey: .port))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var resolvedHost = decodedHost
        var resolvedPort = decodedPort
        if (resolvedHost == nil || resolvedHost?.isEmpty == true),
           let legacyURL = (
            (try? container.decode(String.self, forKey: .url))
                ?? (try? container.decode(String.self, forKey: .serverURLString))
           )?.trimmingCharacters(in: .whitespacesAndNewlines),
           !legacyURL.isEmpty {
            var normalizedURL = legacyURL
            if !normalizedURL.contains("://") {
                normalizedURL = "ws://\(normalizedURL)"
            }
            if let components = URLComponents(string: normalizedURL),
               let parsedHost = components.host,
               !parsedHost.isEmpty {
                resolvedHost = parsedHost
                if let parsedPort = components.port {
                    resolvedPort = String(parsedPort)
                }
            }
        }

        host = (resolvedHost?.isEmpty == false) ? resolvedHost! : (decodedLegacyIP?.isEmpty == false ? decodedLegacyIP! : "127.0.0.1")
        port = (resolvedPort?.isEmpty == false) ? resolvedPort! : "9281"
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? true
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
