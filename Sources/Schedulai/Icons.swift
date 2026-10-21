import AppKit

/// The drawings shared by the menu bar icon and the app icon: a clock with a
/// Claude-style sparkle in its top-right corner.
enum Icons {
    /// A four-point star with concave sides.
    static func sparkle(center c: CGPoint, radius r: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: c.x, y: c.y + r))
        for point in [
            CGPoint(x: c.x + r, y: c.y),
            CGPoint(x: c.x, y: c.y - r),
            CGPoint(x: c.x - r, y: c.y),
            CGPoint(x: c.x, y: c.y + r),
        ] {
            let pull: CGFloat = 0.18
            let current = path.currentPoint
            path.curve(
                to: point,
                controlPoint1: CGPoint(x: c.x + (current.x - c.x) * pull, y: c.y + (current.y - c.y) * pull),
                controlPoint2: CGPoint(x: c.x + (point.x - c.x) * pull, y: c.y + (point.y - c.y) * pull)
            )
        }
        path.close()
        return path
    }

    enum Badge {
        case sparkle, failure, running
    }

    /// The 18 pt template image shown in the menu bar.
    static func menuBar(_ badge: Badge) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let center = CGPoint(x: 8, y: 8)
            let face = NSBezierPath(ovalIn: NSRect(x: center.x - 6.6, y: center.y - 6.6, width: 13.2, height: 13.2))
            face.lineWidth = 1.6
            face.stroke()

            let hands = NSBezierPath()
            hands.move(to: CGPoint(x: center.x, y: center.y + 4))
            hands.line(to: center)
            if badge == .running {
                hands.line(to: CGPoint(x: center.x - 3, y: center.y - 1.8))
            } else {
                hands.line(to: CGPoint(x: center.x + 3, y: center.y - 1.5))
            }
            hands.lineWidth = 1.6
            hands.lineCapStyle = .round
            hands.lineJoinStyle = .round
            hands.stroke()

            // Punch a hole in the face's corner, then draw the badge in it.
            let badgeCenter = CGPoint(x: 14.2, y: 14.2)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - 4.4, y: badgeCenter.y - 4.4, width: 8.8, height: 8.8)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            switch badge {
            case .sparkle, .running:
                sparkle(center: badgeCenter, radius: 3.6).fill()
            case .failure:
                NSBezierPath(ovalIn: NSRect(x: badgeCenter.x - 3, y: badgeCenter.y - 3, width: 6, height: 6)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
