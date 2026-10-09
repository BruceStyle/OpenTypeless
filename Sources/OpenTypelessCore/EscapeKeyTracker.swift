/// Consumes the entire Escape keystroke only while dictation can be cancelled.
/// Key-up stays consumed after cancellation disables the shortcut, so it cannot
/// leak into the destination app and dismiss its input box.
public struct EscapeKeyTracker {
    public struct Decision {
        public let cancel: Bool
        public let suppress: Bool
    }
    private var consumedDown = false
    public init() {}

    public mutating func handle(kind: FnKeyTracker.Kind, keyCode: Int, enabled: Bool, conflictingModifiers: Bool) -> Decision {
        guard keyCode == 53 else { return .init(cancel: false, suppress: false) }
        switch kind {
        case .keyDown:
            if consumedDown { return .init(cancel: false, suppress: true) }
            guard enabled, !conflictingModifiers else { return .init(cancel: false, suppress: false) }
            consumedDown = true
            return .init(cancel: true, suppress: true)
        case .keyUp:
            let consumed = consumedDown; consumedDown = false
            return .init(cancel: false, suppress: consumed)
        case .flagsChanged:
            return .init(cancel: false, suppress: false)
        }
    }
    public mutating func reset() { self = EscapeKeyTracker() }
}
