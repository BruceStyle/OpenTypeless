import AppKit
import OpenTypelessCore

/// The event tap and its state are used exclusively on the main run loop.
final class FnKeyMonitor {
    var onToggle: (() -> Void)?
    var onCancel: (() -> Void)?
    var cancellationEnabled = false
    private var fnEnabled = true
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tracker = FnKeyTracker()
    private var escape = EscapeKeyTracker()

    func start(fnEnabled: Bool = true) -> Bool {
        stop()
        self.fnEnabled = fnEnabled
        guard AXIsProcessTrusted() else { return false }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(pointer).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap); return false
        }
        self.tap = tap; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap)
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; tracker.reset(); escape.reset()
    }
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tracker.reset(); escape.reset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let kind: FnKeyTracker.Kind
        switch type {
        case .flagsChanged: kind = .flagsChanged
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        default: return Unmanaged.passUnretained(event)
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        // Retain Option-Escape as an alias, but keep Cmd/Control/Shift/Fn-Escape
        // available to macOS and the foreground application.
        let cancelDecision = escape.handle(kind: kind, keyCode: keyCode, enabled: cancellationEnabled,
            conflictingModifiers: !event.flags.intersection([.maskCommand, .maskControl, .maskShift, .maskSecondaryFn]).isEmpty)
        if cancelDecision.cancel { DispatchQueue.main.async { [weak self] in self?.onCancel?() } }
        if cancelDecision.suppress {
            _ = tracker.handle(kind: kind, keyCode: keyCode, fn: event.flags.contains(.maskSecondaryFn), otherModifiers: false)
            return nil
        }
        guard fnEnabled else { return Unmanaged.passUnretained(event) }
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let decision = tracker.handle(kind: kind, keyCode: keyCode,
                                      fn: event.flags.contains(.maskSecondaryFn),
                                      otherModifiers: !event.flags.intersection(modifiers).isEmpty)
        if decision.toggle {
            // Keep the event tap fast; application work runs after the callback returns.
            DispatchQueue.main.async { [weak self] in self?.onToggle?() }
        }
        return decision.suppress ? nil : Unmanaged.passUnretained(event)
    }
    deinit { stop() }
}
