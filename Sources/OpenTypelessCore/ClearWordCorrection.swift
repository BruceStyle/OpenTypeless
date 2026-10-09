import Foundation

/// A deterministic backstop for a short, isolated test of one learned name.
/// General prose still needs semantic disambiguation by the rewrite model.
public enum ClearWordCorrection {
    public static func apply(to output: String, original: String, corrections: [SpellingCorrection]) -> String {
        guard original.count <= 240, output.count <= 240 else { return output }
        var replacements: [(NSRange, String)] = []
        for correction in corrections {
            guard safeName(correction.heard), safeName(correction.preferred),
                  correction.heard.filter(\.isNumber) == correction.preferred.filter(\.isNumber),
                  let alias = expression(for: correction.heard),
                  alias.firstMatch(in: original, range: fullRange(original)) != nil,
                  isWordTest(original, correction: correction),
                  isWordTest(output, correction: correction) else { continue }
            for match in alias.matches(in: output, range: fullRange(output)) {
                // Apply against the original output, never cascade one learned
                // spelling into another or modify overlapping ranges twice.
                guard !replacements.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) else { continue }
                replacements.append((match.range, correction.preferred))
            }
        }
        let result = NSMutableString(string: output)
        for (range, preferred) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            result.replaceCharacters(in: range, with: preferred)
        }
        return result as String
    }

    private static func isWordTest(_ text: String, correction: SpellingCorrection) -> Bool {
        // The whole utterance must fit this deliberately small grammar. A cue
        // buried inside a sentence about medicine, devices, or intent is not
        // enough. Quotes, code delimiters, paths and unknown words stay present
        // and therefore fail the grammar rather than being stripped away.
        guard !text.contains("◊") else { return false }
        var marked = text
        for name in [correction.heard, correction.preferred] {
            guard let regex = expression(for: name) else { return false }
            marked = regex.stringByReplacingMatches(in: marked, range: fullRange(marked), withTemplate: "◊")
        }
        let compact = marked.lowercased().filter { !$0.isWhitespace && !",，.。!！?？;；:：、".contains($0) }
        let filler = "(?:okay|ok|好的|好|嗯|呃|那么|那|现在|这次|这边|我们|我|你|请|让|来|再|先|继续|接着|可以|然后|比如说|比如|例如)"
        let cue = "(?:测试|试|说|念|读)"
        let qualifier = "(?:一下|一次|一遍|另一个|另外一个|一个|这个|个|下|词语|单词|名字|词)"
        let mention = "(?:" + filler + "*(?:" + cue + qualifier + "*" + filler + "*)*◊)"
        let pattern = "^" + mention + "+(?:这个词|这个单词|这个名字)?$"
        return compact.range(of: pattern, options: .regularExpression) != nil
    }

    private static func safeName(_ name: String) -> Bool {
        CorrectionClassifier.validTerm(name) && name.allSatisfy { $0.isLetter || $0.isNumber || " -".contains($0) }
    }
    private static func expression(for name: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: "(?<![\\p{Latin}\\p{N}_])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{Latin}\\p{N}_])", options: .caseInsensitive)
    }
    private static func fullRange(_ text: String) -> NSRange { NSRange(text.startIndex..., in: text) }
}
