// Generates the app icon: swift make-icon.swift <output .iconset folder>
// A flat paper lantern (lampion) built from simple shapes, on a black tile.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let tileTop = color(0x2A2A30), tileBottom = color(0x111114)
let paper = color(0xFF7A33), lit = color(0xFFC15E), rib = color(0xD9561F), metal = color(0xF2F2F5)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: s * x, y: s * y, width: s * w, height: s * h) }
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: s * x, y: s * y) }

    // Tile, on the macOS icon grid (824 of 1024)
    let tile = NSBezierPath(roundedRect: R(0.0977, 0.0977, 0.8047, 0.8047), xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: tileTop, ending: tileBottom)!.draw(in: tile, angle: -90)

    // Handle
    metal.setStroke()
    let handle = NSBezierPath()
    handle.appendArc(withCenter: P(0.5, 0.735), radius: s * 0.05, startAngle: 0, endAngle: 180)
    handle.lineWidth = s * 0.026
    handle.lineCapStyle = .round
    handle.stroke()

    // Body: paper circle, lit middle panel, ribs
    paper.setFill()
    NSBezierPath(ovalIn: R(0.29, 0.29, 0.42, 0.42)).fill()
    lit.setFill()
    NSBezierPath(ovalIn: R(0.395, 0.29, 0.21, 0.42)).fill()
    rib.setStroke()
    for w in [0.21, 0.34] as [CGFloat] {
        let r = NSBezierPath(ovalIn: R(0.5 - w / 2, 0.29, w, 0.42))
        r.lineWidth = s * 0.012
        r.stroke()
    }
    let middle = NSBezierPath()
    middle.move(to: P(0.5, 0.30)); middle.line(to: P(0.5, 0.70))
    middle.lineWidth = s * 0.012
    middle.stroke()

    // Caps
    metal.setFill()
    NSBezierPath(roundedRect: R(0.385, 0.682, 0.23, 0.05), xRadius: s * 0.025, yRadius: s * 0.025).fill()
    NSBezierPath(roundedRect: R(0.40, 0.268, 0.20, 0.046), xRadius: s * 0.023, yRadius: s * 0.023).fill()

    // Tassel
    let cord = NSBezierPath()
    cord.move(to: P(0.5, 0.27)); cord.line(to: P(0.5, 0.215))
    cord.lineWidth = s * 0.016
    cord.lineCapStyle = .round
    metal.setStroke()
    cord.stroke()
    paper.setFill()
    NSBezierPath(roundedRect: R(0.476, 0.14, 0.048, 0.085), xRadius: s * 0.024, yRadius: s * 0.024).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
