import AppKit
import SwiftUI

/// The status item: countdown text with a colored bar, or the calendar icon.
struct MenuBarLabel: View {
    let model: AppModel
    @AppStorage(AppSettings.lookaheadMinutes) private var lookahead = AppSettings.defaultLookahead
    @AppStorage(AppSettings.titleLength) private var titleLength = AppSettings.defaultTitleLength
    @AppStorage(AppSettings.showNextEvent) private var showNextEvent = true

    var body: some View {
        switch model.menu.title(lookaheadMinutes: lookahead, titleLength: titleLength,
                                showNextEvent: showNextEvent, setupNeeded: model.setupProblem != nil) {
        case .event(let text, let color, let filled):
            // Only Image and Text render in a status item, so the bar is a non-template image.
            Image(nsImage: barImage(color: color, filled: filled))
            Text(text)
        case .icon(let warning):
            Image(systemName: warning ? "calendar.badge.exclamationmark" : "calendar")
        }
    }
}

/// Rounded bar like the plugin's `pill_png`: filled = there's a meeting link, outline = no video call.
func barImage(color hex: String, filled: Bool, width: CGFloat = 5, height: CGFloat = 16) -> NSImage {
    let color = hexNSColor(hex)
    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
        let stroke: CGFloat = 1.5
        if filled {
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2).fill()
        } else {
            let inset = rect.insetBy(dx: stroke / 2, dy: stroke / 2)
            let path = NSBezierPath(roundedRect: inset, xRadius: inset.width / 2, yRadius: inset.width / 2)
            path.lineWidth = stroke
            color.setStroke()
            path.stroke()
        }
        return true
    }
    image.isTemplate = false
    return image
}
