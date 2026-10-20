import AppKit

/// The menu bar pear: a one-colour template image, so macOS tints it like the other menu bar icons.
let pearGlyph: NSImage = {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        NSColor.black.set()

        let body = NSBezierPath()
        body.move(to: NSPoint(x: 9, y: 1.2))
        body.curve(to: NSPoint(x: 14.3, y: 6.2), controlPoint1: NSPoint(x: 12.2, y: 1.2),
                   controlPoint2: NSPoint(x: 14.3, y: 3.2))
        body.curve(to: NSPoint(x: 11.4, y: 11.4), controlPoint1: NSPoint(x: 14.3, y: 8.7),
                   controlPoint2: NSPoint(x: 12.3, y: 9.8))
        body.curve(to: NSPoint(x: 9, y: 14.8), controlPoint1: NSPoint(x: 10.8, y: 12.6),
                   controlPoint2: NSPoint(x: 11.0, y: 14.8))
        body.curve(to: NSPoint(x: 6.6, y: 11.4), controlPoint1: NSPoint(x: 7.0, y: 14.8),
                   controlPoint2: NSPoint(x: 7.2, y: 12.6))
        body.curve(to: NSPoint(x: 3.7, y: 6.2), controlPoint1: NSPoint(x: 5.7, y: 9.8),
                   controlPoint2: NSPoint(x: 3.7, y: 8.7))
        body.curve(to: NSPoint(x: 9, y: 1.2), controlPoint1: NSPoint(x: 3.7, y: 3.2),
                   controlPoint2: NSPoint(x: 5.8, y: 1.2))
        body.close()
        body.fill()

        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: 9, y: 14.2))
        stem.curve(to: NSPoint(x: 9.9, y: 17.2), controlPoint1: NSPoint(x: 9, y: 15.6),
                   controlPoint2: NSPoint(x: 9.4, y: 16.6))
        stem.lineWidth = 1.3
        stem.lineCapStyle = .round
        stem.stroke()

        let leaf = NSBezierPath()
        leaf.move(to: NSPoint(x: 10.1, y: 15.4))
        leaf.curve(to: NSPoint(x: 13.6, y: 16.6), controlPoint1: NSPoint(x: 11.0, y: 17.2),
                   controlPoint2: NSPoint(x: 12.6, y: 17.4))
        leaf.curve(to: NSPoint(x: 10.1, y: 15.4), controlPoint1: NSPoint(x: 12.8, y: 15.4),
                   controlPoint2: NSPoint(x: 11.2, y: 15.0))
        leaf.close()
        leaf.fill()
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Pear"
    return image
}()
