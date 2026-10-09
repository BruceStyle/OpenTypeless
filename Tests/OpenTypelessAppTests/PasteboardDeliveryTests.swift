import AppKit
import XCTest
@testable import OpenTypeless

final class PasteboardDeliveryTests: XCTestCase {
    @MainActor func testNextPasteRestoresOriginalClipboardRatherThanPreviousDictation() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("用户原始内容", forType: .string)
        item.setData(Data([0, 1, 255, 13, 10]), forType: .init("test.binary"))
        board.writeObjects([item])
        let delivery = PasteboardDelivery(pasteboard: board)
        let first = try delivery.write("第一条听写")
        let second = try delivery.write("第二条听写")
        delivery.restore(first)
        XCTAssertEqual(board.string(forType: .string), "第二条听写", "Late cleanup cannot replace a newer paste")
        delivery.restore(second)
        XCTAssertEqual(board.string(forType: .string), "用户原始内容")
        XCTAssertEqual(board.data(forType: .init("test.binary")), Data([0, 1, 255, 13, 10]))
    }

    @MainActor func testUserCopyWinsOverDelayedCleanupAndBecomesNextBackup() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("原始", forType: .string)
        let delivery = PasteboardDelivery(pasteboard: board)
        let first = try delivery.write("听写")
        board.clearContents(); board.setString("用户刚复制的内容", forType: .string)
        let second = try delivery.write("下一条听写")
        delivery.restore(first)
        delivery.restore(second)
        XCTAssertEqual(board.string(forType: .string), "用户刚复制的内容")
        let third = try delivery.write("第三条")
        board.clearContents(); board.setString("更晚的复制", forType: .string)
        delivery.restore(third)
        XCTAssertEqual(board.string(forType: .string), "更晚的复制")
    }

    @MainActor func testCancellationDoesNotShortenClipboardGraceOrCancelCleanup() async throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("原始剪贴板", forType: .string)
        let delivery = PasteboardDelivery(pasteboard: board)
        let task = Task {
            let ticket = try delivery.write("等待目标应用读取")
            delivery.restore(ticket, after: .milliseconds(150))
            try? await Task.sleep(for: .seconds(5))
        }
        for _ in 0..<100 where board.string(forType: .string) != "等待目标应用读取" {
            try await Task.sleep(for: .milliseconds(2))
        }
        task.cancel(); try await task.value
        XCTAssertEqual(board.string(forType: .string), "等待目标应用读取")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(board.string(forType: .string), "原始剪贴板")
    }

    @MainActor func testLargeClipboardIsPreservedWithoutStartingPaste() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let bytes = Data(repeating: 1, count: 16_000_001)
        board.setData(bytes, forType: .init("test.large"))
        let changes = board.changeCount
        let delivery = PasteboardDelivery(pasteboard: board)
        XCTAssertThrowsError(try delivery.write("不应替换"))
        XCTAssertEqual(board.changeCount, changes)
        XCTAssertEqual(board.data(forType: .init("test.large")), bytes)
    }

    @MainActor func testUnavailableReadbackDoesNotSleepOrAccessTarget() async {
        let confirmed = await PasteConfirmation.wait(expected: nil, readValue: {
            XCTFail("No expected value, so verification cannot succeed"); return nil
        }, sleep: { _ in XCTFail("Unverifiable paste must not wait") })
        XCTAssertFalse(confirmed)
    }

    @MainActor func testConfirmationEndsAsSoonAsTargetMatchesAndNeverClaimsMismatchedText() async {
        var reads = 0, waits: [Duration] = []
        let confirmed = await PasteConfirmation.wait(expected: "最终文字", readValue: {
            reads += 1
            return reads == 2 ? "最终文字" : "原始文字"
        }, sleep: { waits.append($0) })
        XCTAssertTrue(confirmed)
        XCTAssertEqual(reads, 2)
        waits = []
        let missing = await PasteConfirmation.wait(expected: "最终文字", readValue: { "不同内容" }, sleep: { waits.append($0) })
        XCTAssertFalse(missing)
        XCTAssertEqual(waits.reduce(Duration.zero, +), .milliseconds(300))
    }
}
