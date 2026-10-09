import Foundation

/// A monotonic estimate for APIs that report completed requests, not token progress.
/// Only `complete()` may report 100%; elapsed time alone never finishes the work.
public struct DictationProgress: Equatable, Sendable {
    public enum Stage: Int, Sendable { case recognition, rewriting, delivery }

    public private(set) var fractionCompleted: Double = 0
    public private(set) var isComplete = false
    public private(set) var isTakingLonger = false
    public private(set) var stage: Stage?
    public var percentage: Int { isComplete ? 100 : min(99, Int(fractionCompleted * 100)) }

    private var startedAt: TimeInterval = 0
    private var segmentStartedAt: TimeInterval = 0
    private var segmentFloor: Double = 0
    private var segmentCeiling: Double = 0
    private var timeScale: TimeInterval = 1
    private var totalChunks = 1
    private var completedChunks = 0
    private var recognitionEnd: Double = 0.72
    private var chunkTime: TimeInterval = 4
    private var expectedDuration: TimeInterval = 10

    public init() {}

    public mutating func begin(at now: TimeInterval, audioSeconds: Double, totalChunks: Int,
                               completedChunks: Int, includesRewrite: Bool) {
        self = Self()
        startedAt = now
        self.totalChunks = max(1, totalChunks)
        self.completedChunks = min(self.totalChunks, max(0, completedChunks))
        recognitionEnd = includesRewrite ? 0.72 : 0.94
        chunkTime = max(3, min(10, audioSeconds / Double(self.totalChunks) * 0.3))
        expectedDuration = Double(self.totalChunks - self.completedChunks) * chunkTime + (includesRewrite ? 6 : 1)
        stage = .recognition
        fractionCompleted = max(0.02, recognitionEnd * Double(self.completedChunks) / Double(self.totalChunks))
        configureRecognition(at: now)
    }

    public mutating func updateCompletedChunks(_ count: Int, at now: TimeInterval) {
        guard stage == .recognition, !isComplete else { return }
        let count = min(totalChunks, max(completedChunks, count))
        guard count > completedChunks else { return }
        tick(at: now)
        completedChunks = count
        fractionCompleted = max(fractionCompleted, recognitionEnd * Double(count) / Double(totalChunks))
        configureRecognition(at: now)
    }

    public mutating func advance(to next: Stage, at now: TimeInterval) {
        guard let stage, next.rawValue > stage.rawValue, !isComplete else { return }
        tick(at: now)
        self.stage = next
        segmentStartedAt = now
        switch next {
        case .recognition: break
        case .rewriting:
            fractionCompleted = max(fractionCompleted, recognitionEnd)
            segmentCeiling = 0.94
            timeScale = 5
        case .delivery:
            fractionCompleted = max(fractionCompleted, 0.96)
            segmentCeiling = 0.99
            timeScale = 2
        }
        segmentFloor = fractionCompleted
    }

    public mutating func tick(at now: TimeInterval) {
        guard stage != nil, !isComplete else { return }
        let elapsed = max(0, now - segmentStartedAt)
        let estimate = segmentFloor + (segmentCeiling - segmentFloor) * (1 - exp(-elapsed / timeScale))
        fractionCompleted = min(0.99, max(fractionCompleted, estimate))
        isTakingLonger = now - startedAt > max(25, expectedDuration * 2)
    }

    public mutating func complete() {
        fractionCompleted = 1
        isComplete = true
        isTakingLonger = false
    }

    private mutating func configureRecognition(at now: TimeInterval) {
        segmentStartedAt = now
        segmentFloor = fractionCompleted
        // Leave room for each real chunk response; a slow request cannot consume
        // the budget belonging to the remaining audio or later stages.
        let nextChunk = min(Double(totalChunks), Double(completedChunks) + 0.9)
        segmentCeiling = max(segmentFloor, recognitionEnd * nextChunk / Double(totalChunks))
        timeScale = chunkTime
    }
}
