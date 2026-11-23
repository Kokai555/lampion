// Generates the app icon: swift make-icon.swift <output .iconset folder>
// A paper lantern (lampion) on a warm gradient.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let top = NSColor(red: 1.00, green: 0.69, blue: 0.23, alpha: 1)
    let bottom = NSColor(red: 0.88, green: 0.27, blue: 0.17, alpha: 1)
    let rib = NSColor(red: 0.93, green: 0.42, blue: 0.18, alpha: 1)

    // Background
    let tile = NSRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: top, ending: bottom)!.draw(in: tilePath, angle: -90)

    // Glow behind the lantern
    tilePath.addClip()
    let c = NSPoint(x: s * 0.5, y: s * 0.49)
    NSGradient(starting: NSColor(white: 1, alpha: 0.38), ending: NSColor(white: 1, alpha: 0))!
        .draw(fromCenter: c, radius: 0, toCenter: c, radius: s * 0.36, options: [])

    NSColor.white.set()
    // Handle
    let handle = NSBezierPath()
    handle.appendArc(withCenter: NSPoint(x: s * 0.5, y: s * 0.715), radius: s * 0.062, startAngle: 0, endAngle: 180)
    handle.lineWidth = s * 0.022
    handle.lineCapStyle = .round
    handle.stroke()
    // Body
    let body = NSRect(x: s * 0.315, y: s * 0.30, width: s * 0.37, height: s * 0.40)
    NSBezierPath(ovalIn: body).fill()
    // Caps
    for y in [s * 0.675, s * 0.285] as [CGFloat] {
        NSBezierPath(roundedRect: NSRect(x: s * 0.415, y: y, width: s * 0.17, height: s * 0.046), xRadius: s * 0.016, yRadius: s * 0.016).fill()
    }
    // Tassel
    let tassel = NSBezierPath()
    tassel.move(to: NSPoint(x: s * 0.5, y: s * 0.285)); tassel.line(to: NSPoint(x: s * 0.5, y: s * 0.215))
    tassel.lineWidth = s * 0.018; tassel.lineCapStyle = .round; tassel.stroke()
    NSBezierPath(ovalIn: NSRect(x: s * 0.478, y: s * 0.185, width: s * 0.044, height: s * 0.044)).fill()
    // Ribs
    rib.set()
    for w in [0.0, 0.20] as [CGFloat] {
        let r = NSBezierPath(ovalIn: NSRect(x: s * (0.5 - w / 2), y: body.minY + s * 0.012, width: s * w, height: body.height - s * 0.024))
        r.lineWidth = s * 0.013
        r.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
