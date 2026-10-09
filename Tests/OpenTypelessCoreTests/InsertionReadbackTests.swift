import XCTest
@testable import OpenTypelessCore

final class InsertionReadbackTests: XCTestCase {
    func testWebTerminalNewlineAndNonbreakingSpaceCreateUsableReceipt() throws {
        let text = "再说一个，比如说 tablets。"
        let expectation = try XCTUnwrap(InsertionExpectation(before: "", selection: NSRange(location: 0, length: 0), insertedText: text))
        let receipt = try XCTUnwrap(expectation.receipt(in: "\u{200b}再说一个，比如说\u{00a0}tablets。\n"))
        XCTAssertEqual(receipt.baseline, text)
        var observation = CorrectionObservation(receipt: receipt, now: 0)
        let corrected = InputTextNormalization.field("再说一个，比如说 Typeless。\n")
        XCTAssertNil(observation.sample(corrected, now: 1))
        XCTAssertEqual(observation.sample(corrected, now: 4), .learn(.init(original: "tablets", replacement: "Typeless")))
    }
    func testStaleCaretCanBeResolvedOnlyByUniqueWholePasteAndUnchangedSurroundings() throws {
        let expectation = try XCTUnwrap(InsertionExpectation(before: "已有第一句。\n", selection: NSRange(location: 0, length: 0), insertedText: "请用 tableless。"))
        let receipt = try XCTUnwrap(expectation.receipt(in: "已有第一句。\n请用 tableless。\n"))
        XCTAssertEqual(receipt.insertedText, "请用 tableless。")
        XCTAssertEqual(receipt.editedInsertion(in: "已有第一句。\n请用 Typeless。"), "请用 Typeless。")
        XCTAssertNil(expectation.receipt(in: "改变了第一句。\n请用 tableless。\n"))
        XCTAssertNil(expectation.receipt(in: "已有第一句。\n请用 tableless。另写一句"))
    }
    func testReplacementAndMultilineUnicodePreserveOriginalFieldAttribution() throws {
        let original = "😀前文 oldname 后文", old = (original as NSString).range(of: "oldname")
        let expectation = try XCTUnwrap(InsertionExpectation(before: original, selection: old, insertedText: "first\nCodePliot"))
        let receipt = try XCTUnwrap(expectation.receipt(in: "😀前文 first\r\nCodePliot 后文\n"))
        XCTAssertEqual(receipt.insertedText, "first\nCodePliot")
        XCTAssertNil(expectation.receipt(in: "😀改动前文 first\r\nCodePliot 后文\n"))
        XCTAssertNil(expectation.receipt(in: "😀前文 first\r\nCodePliot 改动后文\n"))
    }
    func testNoChangePartialPasteAmbiguousRepeatedWordsAndEarlyCorrectionCannotConfirm() throws {
        let expectation = try XCTUnwrap(InsertionExpectation(before: "CodePilot", selection: nil, insertedText: "CodePilot"))
        XCTAssertNil(expectation.receipt(in: "CodePilot"))
        XCTAssertNil(expectation.receipt(in: "CodePilotCodePilot"), "Two indistinguishable ranges must not be guessed")
        let fresh = try XCTUnwrap(InsertionExpectation(before: "", selection: nil, insertedText: "请用 tablets。"))
        XCTAssertNil(fresh.receipt(in: "请用 tab"))
        XCTAssertNil(fresh.receipt(in: "请用 Typeless。"), "Must first observe the posted text, not infer a correction from any different field")
    }
    func testParagraphTerminatorsDoNotChangeEmojiJoinersOrOrdinarySpaces() throws {
        let value = "👨‍👩‍👧‍👦 a  b\r\nsecond\u{2029}third\n"
        XCTAssertEqual(InputTextNormalization.field(value), "👨‍👩‍👧‍👦 a  b\nsecond\nthird")
        let fresh = try XCTUnwrap(InsertionExpectation(before: "", selection: NSRange(location: NSNotFound, length: 10), insertedText: "line\n"))
        XCTAssertEqual(fresh.receipt(in: "line\n\n")?.insertedText, "line")
    }
}
