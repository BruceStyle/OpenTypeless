import Foundation
import NaturalLanguage

public struct LearnedWord: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case active, pending, excluded }
    public let id: UUID
    public var term: String
    public var variants: [String]
    public var status: Status
    public var updatedAt: Date
    public var confirmations: Int
    public init(id: UUID = UUID(), term: String, variants: [String], status: Status, updatedAt: Date = Date(), confirmations: Int = 1) {
        self.id = id; self.term = term; self.variants = variants; self.status = status
        self.updatedAt = updatedAt; self.confirmations = confirmations
    }
}

public struct WordCorrection: Hashable, Sendable {
    public let original: String
    public let replacement: String
    public init(original: String, replacement: String) {
        self.original = original; self.replacement = replacement
    }
}

/// A receipt is scoped to one verified insertion. Surrounding text is only held
/// in memory, to reject edits in the rest of the document.
public struct InsertionReceipt: Sendable {
    public let baseline: String
    public let insertedText: String
    private let prefix: String
    private let suffix: String
    public init?(baseline: String, range: NSRange, insertedText: String) {
        guard baseline.utf16.count <= 32_768, insertedText.count <= 4_096,
              !insertedText.isEmpty, let range = Range(range, in: baseline),
              baseline[range] == insertedText else { return nil }
        self.baseline = baseline; self.insertedText = insertedText
        prefix = String(baseline[..<range.lowerBound]); suffix = String(baseline[range.upperBound...])
    }
    public func editedInsertion(in text: String) -> String? {
        guard text.utf16.count <= 32_768, text.hasPrefix(prefix), text.hasSuffix(suffix),
              text.count >= prefix.count + suffix.count else { return nil }
        let middle = String(text.dropFirst(prefix.count).dropLast(suffix.count))
        guard middle.count <= 4_096 else { return nil }
        return middle
    }
}

public enum CorrectionClassifier {
    /// This deliberately accepts only one compact lexical correction at a time.
    /// The user's settled edit is the confirmation, including Chinese and
    /// cross-language spellings. Intent and whole-sentence changes still fail.
    public static func candidate(before: String, after: String) -> WordCorrection? {
        guard before != after, !before.isEmpty, !after.isEmpty,
              before.count <= 4_096, after.count <= 4_096,
              !after.contains(before) else { return nil }
        let a = Array(before), b = Array(after)
        var left = 0, right = 0
        while left < min(a.count, b.count), a[left] == b[left] { left += 1 }
        while right < min(a.count, b.count) - left, a[a.count - right - 1] == b[b.count - right - 1] { right += 1 }
        let oldChange = String(a[left..<(a.count - right)])
        let newChange = String(b[left..<(b.count - right)])
        // A letter inserted inside an existing name can fix a typo. A new word
        // or a negation cannot: both expanded lexical spans must remain valid.
        guard (oldChange + newChange).contains(where: \.isLetter),
              !containsIntentChange(oldChange), !containsIntentChange(newChange),
              oldChange.filter(\.isNumber) == newChange.filter(\.isNumber) else { return nil }

        let oldBounds = wordBounds(in: before, changed: left..<(a.count - right))
        let newBounds = wordBounds(in: after, changed: left..<(b.count - right))
        // Expand to whole words on both sides; keep exactly the same unchanged
        // prefix/suffix so a different tokenizer split cannot truncate a name.
        let start = min(oldBounds.lowerBound, newBounds.lowerBound)
        let trailing = min(a.count - oldBounds.upperBound, b.count - newBounds.upperBound)
        let original = String(a[start..<(a.count - trailing)])
        let replacement = String(b[start..<(b.count - trailing)])
        guard validTerm(original), validTerm(replacement), original != replacement,
              original.filter(\.isNumber) == replacement.filter(\.isNumber),
              !containsIntentChange(original), !containsIntentChange(replacement),
              original.count <= 48, replacement.count <= 48 else { return nil }
        // Ignore full-sentence rewrites even when they contain no punctuation.
        let changedCount = oldChange.count + newChange.count
        guard max(original.count, replacement.count) <= 24,
              changedCount <= 32 else { return nil }
        return WordCorrection(original: original, replacement: replacement)
    }

    public static func validTerm(_ term: String) -> Bool {
        let groups = term.split(whereSeparator: \.isWhitespace)
        return (2...100).contains(term.count) && !groups.isEmpty && groups.count <= 3
            && term.contains(where: \.isLetter)
            && term.allSatisfy { $0.isLetter || $0.isNumber || " -_.".contains($0) }
    }
    private static func containsIntentChange(_ text: String) -> Bool {
        // These differences must never be turned into spelling preferences.
        let chinese = ["不", "没", "勿", "别", "否", "是", "要", "可以", "允许", "禁止", "现在", "暂时", "确认", "发布", "取消"]
        if chinese.contains(where: text.contains) { return true }
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let intent: Set<String> = ["no", "not", "never", "yes", "can", "cannot", "could", "should", "would", "will", "won", "don", "do", "did", "does", "is", "isn", "delete", "publish", "allow", "deny", "now", "later", "one", "two", "three", "zero"]
        return words.contains(where: intent.contains)
    }
    private static func wordBounds(in text: String, changed: Range<Int>) -> Range<Int> {
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text
        let start = text.index(text.startIndex, offsetBy: changed.lowerBound)
        let end = text.index(text.startIndex, offsetBy: changed.upperBound)
        var lo = start, hi = end
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { token, _ in
            if token.overlaps(start..<end) { lo = min(lo, token.lowerBound); hi = max(hi, token.upperBound) }
            return token.lowerBound < end
        }
        return text.distance(from: text.startIndex, to: lo)..<text.distance(from: text.startIndex, to: hi)
    }
}

/// Time-based state is independent of AX so cancellation, IME pauses and undo
/// can be exercised without reading another app or calling a model.
public struct CorrectionObservation {
    public enum Event: Equatable { case learn(WordCorrection), undo(WordCorrection) }
    public static let lifetime: TimeInterval = 60
    public static let settlingTime: TimeInterval = 3
    private var receipt: InsertionReceipt
    private let deadline: TimeInterval
    private var lastText: String
    private var changedAt: TimeInterval
    private var emitted: [WordCorrection] = []
    public private(set) var ended = false
    public init(receipt: InsertionReceipt, now: TimeInterval) {
        self.receipt = receipt; lastText = receipt.baseline
        changedAt = now; deadline = now + Self.lifetime
    }
    public mutating func sample(_ text: String?, now: TimeInterval) -> Event? {
        guard !ended else { return nil }
        guard now < deadline, let text, let edited = receipt.editedInsertion(in: text), !edited.isEmpty else {
            ended = true; return nil
        }
        if text != lastText { lastText = text; changedAt = now; return nil }
        guard text != receipt.baseline, now - changedAt >= Self.settlingTime else { return nil }
        // Settle one edit at a time, then retain the updated local baseline for
        // subsequent word corrections within the same 60-second window.
        let candidate = CorrectionClassifier.candidate(before: receipt.insertedText, after: edited)
        guard let candidate else {
            // Punctuation / formatting changes do not terminate an otherwise
            // attributable dictation. Appended words and semantic rewrites do.
            let letters: (String) -> String = { String($0.filter { $0.isLetter || $0.isNumber }) }
            if letters(receipt.insertedText) == letters(edited), let next = receipt.replacingInsertion(with: edited) {
                receipt = next; changedAt = now
            } else { ended = true }
            return nil
        }
        if let next = receipt.replacingInsertion(with: edited) { receipt = next }
        changedAt = now
        if let index = emitted.lastIndex(where: { $0.original == candidate.replacement && $0.replacement == candidate.original }) {
            return .undo(emitted.remove(at: index))
        }
        emitted.append(candidate)
        if emitted.count >= 10 { ended = true }
        return .learn(candidate)
    }
}

private extension InsertionReceipt {
    func replacingInsertion(with text: String) -> InsertionReceipt? {
        InsertionReceipt(baseline: prefix + text + suffix,
                         range: NSRange(location: prefix.utf16.count, length: text.utf16.count), insertedText: text)
    }
}

public enum DictionaryVocabulary {
    public static func settings(_ settings: AppSettings, words: [LearnedWord], transcript: String) -> AppSettings {
        var result = settings
        let manual = settings.dictionary.split(whereSeparator: \.isNewline)
            .map { String($0.trimmingCharacters(in: .whitespaces).prefix(100)) }.filter { !$0.isEmpty }
        let active = words.filter { $0.status == .active }.sorted { $0.updatedAt > $1.updatedAt }
        let corrections = SpellingMemory.relevant(words: words, transcript: transcript)
        let input = transcript.lowercased()
        let matches: (String) -> Bool = { input.contains($0.lowercased()) }
        let relevantLearned = active.filter { matches($0.term) || $0.variants.contains(where: matches) }.map(\.term)
        let relevantManual = manual.filter(matches)
        // Prioritize matching entries, then recent learned words, then the rest.
        // Pending / excluded words and their variants never go to the provider.
        let ordered = relevantLearned + relevantManual + active.prefix(100).map(\.term) + manual
        var seen = Set<String>()
        result.dictionary = ordered.filter { seen.insert($0.lowercased()).inserted }.prefix(100).joined(separator: "\n")
        let selected = Set(result.vocabulary.map { $0.lowercased() })
        result.spellingCorrections = corrections.filter { selected.contains($0.preferred.lowercased()) }
        return result
    }
}
