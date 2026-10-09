import XCTest
@testable import OpenTypelessCore

final class DictationProgressTests: XCTestCase {
    func testLongRequestsNeverReachCompletionByElapsedTimeAlone() {
        var progress = DictationProgress()
        progress.begin(at: 0, audioSeconds: 10, totalChunks: 1, completedChunks: 0, includesRewrite: true)
        progress.tick(at: 1_000)
        XCTAssertLessThan(progress.fractionCompleted, 0.72)
        XCTAssertTrue(progress.isTakingLonger)
        for stage in [DictationProgress.Stage.rewriting, .delivery] {
            progress.advance(to: stage, at: 1_000)
            progress.tick(at: 10_000)
            XCTAssertLessThan(progress.percentage, 100)
            XCTAssertFalse(progress.isComplete)
        }
        progress.complete()
        XCTAssertEqual(progress.percentage, 100)
        XCTAssertEqual(progress.fractionCompleted, 1)
        XCTAssertFalse(progress.isTakingLonger)
    }

    func testProgressNeverGoesBackwardsAcrossChunksAndStages() {
        var progress = DictationProgress()
        progress.begin(at: 10, audioSeconds: 45, totalChunks: 3, completedChunks: 0, includesRewrite: true)
        var previous = progress.fractionCompleted
        for time in 11...30 {
            progress.tick(at: Double(time))
            if time.isMultiple(of: 5) { progress.updateCompletedChunks((time - 10) / 5, at: Double(time)) }
            XCTAssertGreaterThanOrEqual(progress.fractionCompleted, previous)
            previous = progress.fractionCompleted
        }
        progress.advance(to: .rewriting, at: 31)
        progress.tick(at: 32)
        XCTAssertGreaterThanOrEqual(progress.fractionCompleted, previous)
        previous = progress.fractionCompleted
        progress.updateCompletedChunks(0, at: 33) // Ignore stale recognition callbacks.
        progress.advance(to: .recognition, at: 33)
        progress.advance(to: .rewriting, at: 33)
        progress.tick(at: 30) // Even an older timestamp cannot rewind progress.
        XCTAssertGreaterThanOrEqual(progress.fractionCompleted, previous)
        progress.advance(to: .delivery, at: 34)
        XCTAssertGreaterThanOrEqual(progress.fractionCompleted, 0.96)
    }

    func testChunkBudgetLeavesRoomForTheRemainingAudio() {
        var progress = DictationProgress()
        progress.begin(at: 0, audioSeconds: 120, totalChunks: 8, completedChunks: 2, includesRewrite: true)
        XCTAssertEqual(progress.fractionCompleted, 0.18, accuracy: 0.0001)
        progress.tick(at: 1_000)
        XCTAssertLessThan(progress.fractionCompleted, 0.27)
        progress.updateCompletedChunks(3, at: 1_001)
        XCTAssertEqual(progress.fractionCompleted, 0.27, accuracy: 0.0001)
        progress.updateCompletedChunks(1, at: 1_002)
        XCTAssertEqual(progress.fractionCompleted, 0.27, accuracy: 0.0001)
    }

    func testTranscriptModeUsesTheRecognitionBudgetWithoutRewriting() {
        var progress = DictationProgress()
        progress.begin(at: 0, audioSeconds: 12, totalChunks: 1, completedChunks: 0, includesRewrite: false)
        progress.updateCompletedChunks(1, at: 3)
        XCTAssertEqual(progress.fractionCompleted, 0.94, accuracy: 0.0001)
        progress.advance(to: .delivery, at: 3)
        XCTAssertEqual(progress.stage, .delivery)
        XCTAssertFalse(progress.isComplete)
        progress.complete()
        XCTAssertEqual(progress.percentage, 100)
    }

    func testRetryStartsFromWorkAlreadyCompleted() {
        var progress = DictationProgress()
        progress.begin(at: 0, audioSeconds: 60, totalChunks: 4, completedChunks: 4, includesRewrite: true)
        XCTAssertEqual(progress.fractionCompleted, 0.72, accuracy: 0.0001)
        progress.tick(at: 2)
        XCTAssertEqual(progress.fractionCompleted, 0.72, accuracy: 0.0001)
        progress.advance(to: .rewriting, at: 2)
        progress.tick(at: 3)
        XCTAssertGreaterThan(progress.fractionCompleted, 0.72)
    }

    func testNextSessionClearsCompletionAndLongWaitState() {
        var progress = DictationProgress()
        progress.begin(at: 0, audioSeconds: 10, totalChunks: 1, completedChunks: 0, includesRewrite: true)
        progress.tick(at: 1_000)
        progress.complete()
        progress.tick(at: 2_000)
        XCTAssertEqual(progress.fractionCompleted, 1)
        progress.begin(at: 2_001, audioSeconds: 5, totalChunks: 1, completedChunks: 0, includesRewrite: true)
        XCTAssertEqual(progress.percentage, 2)
        XCTAssertFalse(progress.isComplete)
        XCTAssertFalse(progress.isTakingLonger)
        progress = DictationProgress() // Cancellation resets the display.
        progress.tick(at: 3_000)
        XCTAssertEqual(progress.fractionCompleted, 0)
        XCTAssertNil(progress.stage)
    }
}
