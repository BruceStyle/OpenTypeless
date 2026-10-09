import Foundation

/// Recognizes a standalone Fn press/release without retaining typed characters.
public struct FnKeyTracker {
    public enum Kind { case flagsChanged, keyDown, keyUp }
    public struct Decision {
        public let toggle: Bool
        public let suppress: Bool
    }
    private var heldKeys = Set<Int>()
    private var fnDown = false
    private var candidate = false
    private var suppressRelease = false
    public init() {}

    public mutating func handle(kind: Kind, keyCode: Int, fn: Bool, otherModifiers: Bool) -> Decision {
        switch kind {
        case .keyDown:
            heldKeys.insert(keyCode)
            if fnDown { candidate = false }
        case .keyUp:
            heldKeys.remove(keyCode)
        case .flagsChanged:
            if fnDown && otherModifiers { candidate = false }
            // Function/arrow key events may carry the Fn flag themselves.
            guard keyCode == 63 else { return Decision(toggle: false, suppress: false) }
            if fn && !fnDown {
                fnDown = true
                candidate = !otherModifiers && heldKeys.isEmpty
                suppressRelease = candidate
            } else if !fn && fnDown {
                let result = Decision(toggle: candidate && !otherModifiers, suppress: suppressRelease)
                fnDown = false; candidate = false; suppressRelease = false
                return result
            }
            return Decision(toggle: false, suppress: suppressRelease)
        }
        return Decision(toggle: false, suppress: false)
    }
    public mutating func reset() { self = FnKeyTracker() }
}
