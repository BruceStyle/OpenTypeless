import XCTest
@testable import OpenTypelessCore

final class ClearWordCorrectionTests: XCTestCase {
    private let correction = SpellingCorrection(heard: "tablets", preferred: "Typeless")
    private func apply(_ text: String, output: String? = nil) -> String {
        ClearWordCorrection.apply(to: output ?? text, original: text, corrections: [correction])
    }

    func testActualMissIsCorrectedEvenWhenModelIgnoresTheLearnedPair() {
        XCTAssertEqual(apply("OK，那这次让我们再测试一下Tablets。", output: "OK，那这次让我们再测试一下 Tablets。"),
                       "OK，那这次让我们再测试一下 Typeless。")
    }
    func testIsolatedNamesRepeatedNamesAndCommonTestPhrases() {
        for (original, expected) in [
            ("Tablets.", "Typeless."), ("TABLETS, tablets.", "Typeless, Typeless."),
            ("OK，那我这边再测试一下，说tablets。", "OK，那我这边再测试一下，说Typeless。"),
            ("再说一个，比如说 Tablets。", "再说一个，比如说 Typeless。"),
            ("那我们试一下Tablets这个词。", "那我们试一下Typeless这个词。")
        ] { XCTAssertEqual(apply(original), expected, original) }
    }
    func testAlreadyCorrectOutputAndPartialCorrectionKeepFormatting() {
        XCTAssertEqual(apply("Tablets. Tablets.", output: "Typeless. Tablets."), "Typeless. Typeless.")
        XCTAssertEqual(apply("Tablets. Tablets.", output: "Typeless."), "Typeless.")
    }
    func testGeneralProseKeepsModelSemanticsIncludingOrdinaryUses() {
        for text in ["I take two tablets daily.", "这两台 tablets 的屏幕不同。", "我们测试一下 tablets 的屏幕。",
                     "吃药前测试一下 tablets。", "这是药片。再测试一下 tablets。", "请打开 tablets，暂时不要发布。"] {
            XCTAssertEqual(apply(text), text)
        }
    }
    func testExplicitLiteralContentCannotBeRewritten() {
        for text in ["`Tablets`", "\"Tablets\"", "“Tablets”", "/tmp/tablets.txt", "https://tablets.example",
                     "再测试一下 `Tablets`。", "请逐字保留 Tablets。", "Tablets@example.com"] {
            XCTAssertEqual(apply(text), text)
        }
    }
    func testNegationContrastAndQuantitiesAreNotWordTests() {
        for text in ["不要测试 tablets。", "不是 Typeless，是 Tablets。", "再说两片 tablets。", "测试这两台 tablets。"] {
            XCTAssertEqual(apply(text), text)
        }
    }
    func testBothOriginalAndOutputMustBeClearWordTests() {
        XCTAssertEqual(apply("I take tablets daily.", output: "Tablets."), "Tablets.")
        XCTAssertEqual(apply("Tablets.", output: "I take tablets daily."), "I take tablets daily.")
        XCTAssertEqual(apply("Tablist.", output: "Tablets."), "Tablets.")
        XCTAssertEqual(apply(String(repeating: "好，", count: 130) + "Tablets。"), String(repeating: "好，", count: 130) + "Tablets。")
    }
    func testOtherLearnedNamesUseTheSameRuleWithoutHardCodedSpelling() {
        let pair = SpellingCorrection(heard: "codepilot", preferred: "CodePilot")
        XCTAssertEqual(ClearWordCorrection.apply(to: "我们再测试一下 codepilot。", original: "我们再测试一下codepilot。", corrections: [pair]),
                       "我们再测试一下 CodePilot。")
        XCTAssertEqual(ClearWordCorrection.apply(to: "mycodepilot", original: "mycodepilot", corrections: [pair]), "mycodepilot")
        XCTAssertEqual(ClearWordCorrection.apply(to: "GPT4", original: "GPT4", corrections: [.init(heard: "GPT4", preferred: "GPT5")]), "GPT4")
    }
}
