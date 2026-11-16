import AppKit
import SwiftUI

/// UserDefaults keys for app settings. Views read them with `@AppStorage`.
enum AppSettings {
    static let lookaheadMinutes = "menuBarLookaheadMinutes"
    static let showNextEvent = "menuBarShowNextEvent"
    static let titleLength = "menuBarTitleLength"
    /// Calendar local id used for quick add and as the default for new events.
    static let defaultCalendarID = "defaultCalendarID"
    /// Set once the plugin's config.json was imported.
    static let importedPluginConfig = "importedPluginConfig"

    static let defaultLookahead = 60
    static let defaultTitleLength = 24

    static func register() {
        UserDefaults.standard.register(defaults: [
            lookaheadMinutes: defaultLookahead,
            showNextEvent: true,
            titleLength: defaultTitleLength,
        ])
    }
}

/// "#4f8ff7" → color. Falls back to gray for bad input.
func hexColor(_ hex: String) -> Color {
    Color(nsColor: hexNSColor(hex))
}

func hexNSColor(_ hex: String) -> NSColor {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard digits.count >= 6, let value = UInt64(digits.prefix(6), radix: 16) else { return .systemGray }
    return NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                   green: CGFloat((value >> 8) & 0xff) / 255,
                   blue: CGFloat(value & 0xff) / 255, alpha: 1)
}
