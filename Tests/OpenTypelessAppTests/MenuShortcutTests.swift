import AppKit
import XCTest
@testable import OpenTypeless

final class MenuShortcutTests: XCTestCase {
    @MainActor func testDisplayedShortcutDoesNotRegisterAnotherKeyAndActionRunsOnce() throws {
        _ = NSApplication.shared
        let presenter = MenuShortcutPresenter()
        let target = ActionCounter()
        let menu = NSMenu(); menu.autoenablesItems = false
        let item = NSMenuItem(title: "开始听写", action: #selector(ActionCounter.select), keyEquivalent: "")
        item.target = target
        menu.addItem(item)
        menu.addItem(NSMenuItem(title: "打开 OpenTypeless", action: nil, keyEquivalent: ""))
        XCTAssertNotNil(item.view as? ShortcutMenuItemView, "Menu creation must attach the shortcut before tracking starts")
        for shortcut in ["Fn", "⌃ ⌥ 空格", "⇧ ⌘ 空格"] {
            presenter.shortcut = shortcut
            presenter.decorate(menu)
            let view = try XCTUnwrap(item.view as? ShortcutMenuItemView)
            XCTAssertEqual(item.keyEquivalent, "")
            XCTAssertEqual(view.accessibilityHelp(), "快捷键：\(shortcut)")
        }
        let view = try XCTUnwrap(item.view as? ShortcutMenuItemView)
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(target.count, 1)
        item.isEnabled = false
        XCTAssertFalse(view.isAccessibilityEnabled())
        XCTAssertFalse(view.accessibilityPerformPress())
        XCTAssertEqual(target.count, 1)
    }

    @MainActor func testRecordingLabelAndUnrelatedMenus() throws {
        _ = NSApplication.shared
        let menu = NSMenu()
        let item = NSMenuItem(title: "停止并整理", action: nil, keyEquivalent: "")
        menu.addItem(item)
        let presenter = MenuShortcutPresenter()
        presenter.decorate(menu)
        XCTAssertNil(item.view)
        menu.addItem(NSMenuItem(title: "打开 OpenTypeless", action: nil, keyEquivalent: ""))
        let root = NSMenu()
        let parent = NSMenuItem(title: "菜单预览", action: nil, keyEquivalent: "")
        parent.submenu = menu
        root.addItem(parent)
        presenter.decorate(root)
        let view = try XCTUnwrap(item.view as? ShortcutMenuItemView)
        XCTAssertEqual(view.accessibilityLabel(), "停止并整理")
        XCTAssertEqual(view.accessibilityHelp(), "快捷键：Fn")
    }

    @MainActor private final class ActionCounter: NSObject {
        var count = 0
        @objc func select() { count += 1 }
    }
}
