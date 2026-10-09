import ApplicationServices
import Foundation

/// Capture and readback must resolve web-container focus in the same way.
/// Never select an arbitrary textbox: descendants must explicitly own focus.
enum FocusedTextInput {
    struct CaptureResolution {
        var element: AXUIElement?
        var window: AXUIElement?
        var source = "none"
        var stage = "focusedElement"
        var rootRole = "unknown"
        var visited = 0
        var limitReached = false
        var appError: Int32 = 0
        var systemError: Int32 = 0
        var windowError: Int32 = 0
    }
    struct Resolution {
        let element: AXUIElement?
        let rootRole: String
        let visited: Int
        let limitReached: Bool
    }
    static func resolve(_ root: AXUIElement, timeout: Float? = nil) -> AXUIElement? {
        inspect(root, timeout: timeout).element
    }
    /// Some native/web hosts expose no application-level focused element but
    /// do expose focus inside their key window. Never search other windows.
    static func locate(in application: AXUIElement, pid: pid_t, timeout: Float = 0.08) -> CaptureResolution {
        func read(_ element: AXUIElement, _ name: String) -> (element: AXUIElement?, error: Int32) {
            AXUIElementSetMessagingTimeout(element, timeout)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, error.rawValue) }
            return (unsafeBitCast(value, to: AXUIElement.self), error.rawValue)
        }
        func belongsToApplication(_ element: AXUIElement) -> Bool {
            var owner: pid_t = 0
            return AXUIElementGetPid(element, &owner) == .success && owner == pid
        }
        var result = CaptureResolution()
        let window = read(application, kAXFocusedWindowAttribute)
        result.windowError = window.error
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        for source in ["application", "system", "window"] {
            let root: AXUIElement?
            switch source {
            case "application":
                let focus = read(application, kAXFocusedUIElementAttribute)
                result.appError = focus.error; root = focus.element
            case "system":
                let focus = read(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
                result.systemError = focus.error; root = focus.element
            default: root = window.element
            }
            guard let root, belongsToApplication(root) else { continue }
            let resolution = inspect(root, timeout: timeout, rootIsFocused: source != "window",
                                     maximumNodes: source == "window" ? 512 : 64,
                                     shouldContinue: { ProcessInfo.processInfo.systemUptime < deadline })
            result.source = source; result.stage = "resolveInput"
            result.rootRole = resolution.rootRole
            result.visited += resolution.visited
            result.limitReached = result.limitReached || resolution.limitReached
            guard let input = resolution.element, belongsToApplication(input) else { continue }
            guard let inputWindow = read(input, kAXWindowAttribute).element ?? window.element,
                  belongsToApplication(inputWindow) else { result.stage = "window"; continue }
            if let focusedWindow = window.element, !CFEqual(inputWindow, focusedWindow) {
                result.stage = "differentWindow"; continue
            }
            result.element = input; result.window = inputWindow; result.stage = "resolved"
            return result
        }
        return result
    }

    static func inspect(_ root: AXUIElement, timeout: Float? = nil, rootIsFocused: Bool = true,
                        maximumNodes: Int = 64, shouldContinue: () -> Bool = { true }) -> Resolution {
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            if let timeout { AXUIElementSetMessagingTimeout(element, timeout) }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        let rootRole = attribute(root, kAXRoleAttribute) as? String ?? "unknown"
        let traversal = FocusedInputTraversal<AXUIElement>(isInput: {
            [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(attribute($0, kAXRoleAttribute) as? String ?? "")
        }, isFocused: {
            attribute($0, kAXFocusedAttribute) as? Bool == true
        }, focusedChild: {
            guard let raw = attribute($0, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(raw, to: AXUIElement.self)
        }, children: {
            attribute($0, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }, same: { CFEqual($0, $1) })
        let result = traversal.resolve(root, rootIsFocused: rootIsFocused,
                                       maximumNodes: maximumNodes, shouldContinue: shouldContinue)
        return Resolution(element: result.node, rootRole: rootRole,
                          visited: result.visited, limitReached: result.limitReached)
    }
}
