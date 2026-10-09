import AppKit

/// A display-only shortcut column, including modifier-only shortcuts such as Fn.
/// HotkeyService remains the sole owner of the actual recording shortcut.
final class ShortcutMenuItemView: NSView {
    private let title: String
    private let shortcut: String
    private weak var item: NSMenuItem?
    private let font = NSFont.menuFont(ofSize: 0)
    private var hover = false
    private var tracking: NSTrackingArea?

    init(item: NSMenuItem, shortcut: String, width: CGFloat) {
        self.title = item.title
        self.shortcut = shortcut
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.title)
        setAccessibilityHelp("快捷键：\(shortcut)")
    }

    required init?(coder: NSCoder) { nil }

    func represents(title: String, shortcut: String) -> Bool {
        self.title == title && self.shortcut == shortcut
    }

    override func draw(_ dirtyRect: NSRect) {
        let enabled = item?.isEnabled ?? false
        let highlighted = enabled && (item?.isHighlighted == true
            || (hover && item?.menu?.highlightedItem == nil))
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        let titleColor: NSColor = !enabled ? .disabledControlTextColor
            : highlighted ? .selectedMenuItemTextColor : .controlTextColor
        let shortcutColor: NSColor = !enabled ? .disabledControlTextColor
            : highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: titleColor]
        let shortcutAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: shortcutColor]
        let titleSize = (title as NSString).size(withAttributes: titleAttributes)
        let shortcutSize = (shortcut as NSString).size(withAttributes: shortcutAttributes)
        (title as NSString).draw(at: NSPoint(x: 16, y: (bounds.height - titleSize.height) / 2), withAttributes: titleAttributes)
        (shortcut as NSString).draw(at: NSPoint(x: bounds.width - 16 - shortcutSize.width,
                                               y: (bounds.height - shortcutSize.height) / 2),
                                     withAttributes: shortcutAttributes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) {
        hover = bounds.contains(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityEnabled() -> Bool { item?.isEnabled ?? false }
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        _ = accessibilityPerformPress()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let item, item.isEnabled, let menu = item.menu else { return false }
        let index = menu.index(of: item)
        guard index >= 0 else { return false }
        menu.cancelTracking()
        menu.performActionForItem(at: index)
        return true
    }
}
