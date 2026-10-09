import XCTest
@testable import OpenTypelessCore

final class EscapeKeyTests: XCTestCase {
    func testEscapeCancelsOnceAndConsumesReleaseAfterSessionEnds() {
        var tracker = EscapeKeyTracker()
        let down = tracker.handle(kind: .keyDown, keyCode: 53, enabled: true, conflictingModifiers: false)
        XCTAssertTrue(down.cancel); XCTAssertTrue(down.suppress)
        let repeatDown = tracker.handle(kind: .keyDown, keyCode: 53, enabled: false, conflictingModifiers: false)
        XCTAssertFalse(repeatDown.cancel); XCTAssertTrue(repeatDown.suppress)
        let up = tracker.handle(kind: .keyUp, keyCode: 53, enabled: false, conflictingModifiers: false)
        XCTAssertFalse(up.cancel); XCTAssertTrue(up.suppress)
        XCTAssertFalse(tracker.handle(kind: .keyDown, keyCode: 53, enabled: false, conflictingModifiers: false).suppress)
    }
    func testEscapeOutsideDictationAndOtherKeysPassThrough() {
        var tracker = EscapeKeyTracker()
        XCTAssertFalse(tracker.handle(kind: .keyDown, keyCode: 53, enabled: false, conflictingModifiers: false).suppress)
        XCTAssertFalse(tracker.handle(kind: .keyUp, keyCode: 53, enabled: false, conflictingModifiers: false).suppress)
        XCTAssertFalse(tracker.handle(kind: .keyDown, keyCode: 0, enabled: true, conflictingModifiers: false).suppress)
        XCTAssertFalse(tracker.handle(kind: .keyDown, keyCode: 53, enabled: true, conflictingModifiers: true).cancel)
    }
    func testNextSessionCanCancelAndTapResetCannotLeaveEscapeHeld() {
        var tracker = EscapeKeyTracker()
        for _ in 0..<2 {
            XCTAssertTrue(tracker.handle(kind: .keyDown, keyCode: 53, enabled: true, conflictingModifiers: false).cancel)
            XCTAssertTrue(tracker.handle(kind: .keyUp, keyCode: 53, enabled: false, conflictingModifiers: false).suppress)
        }
        _ = tracker.handle(kind: .keyDown, keyCode: 53, enabled: true, conflictingModifiers: false)
        tracker.reset()
        XCTAssertFalse(tracker.handle(kind: .keyUp, keyCode: 53, enabled: false, conflictingModifiers: false).suppress)
    }
}
