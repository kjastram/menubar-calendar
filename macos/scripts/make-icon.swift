// Draws the app icon and writes Resources/AppIcon.icns.
// Run from macos/:  swift scripts/make-icon.swift
// Off-white page, dark ink header, a month of dots with today filled, two event chips
// in the plugin's account colors. No red, no gradients (see PLAN.md, "Look").
import AppKit

let ground = NSColor(srgbRed: 0xFB / 255, green: 0xFB / 255, blue: 0xF9 / 255, alpha: 1)
let border = NSColor(srgbRed: 0xE0 / 255, green: 0xDF / 255, blue: 0xDA / 255, alpha: 1)
let ink = NSColor(srgbRed: 0x1C / 255, green: 0x1D / 255, blue: 0x1F / 255, alpha: 1)
let dot = NSColor(srgbRed: 0xCF / 255, green: 0xCE / 255, blue: 0xC9 / 255, alpha: 1)
let blue = NSColor(srgbRed: 0x4F / 255, green: 0x8F / 255, blue: 0xF7 / 255, alpha: 1)
let orange = NSColor(srgbRed: 0xF0 / 255, green: 0x88 / 255, blue: 0x3E / 255, alpha: 1)

/// Draws in a 1024×1024 space with y pointing down.
func draw() {
    let page = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: page, xRadius: 185, yRadius: 185)
    ground.setFill()
    shape.fill()
    // Border first, so the header covers it at the top.
    border.setStroke()
    let outline = NSBezierPath(roundedRect: page.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
    outline.lineWidth = 4
    outline.stroke()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    ink.setFill()
    NSRect(x: 100, y: 100, width: 824, height: 210).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Light header marks, like a month title.
    NSColor(white: 1, alpha: 0.9).setFill()
    NSBezierPath(roundedRect: NSRect(x: 190, y: 186, width: 230, height: 40), xRadius: 20, yRadius: 20).fill()
    NSColor(white: 1, alpha: 0.35).setFill()
    NSBezierPath(roundedRect: NSRect(x: 440, y: 186, width: 110, height: 40), xRadius: 20, yRadius: 20).fill()

    let x0: CGFloat = 200, y0: CGFloat = 410, dx: CGFloat = 104, dy: CGFloat = 104
    func center(_ col: Int, _ row: Int) -> NSPoint {
        NSPoint(x: x0 + CGFloat(col) * dx, y: y0 + CGFloat(row) * dy)
    }
    // Cells covered by a chip or today don't get a dot.
    let chips: [(row: Int, from: Int, to: Int, color: NSColor)] = [(1, 0, 2, blue), (3, 4, 6, orange)]
    let today = (col: 3, row: 2)
    for row in 0..<5 {
        for col in 0..<7 {
            if chips.contains(where: { $0.row == row && (($0.from)...($0.to)).contains(col) }) { continue }
            if (col, row) == today { continue }
            let c = center(col, row)
            dot.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 17, y: c.y - 17, width: 34, height: 34)).fill()
        }
    }
    for chip in chips {
        let a = center(chip.from, chip.row), b = center(chip.to, chip.row)
        chip.color.setFill()
        NSBezierPath(roundedRect: NSRect(x: a.x - 30, y: a.y - 22, width: b.x - a.x + 60, height: 44),
                     xRadius: 22, yRadius: 22).fill()
    }
    let t = center(today.col, today.row)
    ink.setFill()
    NSBezierPath(ovalIn: NSRect(x: t.x - 42, y: t.y - 42, width: 84, height: 84)).fill()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    let scale = CGFloat(pixels) / 1024
    cg.translateBy(x: 0, y: CGFloat(pixels))
    cg.scaleBy(x: scale, y: -scale)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try png(pixels: size).write(to: iconset.appending(path: "icon_\(size)x\(size).png"))
    try png(pixels: size * 2).write(to: iconset.appending(path: "icon_\(size)x\(size)@2x.png"))
}
try fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Resources/AppIcon.icns (PNGs in \(iconset.path))")
