import AppKit

// Renders a 1024×1024 app icon: a macOS Big-Sur-grid squircle with a vertical
// gradient and a centered white "waveform" glyph. Channel color is passed in.
// Usage: swift MakeIcon.swift <hexTop> <hexBottom> <out.png>

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: MakeIcon.swift <hexTop> <hexBottom> <out.png>\n".data(using: .utf8)!)
    exit(1)
}
let topHex = args[1], botHex = args[2], outPath = args[3]

func color(_ hex: String) -> NSColor {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    let v = UInt64(s, radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255.0,
                   green: CGFloat((v >> 8) & 0xff) / 255.0,
                   blue: CGFloat(v & 0xff) / 255.0, alpha: 1)
}

let px = 1024
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Squircle background (Big Sur grid: 824 content within 1024, ~22.37% corner).
let margin: CGFloat = 100
let side = CGFloat(px) - margin * 2
let radius = side * 0.2237
let bgRect = NSRect(x: margin, y: margin, width: side, height: side)

NSGraphicsContext.current?.saveGraphicsState()
let bg = NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius)
bg.addClip()
if let gradient = NSGradient(starting: color(topHex), ending: color(botHex)) {
    gradient.draw(in: bgRect, angle: -90) // top → bottom
}
NSGraphicsContext.current?.restoreGraphicsState()

// Centered white "waveform" glyph.
let glyphPoint = side * 0.5
let cfg = NSImage.SymbolConfiguration(pointSize: glyphPoint, weight: .semibold)
if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let s = symbol.size
    // Tint the template symbol white.
    let tinted = NSImage(size: s)
    tinted.lockFocus()
    symbol.draw(in: NSRect(origin: .zero, size: s))
    NSColor.white.set()
    NSGraphicsContext.current?.compositingOperation = .sourceAtop
    NSRect(origin: .zero, size: s).fill()
    tinted.unlockFocus()
    let gx = (CGFloat(px) - s.width) / 2
    let gy = (CGFloat(px) - s.height) / 2
    tinted.draw(in: NSRect(x: gx, y: gy, width: s.width, height: s.height))
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do {
    try png.write(to: URL(fileURLWithPath: outPath))
} catch {
    FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
