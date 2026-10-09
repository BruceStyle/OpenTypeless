import Foundation
import XCTest
import OpenTypelessCore
@testable import OpenTypeless

final class DictionaryLearningStoreTests: XCTestCase {
    @MainActor func testLatinAndChineseEditsAreImmediatelyActiveAndPersistPrivately() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LearnedDictionaryStore(root: root)
        let latin = try XCTUnwrap(store.learn(.init(original: "CodePliot", replacement: "CodePilot")))
        let chinese = try XCTUnwrap(store.learn(.init(original: "扣得克斯", replacement: "Codex")))
        let reopened = LearnedDictionaryStore(root: root)
        XCTAssertEqual(Set(reopened.active.map(\.id)), [latin.word.id, chinese.word.id])
        XCTAssertTrue(reopened.words.allSatisfy { $0.status == .active })
        let file = root.appendingPathComponent("learned-dictionary.json")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let json = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(json.contains("baseline")); XCTAssertFalse(json.contains("transcript"))
    }
    @MainActor func testUndoRetractsWordUntilAnotherExplicitCorrection() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LearnedDictionaryStore(root: root)
        let correction = WordCorrection(original: "CodePliot", replacement: "CodePilot")
        let change = try XCTUnwrap(store.learn(correction))
        XCTAssertTrue(store.undo(change))
        let reopened = LearnedDictionaryStore(root: root)
        XCTAssertTrue(reopened.active.isEmpty)
        XCTAssertNotNil(reopened.learn(correction))
        XCTAssertEqual(reopened.active.first?.id, change.word.id)
        XCTAssertEqual(reopened.words.count, 1)
    }
    @MainActor func testAdditionalAliasesStayActiveAndCanBeEditedWithoutConfirmation() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LearnedDictionaryStore(root: root)
        let first = try XCTUnwrap(store.learn(.init(original: "扣得派洛特", replacement: "CodePilot")))
        let second = try XCTUnwrap(store.learn(.init(original: "codepilot", replacement: "CodePilot")))
        XCTAssertEqual(second.word.id, first.word.id)
        XCTAssertEqual(store.active.first?.variants, ["扣得派洛特", "codepilot"])
        XCTAssertNil(store.learn(.init(original: "codepilot", replacement: "CodePilot")))
        XCTAssertTrue(store.edit(first.word.id, term: "CodePilot Pro"))
        XCTAssertEqual(store.active.first?.term, "CodePilot Pro")
        XCTAssertEqual(store.active.count, 1)
    }
    @MainActor func testFailedLearningAndMigrationWritesDoNotReportSuccess() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LearnedDictionaryStore(root: root)
        let correction = WordCorrection(original: "SwfitUI", replacement: "SwiftUI")
        try Data("not a directory".utf8).write(to: root)
        XCTAssertNil(store.learn(correction))
        XCTAssertFalse(store.migrateExistingWords(["SwiftUI"]))
        XCTAssertTrue(store.words.isEmpty); XCTAssertNotNil(store.storageError)
    }
    @MainActor func testMigratedWordCanLearnAliasesAndCorrectCapitalization() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LearnedDictionaryStore(root: root)
        XCTAssertTrue(store.migrateExistingWords(["codepilot"]))
        let change = try XCTUnwrap(store.learn(.init(original: "codepilot", replacement: "CodePilot")))
        var settings = AppSettings(); settings.dictionary = "codepilot"
        let rewriteSettings = DictionaryVocabulary.settings(settings, words: store.words, transcript: "用 codepilot")
        XCTAssertEqual(rewriteSettings.vocabulary, ["CodePilot"])
        XCTAssertEqual(settings.dictionary, "codepilot")
        XCTAssertEqual(change.previous?.term, "codepilot")
        XCTAssertEqual(rewriteSettings.spellingCorrections, [.init(heard: "codepilot", preferred: "CodePilot")])
    }
    @MainActor func testCorruptFileIsNotSilentlyOverwritten() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("learned-dictionary.json"), bytes = Data("damaged".utf8)
        try bytes.write(to: file)
        let store = LearnedDictionaryStore(root: root)
        XCTAssertFalse(store.migrateExistingWords(["Codex"]))
        XCTAssertNil(store.learn(.init(original: "SwfitUI", replacement: "SwiftUI")))
        XCTAssertNotNil(store.storageError); XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    @MainActor func testLegacyMigrationActivatesPendingPreservesAliasesAndDoesNotReviveRemovals() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let pending = LearnedWord(term: "Typeless", variants: ["tablets"], status: .pending)
        let removed = LearnedWord(term: "RemovedName", variants: ["wrongname"], status: .excluded)
        struct LegacyDocument: Encodable { var version = 1; let words: [LearnedWord] }
        let file = root.appendingPathComponent("learned-dictionary.json")
        try LocalFiles.write(LegacyDocument(words: [pending, removed]), to: file)
        let store = LearnedDictionaryStore(root: root)
        let legacy = ["Codex", "ChatGPT", "codex", "Typeless", "RemovedName"]
        XCTAssertTrue(store.migrateExistingWords(legacy))
        XCTAssertEqual(Set(store.active.map(\.term)), ["Typeless", "Codex", "ChatGPT"])
        let migrated = try XCTUnwrap(store.active.first { $0.id == pending.id })
        XCTAssertEqual(migrated.variants, ["tablets"])
        XCTAssertEqual(migrated.confirmations, pending.confirmations)
        XCTAssertEqual(store.words.first { $0.id == removed.id }?.status, .excluded)
        XCTAssertEqual(store.active.first { $0.term == "Codex" }?.variants, [])
        let saved = try Data(contentsOf: file)
        let reopened = LearnedDictionaryStore(root: root)
        XCTAssertTrue(reopened.migrateExistingWords(legacy))
        XCTAssertEqual(try Data(contentsOf: file), saved, "Repeated migration must not duplicate or revive entries")
        let settings = DictionaryVocabulary.settings(AppSettings(), words: reopened.words, transcript: "Tablets")
        XCTAssertEqual(settings.spellingCorrections, [.init(heard: "tablets", preferred: "Typeless")])
    }
    @MainActor func testUndoAliasAdditionRetainsThePreviouslySavedWord() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LearnedDictionaryStore(root: root)
        XCTAssertTrue(store.migrateExistingWords(["Codex"]))
        let before = store.active
        let change = try XCTUnwrap(store.learn(.init(original: "扣得克斯", replacement: "Codex")))
        XCTAssertEqual(store.active.first?.variants, ["扣得克斯"])
        XCTAssertTrue(store.undo(change))
        XCTAssertEqual(store.active, before)
        XCTAssertEqual(LearnedDictionaryStore(root: root).active, before)
    }
    @MainActor func testOldUndoCannotOverwriteALaterEditOrRemoval() throws {
        for remove in [false, true] {
            let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let store = LearnedDictionaryStore(root: root)
            let change = try XCTUnwrap(store.learn(.init(original: "tablets", replacement: "Typeless")))
            if remove { XCTAssertTrue(store.exclude(change.word.id)) }
            else { XCTAssertTrue(store.edit(change.word.id, term: "TypeLess Pro")) }
            let before = store.words
            XCTAssertFalse(store.undo(change))
            XCTAssertEqual(store.words, before)
        }
    }
    @MainActor func testNewCorrectionRestoresOnlyTheNewAliasOfARemovedWord() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LearnedDictionaryStore(root: root)
        let first = try XCTUnwrap(store.learn(.init(original: "tablets", replacement: "Typeless")))
        XCTAssertTrue(store.exclude(first.word.id))
        let restored = try XCTUnwrap(store.learn(.init(original: "tableless", replacement: "Typeless")))
        XCTAssertEqual(store.active.first?.variants, ["tableless"])
        XCTAssertTrue(store.undo(restored))
        XCTAssertTrue(store.active.isEmpty)
    }
    @MainActor func testCancelledOrDisabledObserverDiscardsAnOutstandingRead() async throws {
        for disabled in [true, false] {
            let service = CorrectionLearningService()
            let receipt = InsertionReceipt(baseline: "CodePliot", range: NSRange(location: 0, length: 9), insertedText: "CodePliot")!
            var continuation: CheckedContinuation<String?, Never>?
            var enabled = true
            var reads = 0
            service.start(receipt: receipt, enabled: { enabled }, read: {
                reads += 1
                return await withCheckedContinuation { continuation = $0 }
            }, interval: .milliseconds(1), receive: { _ in XCTFail("Cancelled observation must not deliver a correction") })
            for _ in 0..<100 where continuation == nil { try await Task.sleep(for: .milliseconds(2)) }
            XCTAssertNotNil(continuation)
            if disabled { enabled = false } else { service.stop() }
            continuation?.resume(returning: "CodePilot")
            try await Task.sleep(for: .milliseconds(15))
            XCTAssertEqual(reads, 1)
            service.stop()
        }
    }
    @MainActor func testObserverDeliversOnlySettledCandidateAndStopsWhenFieldDisappears() async throws {
        let service = CorrectionLearningService()
        let receipt = InsertionReceipt(baseline: "CodePliot", range: NSRange(location: 0, length: 9), insertedText: "CodePliot")!
        var time: TimeInterval = 0, reads = 0
        var events: [CorrectionObservation.Event] = []
        service.start(receipt: receipt, enabled: { true }, read: {
            reads += 1; time += 1
            return reads < 6 ? "CodePilot" : nil
        }, interval: .milliseconds(1), now: { time }, receive: { events.append($0) })
        for _ in 0..<100 where reads < 6 { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(events, [.learn(.init(original: "CodePliot", replacement: "CodePilot"))])
        try await Task.sleep(for: .milliseconds(10)); XCTAssertEqual(reads, 6)
        service.stop()
    }
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("DictionaryTests-\(UUID().uuidString)") }

    @MainActor func testLateWebReadbackLearnsTypelessForImmediateUseWithoutConfirmation() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LearnedDictionaryStore(root: root), service = CorrectionLearningService()
        let expectation = InsertionExpectation(before: "前文\n", selection: NSRange(location: 0, length: 0), insertedText: "比如说 tablets。")!
        var time: TimeInterval = 0, reads = 0
        var states: [CorrectionLearningService.Status] = []
        service.start(expectation: expectation, enabled: { true }, read: {
            reads += 1; time += 0.5
            if reads <= 2 { return "前文\n" }
            if reads == 3 { return "前文\n比如说 tablets。\n" }
            return reads < 12 ? "前文\n比如说 Typeless。\n" : nil
        }, interval: .milliseconds(1), now: { time }, status: { states.append($0) }, receive: { event in
            if case .learn(let correction) = event { _ = store.learn(correction) }
        })
        for _ in 0..<100 where reads < 12 { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(states.contains(.awaitingPaste)); XCTAssertTrue(states.contains(.observing))
        XCTAssertEqual(store.active.map(\.term), ["Typeless"])
        let reopened = LearnedDictionaryStore(root: root)
        XCTAssertEqual(reopened.active.first?.variants, ["tablets"])
        let settings = DictionaryVocabulary.settings(AppSettings(), words: reopened.words, transcript: "Tablets")
        XCTAssertEqual(settings.spellingCorrections, [.init(heard: "tablets", preferred: "Typeless")])
        service.stop()
    }
    @MainActor func testUnconfirmedPasteTimesOutWithoutObservingOrLearning() async throws {
        let service = CorrectionLearningService()
        let expectation = InsertionExpectation(before: "", selection: nil, insertedText: "tablets")!
        var time: TimeInterval = 0, reads = 0
        var states: [CorrectionLearningService.Status] = []
        service.start(expectation: expectation, enabled: { true }, read: {
            reads += 1; time += 1; return ""
        }, interval: .milliseconds(1), now: { time }, status: { states.append($0) }, receive: { _ in XCTFail("No confirmed paste") })
        for _ in 0..<100 where !states.contains(.unconfirmed) { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(states, [.awaitingPaste, .unconfirmed]); XCTAssertEqual(reads, 5)
        service.stop()
    }
    @MainActor func testNewObservationDiscardsOldPendingReadback() async throws {
        let service = CorrectionLearningService()
        let expectation = InsertionExpectation(before: "", selection: nil, insertedText: "tablets")!
        var late: CheckedContinuation<String?, Never>?
        var oldStates: [CorrectionLearningService.Status] = []
        service.start(expectation: expectation, enabled: { true }, read: {
            await withCheckedContinuation { late = $0 }
        }, interval: .milliseconds(1), status: { oldStates.append($0) }, receive: { _ in XCTFail("Old session") })
        for _ in 0..<100 where late == nil { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNotNil(late)
        service.start(expectation: expectation, enabled: { true }, read: { nil }, interval: .milliseconds(1), receive: { _ in XCTFail("No field") })
        late?.resume(returning: "tablets\n")
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(oldStates, [.awaitingPaste])
        service.stop()
    }
}
