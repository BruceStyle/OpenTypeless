import Foundation

/// Normalization is only for in-memory attribution. It never edits the field
/// or the delivered text, and preserves ordinary spaces and punctuation.
public enum InputTextNormalization {
    public static func content(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "\u{200b}", with: "")
            .replacingOccurrences(of: "\u{feff}", with: "")
    }
    public static func field(_ value: String) -> String {
        var result = content(value)
        // Web text areas may expose an extra paragraph terminator.
        while result.last == "\n" { result.removeLast() }
        return result
    }
}

/// A posted paste is not proof of insertion. Confirm the complete dictation in
/// the same target, and require that removing it (or restoring the selection)
/// reconstructs the original field. This also handles stale web caret offsets.
public struct InsertionExpectation: Sendable {
    public let before: String
    public let insertedText: String
    private let replacedText: String
    public init?(before: String, selection: NSRange?, insertedText: String) {
        guard before.utf16.count <= 32_768, !insertedText.isEmpty, insertedText.count <= 4_096 else { return nil }
        self.before = before; self.insertedText = insertedText
        if let selection, selection.location >= 0, selection.length >= 0,
           selection.location <= before.utf16.count, selection.length <= before.utf16.count - selection.location,
           let range = Range(selection, in: before) {
            replacedText = String(before[range])
        } else { replacedText = "" }
    }
    public func receipt(in observed: String) -> InsertionReceipt? {
        guard observed.utf16.count <= 32_768 else { return nil }
        let baseline = InputTextNormalization.field(observed)
        let original = InputTextNormalization.field(before)
        guard baseline != original else { return nil }
        let full = InputTextNormalization.content(insertedText)
        let trimmed = InputTextNormalization.field(insertedText)
        let patterns = full == trimmed ? [full] : [full, trimmed]
        let replacement = InputTextNormalization.content(replacedText)
        let restorations = replacement.isEmpty ? [""] : [replacement, ""]
        var matches: [NSRange] = []
        var examined = 0
        for pattern in patterns where !pattern.isEmpty {
            var search = baseline.startIndex..<baseline.endIndex
            while let range = baseline.range(of: pattern, range: search) {
                examined += 1
                guard examined <= 16 else { return nil }
                // Only ignore a dictation's own terminal newline at field end.
                if pattern == full || range.upperBound == baseline.endIndex {
                    if restorations.contains(where: { restored in
                        InputTextNormalization.field(baseline.replacingCharacters(in: range, with: restored)) == original
                    }) {
                        let nsRange = NSRange(range, in: baseline)
                        if !matches.contains(nsRange) { matches.append(nsRange) }
                        guard matches.count <= 1 else { return nil }
                    }
                }
                search = baseline.index(after: range.lowerBound)..<baseline.endIndex
            }
        }
        guard let range = matches.first, let swiftRange = Range(range, in: baseline) else { return nil }
        return InsertionReceipt(baseline: baseline, range: range, insertedText: String(baseline[swiftRange]))
    }
}
