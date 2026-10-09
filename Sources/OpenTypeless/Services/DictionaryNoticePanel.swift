import AppKit
import SwiftUI

private final class WordNoticePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class DictionaryNoticePanel {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?
    func show(term: String, action: @escaping () -> Void) {
        hide()
        let panel = WordNoticePanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 66),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "词典学习提示"; panel.level = .floating
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView:
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                Text("已记住：\(term)").lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button("撤销") { [weak self] in self?.hide(); action() }
            }.padding(16).frame(width: 390, height: 66)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        )
        let visible = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        panel.setFrameOrigin(NSPoint(x: visible.maxX - 410, y: visible.minY + 28))
        self.panel = panel; panel.orderFrontRegardless()
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.hide()
        }
    }
    func hide() { dismissal?.cancel(); dismissal = nil; panel?.orderOut(nil); panel = nil }
}
