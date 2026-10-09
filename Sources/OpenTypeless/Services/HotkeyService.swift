import Carbon
import AppKit
import Foundation
import OpenTypelessCore

@MainActor final class HotkeyService {
    static let shortcuts = ["fn", "optionSpace", "controlOptionSpace", "commandShiftSpace"]
    static func label(_ value: String) -> String {
        switch value { case "fn": return "Fn"; case "controlOptionSpace": return "⌃ ⌥ 空格"; case "commandShiftSpace": return "⇧ ⌘ 空格"; default: return "⌥ 空格" }
    }
    var onToggle: (() -> Void)?
    var onCancel: (() -> Void)?
    private var handler: EventHandlerRef?
    private var hotkey: EventHotKeyRef?
    private let fnMonitor = FnKeyMonitor()
    private var localEscape: Any?
    private var escape = EscapeKeyTracker()
    private var cancellationEnabled = false
    private let signature: OSType = 0x4F54594C

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            let service = Unmanaged<HotkeyService>.fromOpaque(pointer).takeUnretainedValue()
            let id = key.id
            Task { @MainActor in if id == 1 { service.onToggle?() } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        // Also handle app-local Escape (including while its main window is
        // active). A consumed global event never reaches this monitor twice.
        localEscape = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            let decision = self.escape.handle(kind: event.type == .keyDown ? .keyDown : .keyUp,
                keyCode: Int(event.keyCode), enabled: self.cancellationEnabled,
                conflictingModifiers: !event.modifierFlags.intersection([.command, .control, .shift, .function]).isEmpty)
            if decision.cancel { self.onCancel?() }
            return decision.suppress ? nil : event
        }
    }
    func register(_ choice: String) -> Bool {
        if let hotkey { UnregisterEventHotKey(hotkey) }; hotkey = nil
        fnMonitor.onToggle = { [weak self] in self?.onToggle?() }
        fnMonitor.onCancel = { [weak self] in self?.onCancel?() }
        let monitoring = fnMonitor.start(fnEnabled: choice == "fn")
        if choice == "fn" {
            return monitoring
        }
        let modifiers: UInt32
        switch choice {
        case "controlOptionSpace": modifiers = UInt32(controlKey | optionKey)
        case "commandShiftSpace": modifiers = UInt32(cmdKey | shiftKey)
        default: modifiers = UInt32(optionKey)
        }
        return RegisterEventHotKey(UInt32(kVK_Space), modifiers, EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &hotkey) == noErr
    }
    func setBusy(_ busy: Bool) {
        cancellationEnabled = busy
        fnMonitor.cancellationEnabled = busy
    }
    deinit {
        if let localEscape { NSEvent.removeMonitor(localEscape) }
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
