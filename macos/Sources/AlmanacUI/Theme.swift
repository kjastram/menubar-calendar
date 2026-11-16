import SwiftUI
import AppKit
import CoreText

/// Parses "#rrggbb" / "rrggbb" / "#rgb" strings from the cache.
public enum HexColor {
    public static func components(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    public static func color(_ hex: String, fallback: Color = .gray) -> Color {
        guard let c = components(hex) else { return fallback }
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: 1)
    }
}

/// Color tokens with matching light and dark values.
enum Theme {
    static let ground = dynamic(light: 0xFFFFFF, dark: 0x1B1B1D)
    static let sidebar = dynamic(light: 0xF7F7F5, dark: 0x212123)
    static let weekend = dynamic(light: 0xFAFAF8, dark: 0x1F1F21)
    static let selectedCell = dynamic(light: 0xF2F5FD, dark: 0x232631)
    static let hover = dynamic(light: 0xF4F4F2, dark: 0x29292C)
    static let miniSelected = dynamic(light: 0xE2E1DC, dark: 0x3A3A3E)
    static let divider = dynamic(light: 0xE6E5E1, dark: 0x303033)
    static let border = dynamic(light: 0xE0DFDA, dark: 0x3A3A3E)
    static let dashed = dynamic(light: 0xCFCEC9, dark: 0x45454A)
    static let ink = dynamic(light: 0x1C1D1F, dark: 0xECECEA)
    static let secondary = dynamic(light: 0x5F6168, dark: 0xA3A4AA)
    static let tertiary = dynamic(light: 0x73757C, dark: 0x7E7F86)
    /// The one accent: today, primary buttons, selection ring.
    static let accent = dynamic(light: 0x1C1D1F, dark: 0xECECEA)
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x1B1B1D)
    static let destructive = dynamic(light: 0xB42318, dark: 0xF97066)
    static let ok = dynamic(light: 0x2E9E5B, dark: 0x3FB970)
    static let warning = dynamic(light: 0xB54708, dark: 0xF0A050)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                           green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Inter for text and Space Grotesk for headings when installed; system fonts otherwise.
enum Fonts {
    private static let families: Set<String> = {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return Set(names)
    }()
    static let hasInter = families.contains("Inter")
    static let hasSpaceGrotesk = families.contains("Space Grotesk")

    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        hasInter ? .custom("Inter", size: size).weight(weight) : .system(size: size, weight: weight)
    }

    static func heading(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        if hasSpaceGrotesk { return .custom("Space Grotesk", size: size).weight(weight) }
        return text(size, weight)
    }
}

/// 1pt divider in the divider color.
struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Small uppercase label used for section headers.
struct SectionLabel: View {
    let text: String
    var size: CGFloat = 11.5
    var body: some View {
        Text(text.uppercased())
            .font(Fonts.text(size, .semibold))
            .kerning(0.5)
            .foregroundStyle(Theme.secondary)
    }
}

/// The bordered toolbar button from the mockup. `prominent` uses the accent fill.
struct PlainButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    var height: CGFloat = 32
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, style: self)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let style: PlainButtonStyle
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Fonts.text(13, style.prominent ? .semibold : .medium))
                .foregroundStyle(style.prominent ? Theme.onAccent : (style.destructive ? Theme.destructive : Theme.ink))
                .padding(.horizontal, 10)
                .frame(minWidth: style.height, maxWidth: style.fullWidth ? .infinity : nil, minHeight: style.height, maxHeight: style.height)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(style.prominent ? Theme.accent : (hovering ? Theme.hover : Theme.ground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(style.prominent ? Theme.accent : Theme.border, lineWidth: 1)
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .onHover { hovering = $0 }
        }
    }
}

/// Borderless icon button (settings gear, close X, sync).
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration, size: size)
    }

    private struct Inner: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(Theme.secondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.hover : Color.clear))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
