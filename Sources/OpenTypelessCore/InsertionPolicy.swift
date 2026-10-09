import Foundation

public struct FocusSignature: Equatable, Sendable {
    public var processID: Int32
    public var valueDigest: String?
    public var selectionLocation: Int?
    public var selectionLength: Int?
    public var editable: Bool
    public var secure: Bool
    public var explicitlyEditable: Bool
    public init(processID: Int32, valueDigest: String?, selectionLocation: Int?, selectionLength: Int?, editable: Bool, secure: Bool, explicitlyEditable: Bool = false) {
        self.processID = processID; self.valueDigest = valueDigest
        self.selectionLocation = selectionLocation; self.selectionLength = selectionLength
        self.editable = editable; self.secure = secure
        self.explicitlyEditable = explicitlyEditable
    }
}

public enum InsertionPolicy {
    public static func permits(original: FocusSignature, current: FocusSignature, sameElement: Bool, sameWindow: Bool) -> Bool {
        guard sameElement, sameWindow, original.processID == current.processID,
              original.editable, current.editable, !original.secure, !current.secure else { return false }
        if let before = original.valueDigest, let after = current.valueDigest {
            guard before == after else { return false }
        } else {
            // Some web editors expose focus and editability but no AXValue.
            // A missing value alone does not mean that there is no input cursor.
            guard original.explicitlyEditable, current.explicitlyEditable else { return false }
        }
        if let before = original.selectionLocation, let after = current.selectionLocation,
           let beforeLength = original.selectionLength, let afterLength = current.selectionLength {
            guard before == after, beforeLength == afterLength else { return false }
        }
        return true
    }
}
