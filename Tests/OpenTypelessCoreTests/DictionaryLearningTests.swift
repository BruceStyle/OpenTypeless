import XCTest
@testable import OpenTypelessCore

final class DictionaryLearningTests: XCTestCase {
    func testSpellingAndCapitalizationEditsAreAccepted() throws {
        for (old, new) in [("SwfitUI", "SwiftUI"), ("chatgpt", "ChatGPT"), ("openrouter", "OpenRouter"), ("ChatGT", "ChatGPT"), ("SwiftUUI", "SwiftUI")] {
            let result = try XCTUnwrap(CorrectionClassifier.candidate(before: "请使用 \(old) 检查界面。", after: "请使用 \(new) 检查界面。"))
            XCTAssertEqual(result.original, old); XCTAssertEqual(result.replacement, new)
        }
    }
    func testChineseAndCrossLanguageEditsAreAcceptedAsConfirmation() throws {
        for (old, new) in [("扣得克斯", "Codex"), ("启明科技", "启鸣科技"), ("Smyth", "Smith")] {
            let result = try XCTUnwrap(CorrectionClassifier.candidate(before: "联系 \(old) 团队。", after: "联系 \(new) 团队。"))
            XCTAssertTrue(new.contains(result.replacement))
        }
    }
    func testNegationNumbersPunctuationAndCommandsNeverBecomeWords() {
        let cases = [
            ("暂时不要发布", "现在发布"), ("不是接入这些模型", "是接入这些模型"),
            ("请确认后发布。", "请马上发布。"), ("Do not publish", "Do publish"),
            ("Please allow it", "Please deny it"), ("价格是 100 元", "价格是 200 元"),
            ("使用 GPT4", "使用 GPT5"), ("你好，世界", "你好。世界"),
            ("内容\n第二行", "内容第二行"), ("将会议定在明天", ""),
            ("原先要讨论复杂的技术实现和多种备选模型", "今天去公园拍照")
        ]
        for (old, new) in cases { XCTAssertNil(CorrectionClassifier.candidate(before: old, after: new), "\(old) → \(new)") }
    }
    func testAppendingNewContentCannotBeAttributedToDictation() {
        XCTAssertNil(CorrectionClassifier.candidate(before: "已经回填", after: "已经回填，另加一句 SwfitUI"))
        var observation = CorrectionObservation(receipt: receipt("已经回填"), now: 0)
        XCTAssertNil(observation.sample("已经回填，另加一句 SwfitUI", now: 1))
        XCTAssertNil(observation.sample("已经回填，另加一句 SwfitUI", now: 4))
        XCTAssertTrue(observation.ended)
        XCTAssertNil(observation.sample("已经回填，另加一句 SwiftUI", now: 8))
    }
    func testReceiptUsesUTF16AndOriginalAnchorsWhenWordsRepeat() throws {
        let original = "请用 SwfitUI。", prefix = "😀已有内容 SwfitUI\n", suffix = "\n后面的原有内容"
        let receipt = try XCTUnwrap(InsertionReceipt(baseline: prefix + original + suffix,
            range: NSRange(location: prefix.utf16.count, length: original.utf16.count), insertedText: original))
        XCTAssertEqual(receipt.editedInsertion(in: prefix + "请用 SwiftUI。" + suffix), "请用 SwiftUI。")
        XCTAssertNil(receipt.editedInsertion(in: "😀改动前文\n" + original + suffix))
        XCTAssertNil(receipt.editedInsertion(in: prefix + original + "改动后文"))
        XCTAssertNil(InsertionReceipt(baseline: "😀abc", range: NSRange(location: 1, length: 3), insertedText: "abc"))
        XCTAssertNil(InsertionReceipt(baseline: String(repeating: "x", count: 32_769), range: NSRange(location: 0, length: 2), insertedText: "xx"))
    }
    func testTypingMustSettleAndRevertingBeforeSettlingLearnsNothing() {
        var state = CorrectionObservation(receipt: receipt("请用 SwfitUI。"), now: 0)
        XCTAssertNil(state.sample("请用 Swi。", now: 1))
        XCTAssertNil(state.sample("请用 Swift。", now: 2))
        XCTAssertNil(state.sample("请用 SwiftUI。", now: 3))
        XCTAssertNil(state.sample("请用 SwiftUI。", now: 5.9))
        XCTAssertEqual(state.sample("请用 SwiftUI。", now: 6), .learn(.init(original: "SwfitUI", replacement: "SwiftUI")))
        XCTAssertNil(state.sample("请用 SwiftUI。", now: 10))

        var reverted = CorrectionObservation(receipt: receipt("请用 SwfitUI。"), now: 0)
        XCTAssertNil(reverted.sample("请用 SwiftUI。", now: 1))
        XCTAssertNil(reverted.sample("请用 SwfitUI。", now: 2))
        XCTAssertNil(reverted.sample("请用 SwfitUI。", now: 7))
    }
    func testPunctuationDoesNotPreventLaterWordCorrection() {
        var state = CorrectionObservation(receipt: receipt("请用 SwfitUI，"), now: 0)
        _ = state.sample("请用 SwfitUI。", now: 1)
        XCTAssertNil(state.sample("请用 SwfitUI。", now: 4))
        XCTAssertFalse(state.ended)
        _ = state.sample("请用 SwiftUI。", now: 5)
        XCTAssertEqual(state.sample("请用 SwiftUI。", now: 8), .learn(.init(original: "SwfitUI", replacement: "SwiftUI")))
    }
    func testUndoRetractsInsteadOfLearningWrongSpellingAndNextWordStillWorks() {
        var state = CorrectionObservation(receipt: receipt("SwfitUI 和 chatgpt"), now: 0)
        _ = state.sample("SwiftUI 和 chatgpt", now: 1)
        let first = WordCorrection(original: "SwfitUI", replacement: "SwiftUI")
        XCTAssertEqual(state.sample("SwiftUI 和 chatgpt", now: 4), .learn(first))
        _ = state.sample("SwfitUI 和 chatgpt", now: 5)
        XCTAssertEqual(state.sample("SwfitUI 和 chatgpt", now: 8), .undo(first))
        _ = state.sample("SwfitUI 和 ChatGPT", now: 9)
        XCTAssertEqual(state.sample("SwfitUI 和 ChatGPT", now: 12), .learn(.init(original: "chatgpt", replacement: "ChatGPT")))
    }
    func testUnavailableFieldAndDeadlineEndObservationWithoutLateLearning() {
        for unavailable in [true, false] {
            var state = CorrectionObservation(receipt: receipt("SwfitUI"), now: 0)
            _ = state.sample("SwiftUI", now: 1)
            XCTAssertNil(state.sample(unavailable ? nil : "SwiftUI", now: unavailable ? 2 : 60))
            XCTAssertTrue(state.ended)
            XCTAssertNil(state.sample("SwiftUI", now: 65))
        }
    }
    func testRelevantLearnedWordSurvivesFullManualDictionaryAndUnconfirmedWordsAreExcluded() {
        var settings = AppSettings(); settings.dictionary = (0..<150).map { "Manual\($0)" }.joined(separator: "\n")
        let words = [LearnedWord(term: "CodePilot", variants: ["扣得派洛特"], status: .active),
                     LearnedWord(term: "PendingName", variants: [], status: .pending),
                     LearnedWord(term: "RemovedName", variants: [], status: .excluded)]
        let next = DictionaryVocabulary.settings(settings, words: words, transcript: "用扣得派洛特检查")
        XCTAssertEqual(next.vocabulary.count, 100)
        XCTAssertEqual(next.vocabulary.first, "CodePilot")
        XCTAssertFalse(next.vocabulary.contains("PendingName")); XCTAssertFalse(next.vocabulary.contains("RemovedName"))
        XCTAssertEqual(settings.dictionary.components(separatedBy: "\n").count, 150, "Retrieval must not rewrite the saved manual dictionary")
    }
    func testSettingsBeforeLearningFeatureMigrateWithoutTurningObservationOn() throws {
        var settings = AppSettings(); settings.transcriptionModel = "fish-audio/transcribe-1"
        settings.transcriptionFallbackModel = "qwen/qwen3-asr-1.7b"
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        json.removeValue(forKey: "learnFromCorrections")
        let loaded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(loaded, settings); XCTAssertFalse(loaded.learnFromCorrections)
    }
    private func receipt(_ text: String) -> InsertionReceipt {
        InsertionReceipt(baseline: text, range: NSRange(location: 0, length: text.utf16.count), insertedText: text)!
    }
}
