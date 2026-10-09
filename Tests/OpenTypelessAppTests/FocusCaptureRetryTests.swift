import XCTest
@testable import OpenTypeless

final class FocusCaptureRetryTests: XCTestCase {
    @MainActor func testChromiumCanBecomeReadyAfterTwoSecondDebounce() async {
        var elapsed = Duration.zero
        let result = await FocusCaptureRetry.wait(delays: FocusCaptureRetry.chromiumDelays,
            isOriginalWindowFocused: { true }, capture: { elapsed >= .seconds(2) ? "editor" : nil },
            sleep: { elapsed += $0 })
        XCTAssertEqual(result, "editor")
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(2))
        XCTAssertLessThan(elapsed, .seconds(3))
    }

    @MainActor func testAlreadyReadyInputReturnsOnFirstRetry() async {
        var waits = 0
        let result = await FocusCaptureRetry.wait(delays: FocusCaptureRetry.chromiumDelays,
            isOriginalWindowFocused: { true }, capture: { "editor" }, sleep: { _ in waits += 1 })
        XCTAssertEqual(result, "editor")
        XCTAssertEqual(waits, 1)
    }

    @MainActor func testWindowSwitchDuringWarmupStopsBeforeReadingAnotherInput() async {
        var originalWindow = true
        let result: String? = await FocusCaptureRetry.wait(delays: FocusCaptureRetry.chromiumDelays,
            isOriginalWindowFocused: { originalWindow },
            capture: { XCTFail("Must not inspect the new window"); return "other editor" },
            sleep: { _ in originalWindow = false })
        XCTAssertNil(result)
    }

    @MainActor func testWindowSwitchDuringAccessibilityReadRejectsCapturedInput() async {
        var originalWindow = true
        let result = await FocusCaptureRetry.wait(delays: FocusCaptureRetry.chromiumDelays,
            isOriginalWindowFocused: { originalWindow },
            capture: { originalWindow = false; return "stale editor" }, sleep: { _ in })
        XCTAssertNil(result)
    }

    @MainActor func testUnavailableTreeHasBoundedWaitAndNativeAppsKeepShortRetries() async {
        for delays in [FocusCaptureRetry.standardDelays, FocusCaptureRetry.chromiumDelays] {
            var elapsed = Duration.zero
            let result: String? = await FocusCaptureRetry.wait(delays: delays,
                isOriginalWindowFocused: { true }, capture: { nil }, sleep: { elapsed += $0 })
            XCTAssertNil(result)
            XCTAssertLessThan(elapsed, .seconds(4))
        }
        XCTAssertLessThan(FocusCaptureRetry.standardDelays.reduce(.zero, +), .seconds(1))
    }

    @MainActor func testCancelledSessionNeverCapturesEvenIfSleepIgnoresCancellation() async {
        let task = Task { @MainActor () -> String? in
            await FocusCaptureRetry.wait(delays: FocusCaptureRetry.chromiumDelays,
                isOriginalWindowFocused: { true },
                capture: { XCTFail("Cancelled dictation must not capture"); return "editor" },
                sleep: { _ in await Task.yield() })
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }
}
