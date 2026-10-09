import Foundation

/// A learned spelling preference, not a global search-and-replace rule.
public struct SpellingCorrection: Codable, Equatable, Sendable {
    public let heard: String
    public let preferred: String
    public init(heard: String, preferred: String) { self.heard = heard; self.preferred = preferred }
}

public enum SpellingMemory {
    public static func relevant(words: [LearnedWord], transcript: String) -> [SpellingCorrection] {
        let active = words.filter { $0.status == .active }.sorted { $0.updatedAt > $1.updatedAt }
        var targets: [String: Set<String>] = [:]
        for word in active {
            for variant in word.variants {
                targets[variant.lowercased(), default: []].insert(word.term.lowercased())
            }
        }
        var seen = Set<String>(), result: [SpellingCorrection] = []
        // Exact aliases only; ordinary word meanings remain for the rewrite
        // model to disambiguate. Never manufacture new aliases from similarity.
        for word in active where CorrectionClassifier.validTerm(word.term) {
            for variant in word.variants where CorrectionClassifier.validTerm(variant) {
                let key = variant.lowercased()
                guard targets[key]?.count == 1, !seen.contains(key),
                      variant != word.term,
                      variant.filter(\.isNumber) == word.term.filter(\.isNumber),
                      containsTerm(variant, in: transcript) else { continue }
                seen.insert(key)
                result.append(SpellingCorrection(heard: variant, preferred: word.term))
                if result.count == 32 { return result }
            }
        }
        return result
    }
    private static func containsTerm(_ term: String, in transcript: String) -> Bool {
        // Latin boundaries allow Chinese/English mixing, while excluding an
        // alias that is only a substring of another Latin word or identifier.
        let escaped = NSRegularExpression.escapedPattern(for: term)
        let pattern = "(?<![\\p{Latin}\\p{N}_])" + escaped + "(?![\\p{Latin}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        return regex.firstMatch(in: transcript, range: NSRange(transcript.startIndex..., in: transcript)) != nil
    }
}
