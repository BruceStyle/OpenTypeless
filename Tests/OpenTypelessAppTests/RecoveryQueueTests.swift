import Foundation
import XCTest
import OpenTypelessCore
@testable import OpenTypeless

final class RecoveryQueueTests: XCTestCase {
    @MainActor func testOldSchemaWithoutOriginalOrAttemptMetadataStillDecodesAndExposesPartialText() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root), queue = RecoveryQueue(store: RecoveryStore(root: root))
        var draft = try record(into: queue, store: store)
        draft.chunks[0].result = .init(text: "之前已识别的正文", cost: 0.001)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as! [String: Any]
        for name in ["originalAudio", "attempts", "lastFailure", "acceptedSource"] { json.removeValue(forKey: name) }
        var chunks = json["chunks"] as! [[String: Any]]
        for name in ["startSample", "endSample", "failure", "previousText"] { chunks[0].removeValue(forKey: name) }
        json["chunks"] = chunks
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: root.appendingPathComponent(draft.id.uuidString).appendingPathComponent("session.json"))
        let recovered = try XCTUnwrap(store.recoverable().first)
        XCTAssertEqual(recovered.rawText, "之前已识别的正文")
        XCTAssertNil(recovered.originalAudio)
        XCTAssertNil(recovered.attempts)
        XCTAssertEqual(try store.audio(recovered.chunks[0], id: draft.id), try store.audio(draft.chunks[0], id: draft.id))
    }

    @MainActor func testFailedRecordingDoesNotBlockNextRecordingOrLoseOriginalAudio() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root)
        let queue = RecoveryQueue(store: store)
        let first = try record(into: queue, store: store)
        let audio = try store.audio(first.chunks[0], id: first.id)
        queue.preserveActive()
        XCTAssertNil(queue.active)
        XCTAssertEqual(queue.pending.map(\.id), [first.id])

        let second = try record(into: queue, store: store)
        XCTAssertEqual(queue.active?.id, second.id)
        queue.completeActive(removingFiles: true)
        XCTAssertEqual(try store.audio(first.chunks[0], id: first.id), audio)
        XCTAssertEqual(RecoveryQueue(store: store).pending.map(\.id), [first.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(second.id.uuidString).path))
    }

    @MainActor func testRestartLoadsEveryFailedSessionWithoutMakingOneActive() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root)
        let queue = RecoveryQueue(store: store)
        let first = try record(into: queue, store: store)
        queue.preserveActive()
        let second = try record(into: queue, store: store)
        queue.preserveActive()

        let reopened = RecoveryQueue(store: store)
        XCTAssertNil(reopened.active)
        XCTAssertEqual(Set(reopened.pending.map(\.id)), [first.id, second.id])
        try reopened.begin(id: UUID(), settings: AppSettings())
        XCTAssertEqual(reopened.pending.count, 2)
        XCTAssertNotNil(reopened.active)
    }

    @MainActor func testRetrySelectsOnlyRequestedSessionAndPreservesItAgainOnFailure() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root)
        let queue = RecoveryQueue(store: store)
        var first = try record(into: queue, store: store)
        first.rawText = "保留这一段原稿"; first.completeTranscript = true
        queue.active = first
        queue.preserveActive()
        let second = try record(into: queue, store: store)
        queue.preserveActive()

        XCTAssertTrue(queue.resume(first.id))
        XCTAssertEqual(queue.active?.rawText, first.rawText)
        XCTAssertEqual(queue.pending.map(\.id), [second.id])
        XCTAssertFalse(queue.resume(second.id))
        queue.preserveActive()
        XCTAssertEqual(Set(queue.pending.map(\.id)), [first.id, second.id])
        XCTAssertTrue(queue.resume(first.id))
        queue.completeActive(removingFiles: true)
        XCTAssertEqual(store.recoverable().map(\.id), [second.id])
    }

    @MainActor func testCancelNewRecordingAndDiscardOnePendingDoNotDeleteAnother() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root)
        let queue = RecoveryQueue(store: store)
        let first = try record(into: queue, store: store)
        queue.preserveActive()
        let second = try record(into: queue, store: store)
        queue.preserveActive()
        _ = try record(into: queue, store: store)
        queue.discardActive()
        XCTAssertEqual(Set(store.recoverable().map(\.id)), [first.id, second.id])
        queue.discardPending(first.id)
        XCTAssertEqual(queue.pending.map(\.id), [second.id])
        XCTAssertEqual(store.recoverable().map(\.id), [second.id])
    }

    @MainActor func testEmptyFailureIsRemovedAndStorageFailureKeepsCompletedSessionRecoverable() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root)
        let queue = RecoveryQueue(store: store)
        let empty = UUID()
        try queue.begin(id: empty, settings: AppSettings())
        queue.preserveActive()
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(empty.uuidString).path))

        let completed = try record(into: queue, store: store)
        queue.completeActive(removingFiles: false)
        XCTAssertNil(queue.active)
        XCTAssertEqual(queue.pending.map(\.id), [completed.id])
        XCTAssertEqual(store.recoverable().map(\.id), [completed.id])
    }

    @MainActor func testExpirationKeepsRecentAndTextOnlyRecoveries() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root)
        let now = Date()
        var expired = RecoveryDraft(id: UUID(), created: now.addingTimeInterval(-86_401), settings: AppSettings())
        expired.rawText = "过期的原稿"
        try store.save(expired)
        var recent = RecoveryDraft(id: UUID(), created: now.addingTimeInterval(-60), settings: AppSettings())
        recent.rawText = "可恢复的原稿"
        try store.save(recent)
        XCTAssertEqual(store.recoverable(now: now).map(\.id), [recent.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(expired.id.uuidString).path))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RecoveryQueueTests-\(UUID().uuidString)")
    }

    @MainActor private func record(into queue: RecoveryQueue, store: RecoveryStore) throws -> RecoveryDraft {
        try queue.begin(id: UUID(), settings: AppSettings())
        var draft = try XCTUnwrap(queue.active)
        try store.append(AudioChunk(data: WaveEncoder.encode([0.1, 0.2, 0, -0.1]), duration: 0.25, overlapsPrevious: false), to: &draft)
        queue.active = draft
        return draft
    }
}
