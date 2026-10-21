// Draws the 1024 px app icon: a white clock face on a terracotta tile, with a
// Claude-style sparkle in its top-right corner (same motif as the menu bar icon).
// Usage: swift scripts/generate-app-icon.swift <output.png>
import AppKit

func sparkle(center c: CGPoint, radius r: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: CGPoint(x: c.x, y: c.y + r))
    for point in [CGPoint(x: c.x + r, y: c.y), CGPoint(x: c.x, y: c.y - r),
                  CGPoint(x: c.x - r, y: c.y), CGPoint(x: c.x, y: c.y + r)] {
        let pull: CGFloat = 0.18
        let current = path.currentPoint
        path.curve(to: point,
                   controlPoint1: CGPoint(x: c.x + (current.x - c.x) * pull, y: c.y + (current.y - c.y) * pull),
                   controlPoint2: CGPoint(x: c.x + (point.x - c.x) * pull, y: c.y + (point.y - c.y) * pull))
    }
    path.close()
    return path
}

let size: CGFloat = 1024
let terracotta = NSColor(srgbRed: 0.80, green: 0.40, blue: 0.27, alpha: 1)
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    // Tile, with a soft drop shadow like the system icons.
    let tileRect = rect.insetBy(dx: 100, dy: 100)
    let tile = NSBezierPath(roundedRect: tileRect, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    NSColor.black.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(srgbRed: 0.95, green: 0.58, blue: 0.40, alpha: 1),
               ending: NSColor(srgbRed: 0.72, green: 0.31, blue: 0.20, alpha: 1))!
        .draw(in: tile, angle: -90)

    // Clock face.
    let center = CGPoint(x: 488, y: 488)
    let radius: CGFloat = 245
    let face = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                           width: radius * 2, height: radius * 2))
    NSColor(srgbRed: 1, green: 0.97, blue: 0.94, alpha: 1).setFill()
    face.fill()

    // Hour ticks.
    terracotta.withAlphaComponent(0.55).setStroke()
    for hour in 0..<12 {
        let angle = CGFloat(hour) * .pi / 6
        let tick = NSBezierPath()
        let inner: CGFloat = hour % 3 == 0 ? 180 : 200
        tick.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
        tick.line(to: CGPoint(x: center.x + cos(angle) * 218, y: center.y + sin(angle) * 218))
        tick.lineWidth = hour % 3 == 0 ? 22 : 12
        tick.lineCapStyle = .round
        tick.stroke()
    }

    // Hands at 8:00.
    terracotta.setStroke()
    let hands = NSBezierPath()
    hands.move(to: CGPoint(x: center.x, y: center.y + 165))
    hands.line(to: center)
    hands.line(to: CGPoint(x: center.x - 112, y: center.y - 64))
    hands.lineWidth = 40
    hands.lineCapStyle = .round
    hands.lineJoinStyle = .round
    hands.stroke()
    terracotta.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 30, y: center.y - 30, width: 60, height: 60)).fill()

    // Sparkle over the face's top-right edge, outlined in the tile colour so
    // it reads as cut out of the face.
    let star = sparkle(center: CGPoint(x: 690, y: 690), radius: 140)
    NSColor(srgbRed: 0.90, green: 0.51, blue: 0.35, alpha: 1).setStroke()
    star.lineWidth = 34
    star.lineJoinStyle = .round
    star.stroke()
    NSColor.white.setFill()
    star.fill()
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(filePath: CommandLine.arguments[1]))
