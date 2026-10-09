import AppKit
import OSLog

/// SwiftUI has no key equivalent for a lone modifier. Decorate only the
/// dictation row once its native menu exists, without registering another key.
@MainActor final class MenuShortcutPresenter {
    var shortcut = "Fn"
    private var observers: [NSObjectProtocol] = []

    init() {
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name,
                                                                    object: nil, queue: nil) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                MainActor.assumeIsolated { self?.decorate(menu) }
            })
        }
    }

    func decorate(_ menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu { decorate(submenu) }
        }
        guard let item = menu.items.first(where: { ["开始听写", "停止并整理"].contains($0.title) }),
              menu.items.contains(where: { $0.title == "打开 OpenTypeless" }) else { return }
        if let view = item.view as? ShortcutMenuItemView, view.represents(title: item.title, shortcut: shortcut) {
            view.needsDisplay = true
            return
        }
        let font = NSFont.menuFont(ofSize: 0)
        let textWidth = ((item.title + shortcut) as NSString).size(withAttributes: [.font: font]).width
        let width = max(190, textWidth + 60)
        item.view = ShortcutMenuItemView(item: item, shortcut: shortcut, width: width)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--verification") {
            Logger(subsystem: "com.opentypeless.mac", category: "MenuShortcut")
                .notice("Installed shortcut menu view; width=\(width)")
        }
        #endif
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
