import Foundation
import XCTest
import OpenTypelessCore
@testable import OpenTypeless

final class AudioDiagnosticsTests: XCTestCase {
    @MainActor func testOptInArchiveKeepsContinuousOriginalAndRemovesItWithEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AudioDiagnosticsStore(root: root), id = UUID()
        let original = WaveEncoder.encode([0, 0.1, 0, 0.0001, 0])
        try store.preserve(id: id, chunks: [], original: original)
        let folder = try XCTUnwrap(store.folder(for: id))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("recording.wav")), original)
        store.remove(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor func testArchiveKeepsExactUploadedAudioAndExpires() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AudioDiagnosticsStore(root: root)
        let now = Date(), id = UUID()
        let first = WaveEncoder.encode([0.1, 0.2, 0, -0.1])
        let second = WaveEncoder.encode([0.2, 0, -0.1, 0.3])
        try store.preserve(id: id, chunks: [(first, false), (second, true)], now: now)
        let folder = try XCTUnwrap(store.folder(for: id, now: now))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("chunk-0.wav")), first)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("chunk-1.wav")), second)
        let attrs = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("chunk-0.wav").path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
        XCTAssertNil(store.folder(for: id, now: now.addingTimeInterval(86_400)))
        store.prune(now: now.addingTimeInterval(86_401))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor func testArchiveIsBoundedAndDeletionRemovesAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AudioDiagnosticsStore(root: root)
        let now = Date(), ids = (0..<12).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            try store.preserve(id: id, chunks: [(WaveEncoder.encode([0.1]), false)], now: now.addingTimeInterval(Double(index)))
        }
        XCTAssertNil(store.folder(for: ids[0], now: now))
        XCTAssertNil(store.folder(for: ids[1], now: now))
        XCTAssertNotNil(store.folder(for: ids[2], now: now))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 10)
        store.remove(ids[11])
        XCTAssertNil(store.folder(for: ids[11], now: now))
    }
}
