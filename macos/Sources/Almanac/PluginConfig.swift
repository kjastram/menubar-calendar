import Foundation

/// The SwiftBar plugin's `config.json` (`~/.config/menubar-calendar/config.json`, or `$MENUBAR_CAL_DIR`).
/// Only read, never written. Unknown keys are ignored, and a key with the wrong type is treated as missing,
/// so a hand-edited file never stops the import.
struct PluginConfig: Equatable, Sendable {
    var accountColors: [String: String] = [:]
    var hiddenAccounts: [String] = []
    /// Calendar names or IDs to hide.
    var exclude: [String] = []
    var lookaheadMinutes: Int?

    /// The plugin's config folder, same rule as `CONFIG_DIR` in calendar.1m.py.
    static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["MENUBAR_CAL_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/menubar-calendar", isDirectory: true)
    }

    static func fileURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        directory(environment: environment).appendingPathComponent("config.json")
    }

    /// Nil if the file doesn't exist. Throws if it exists but isn't a JSON object.
    static func load(from url: URL = fileURL()) throws -> PluginConfig? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try PluginConfig(data: Data(contentsOf: url))
    }

    init(accountColors: [String: String] = [:], hiddenAccounts: [String] = [], exclude: [String] = [],
         lookaheadMinutes: Int? = nil) {
        self.accountColors = accountColors
        self.hiddenAccounts = hiddenAccounts
        self.exclude = exclude
        self.lookaheadMinutes = lookaheadMinutes
    }

    init(data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        if let colors = object["account_colors"] as? [String: Any] {
            for (email, value) in colors {
                if let hex = value as? String, Self.isHexColor(hex) { accountColors[email] = hex }
            }
        }
        hiddenAccounts = (object["hidden_accounts"] as? [Any])?.compactMap { $0 as? String } ?? []
        exclude = (object["exclude"] as? [Any])?.compactMap { $0 as? String } ?? []
        if let number = object["lookahead_minutes"] as? NSNumber, number.doubleValue > 0 {
            lookaheadMinutes = Int(number.doubleValue.rounded())
        }
    }

    static func isHexColor(_ text: String) -> Bool {
        let digits = text.hasPrefix("#") ? text.dropFirst() : Substring(text)
        return (digits.count == 6 || digits.count == 8) && digits.allSatisfy(\.isHexDigit)
    }

    /// Readable dump for `Almanac --print-plugin-config`.
    var summary: String {
        var lines = ["account_colors:"]
        for email in accountColors.keys.sorted() { lines.append("  \(email) = \(accountColors[email]!)") }
        lines.append("hidden_accounts: \(hiddenAccounts)")
        lines.append("exclude: \(exclude)")
        lines.append("lookahead_minutes: \(lookaheadMinutes.map(String.init) ?? "(not set, default 60)")")
        return lines.joined(separator: "\n")
    }
}
