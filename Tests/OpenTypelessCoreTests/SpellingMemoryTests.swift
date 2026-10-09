import XCTest
@testable import OpenTypelessCore

final class SpellingMemoryTests: XCTestCase {
    private let typeless = LearnedWord(term: "Typeless", variants: ["tablets"], status: .active)
    private let expected = SpellingCorrection(heard: "tablets", preferred: "Typeless")

    func testKnownAliasMatchesCaseInsensitivelyInShortAndMixedLanguageSpeech() {
        for transcript in ["tablets", "Tablets. Tablets.", "TABLETS", "说tablets。", "打开Tablets检查"] {
            XCTAssertEqual(SpellingMemory.relevant(words: [typeless], transcript: transcript), [expected], transcript)
        }
    }

    func testUnknownSimilarSoundAndLargerWordsDoNotManufactureCorrections() {
        for transcript in ["Tablist, tablist.", "tablet", "mytablets", "tabletsPlus", "my_tablets", "tablets2", "2tablets"] {
            XCTAssertTrue(SpellingMemory.relevant(words: [typeless], transcript: transcript).isEmpty, transcript)
        }
    }

    func testOnlyActiveRelevantPairsAreSent() {
        let words = [typeless,
                     LearnedWord(term: "SwiftUI", variants: ["SwfitUI"], status: .active),
                     LearnedWord(term: "PendingName", variants: ["pendingname"], status: .pending),
                     LearnedWord(term: "ExcludedName", variants: ["excludedname"], status: .excluded)]
        XCTAssertEqual(SpellingMemory.relevant(words: words, transcript: "tablets pendingname excludedname"), [expected])
    }

    func testConflictingActiveAliasesAreNotResolvedByRecency() {
        let conflict = LearnedWord(term: "TableTools", variants: ["TABLETS"], status: .active)
        XCTAssertTrue(SpellingMemory.relevant(words: [typeless, conflict], transcript: "Tablets").isEmpty)
        let excluded = LearnedWord(term: "TableTools", variants: ["TABLETS"], status: .excluded)
        XCTAssertEqual(SpellingMemory.relevant(words: [typeless, excluded], transcript: "Tablets"), [expected])
    }

    func testCapitalizationIsLearnableButIdentityAndChangedNumbersAreExcluded() {
        let words = [LearnedWord(term: "ChatGPT", variants: ["chatgpt", "ChatGPT"], status: .active),
                     LearnedWord(term: "GPT5", variants: ["GPT4"], status: .active)]
        XCTAssertEqual(SpellingMemory.relevant(words: words, transcript: "chatgpt GPT4"),
                       [SpellingCorrection(heard: "chatgpt", preferred: "ChatGPT")])
    }

    func testRepeatedAndDifferentlyCasedAliasesAreDeduplicated() {
        let word = LearnedWord(term: "Typeless", variants: ["tablets", "Tablets", "tablets"], status: .active)
        XCTAssertEqual(SpellingMemory.relevant(words: [word], transcript: "Tablets. tablets."), [expected])
    }

    func testTermPunctuationIsLiteralInsteadOfRegexSyntax() {
        let word = LearnedWord(term: "AGENTS.md", variants: ["agent.md"], status: .active)
        XCTAssertEqual(SpellingMemory.relevant(words: [word], transcript: "agent.md"),
                       [SpellingCorrection(heard: "agent.md", preferred: "AGENTS.md")])
        XCTAssertTrue(SpellingMemory.relevant(words: [word], transcript: "agentXmd").isEmpty)
    }

    func testOrdinaryMeaningAndLiteralContextRemainAvailableForModelDisambiguation() throws {
        let transcript = "I take two tablets daily. Keep `tablets` and /tmp/tablets.txt unchanged."
        let settings = DictionaryVocabulary.settings(AppSettings(), words: [typeless], transcript: transcript)
        let payload = try RewritePrompt.user(transcript: transcript, vocabulary: settings.vocabulary, corrections: settings.spellingCorrections)
        let decoded = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any]
        XCTAssertEqual(decoded["transcript"] as? String, transcript, "No blanket replacement before the model sees context")
        XCTAssertEqual(settings.spellingCorrections, [expected])
    }

    func testRelevantPairsAreBoundedAndCanonicalWordsSurviveFullManualDictionary() {
        let words = (0..<40).map { i in
            LearnedWord(term: "Preferred\(i)", variants: ["heard\(i)"], status: .active,
                        updatedAt: Date(timeIntervalSinceReferenceDate: Double(i)))
        }
        let transcript = (0..<40).map { "heard\($0)" }.joined(separator: " ")
        var original = AppSettings(); original.mode = .structured
        original.dictionary = (0..<150).map { "Manual\($0)" }.joined(separator: "\n")
        let result = DictionaryVocabulary.settings(original, words: words, transcript: transcript)
        XCTAssertEqual(result.spellingCorrections.count, 32)
        XCTAssertEqual(result.spellingCorrections.first?.preferred, "Preferred39")
        XCTAssertEqual(result.vocabulary.count, 100)
        XCTAssertTrue(result.spellingCorrections.allSatisfy { result.vocabulary.contains($0.preferred) })
        XCTAssertEqual(result.mode, .structured)
        XCTAssertEqual(original.dictionary.components(separatedBy: "\n").count, 150)
        XCTAssertTrue(original.spellingCorrections.isEmpty)
    }

    func testRequestContextIsNotPersistedAndIsRecomputedForNextTranscript() throws {
        var original = AppSettings(); original.mode = .structured
        original.spellingCorrections = [expected]
        let encoded = try JSONEncoder().encode(original)
        let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        XCTAssertNil(json["spellingCorrections"])
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertEqual(decoded.mode, .structured)
        XCTAssertTrue(decoded.spellingCorrections.isEmpty)
        let next = DictionaryVocabulary.settings(original, words: [typeless], transcript: "another sentence")
        XCTAssertTrue(next.spellingCorrections.isEmpty)
    }
}
