import AppKit

/// The app's five-stroke mark, optically sized for the menu bar.
/// Template rendering lets macOS supply the color for the current background.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            let strokes = [
                NSRect(x: 0, y: 6.2, width: 2.3, height: 5.8),
                NSRect(x: 3.5, y: 3, width: 2.3, height: 12),
                NSRect(x: 7, y: 5.4, width: 2.3, height: 7.5),
                NSRect(x: 10.5, y: 6.8, width: 7.5, height: 2.1),
                NSRect(x: 10.5, y: 10.1, width: 7.5, height: 2.1)
            ]
            for stroke in strokes {
                let radius = min(stroke.width, stroke.height) / 2
                NSBezierPath(roundedRect: stroke, xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "OpenTypeless"
        return image
    }()
}
