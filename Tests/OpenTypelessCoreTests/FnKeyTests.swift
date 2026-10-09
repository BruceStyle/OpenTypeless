import XCTest
@testable import OpenTypelessCore

final class FnKeyTests: XCTestCase {
    func testStandaloneFnTogglesOncePerRelease() {
        var tracker = FnKeyTracker()
        for _ in 0..<2 {
            let down = tracker.handle(kind: .flagsChanged, keyCode: 63, fn: true, otherModifiers: false)
            XCTAssertFalse(down.toggle); XCTAssertTrue(down.suppress)
            let up = tracker.handle(kind: .flagsChanged, keyCode: 63, fn: false, otherModifiers: false)
            XCTAssertTrue(up.toggle); XCTAssertTrue(up.suppress)
        }
        XCTAssertFalse(tracker.handle(kind: .flagsChanged, keyCode: 63, fn: false, otherModifiers: false).toggle)
    }
    func testFnArrowChordPassesThroughWithoutToggling() {
        var tracker = FnKeyTracker()
        _ = tracker.handle(kind: .flagsChanged, keyCode: 63, fn: true, otherModifiers: false)
        XCTAssertFalse(tracker.handle(kind: .keyDown, keyCode: 123, fn: true, otherModifiers: false).suppress)
        _ = tracker.handle(kind: .keyUp, keyCode: 123, fn: true, otherModifiers: false)
        XCTAssertFalse(tracker.handle(kind: .flagsChanged, keyCode: 63, fn: false, otherModifiers: false).toggle)
    }
    func testAnotherModifierOnEitherSidePreventsToggle() {
        var tracker = FnKeyTracker()
        _ = tracker.handle(kind: .flagsChanged, keyCode: 63, fn: true, otherModifiers: true)
        XCTAssertFalse(tracker.handle(kind: .flagsChanged, keyCode: 63, fn: false, otherModifiers: false).toggle)
        _ = tracker.handle(kind: .flagsChanged, keyCode: 63, fn: true, otherModifiers: false)
        _ = tracker.handle(kind: .flagsChanged, keyCode: 56, fn: true, otherModifiers: true)
        _ = tracker.handle(kind: .flagsChanged, keyCode: 56, fn: true, otherModifiers: false)
        XCTAssertFalse(tracker.handle(kind: .flagsChanged, keyCode: 63, fn: false, otherModifiers: false).toggle)
    }
    func testHeldKeyAndFunctionFlagsDoNotBecomeFnPresses() {
        var tracker = FnKeyTracker()
        _ = tracker.handle(kind: .keyDown, keyCode: 0, fn: false, otherModifiers: false)
        _ = tracker.handle(kind: .flagsChanged, keyCode: 63, fn: true, otherModifiers: false)
        _ = tracker.handle(kind: .keyUp, keyCode: 0, fn: true, otherModifiers: false)
        XCTAssertFalse(tracker.handle(kind: .flagsChanged, keyCode: 63, fn: false, otherModifiers: false).toggle)
        XCTAssertFalse(tracker.handle(kind: .flagsChanged, keyCode: 122, fn: true, otherModifiers: false).suppress)
        XCTAssertFalse(tracker.handle(kind: .flagsChanged, keyCode: 63, fn: false, otherModifiers: false).toggle)
    }
    func testResetAndRepeatedDownDoNotCauseExtraToggles() {
        var tracker = FnKeyTracker()
        _ = tracker.handle(kind: .flagsChanged, keyCode: 63, fn: true, otherModifiers: false)
        XCTAssertFalse(tracker.handle(kind: .flagsChanged, keyCode: 63, fn: true, otherModifiers: false).toggle)
        tracker.reset()
        XCTAssertFalse(tracker.handle(kind: .flagsChanged, keyCode: 63, fn: false, otherModifiers: false).toggle)
        XCTAssertEqual(AppSettings().shortcut, "fn")
    }
}
