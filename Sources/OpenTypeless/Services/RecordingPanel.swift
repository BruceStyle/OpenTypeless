import AppKit
import SwiftUI

private final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class RecordingPanel {
    private let panel: NSPanel
    private weak var model: AppController?
    private var screen: NSScreen?

    init(model: AppController) {
        self.model = model
        panel = DictationPanel(contentRect: NSRect(origin: .zero, size: DictationLayout.panelSize),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "OpenTypeless 听写"
        panel.isFloatingPanel = true; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: RecordingOverlay(
            model: model,
            updateAppearance: { [weak self] in self?.updateAppearance() }
        ))
    }
    func show() {
        updateAppearance()
        let mouse = NSEvent.mouseLocation
        screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        resize()
        panel.orderFrontRegardless()
    }
    private func updateAppearance() {
        panel.appearance = model?.settings.configuration.overlayAppearance.appKitAppearance
        // Liquid Glass already draws its own elevation. A second NSWindow
        // shadow makes the small capsule's edge look like a dark double rim.
        if #available(macOS 26.0, *) {
            panel.hasShadow = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        }
    }
    private func resize() {
        let size = DictationLayout.panelSize
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.minY + 12,
                           width: size.width, height: size.height)
        if panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                panel.animator().setFrame(frame, display: true)
            }
        } else { panel.setFrame(frame, display: true) }
    }
    func hide() { panel.orderOut(nil) }
}
