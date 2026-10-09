import Foundation
import XCTest
import OpenTypelessCore
@testable import OpenTypeless

private actor ScriptedSpeech: SpeechClient {
    var responses: [Result<InferenceResult, SpeechFailure>]
    private(set) var audio: [Data] = []
    private(set) var models: [String] = []
    init(_ responses: [Result<InferenceResult, SpeechFailure>]) { self.responses = responses }
    func transcribe(audio: Data, model: String, key: String) async throws -> InferenceResult {
        self.audio.append(audio)
        models.append(model)
        guard !responses.isEmpty else { throw SpeechFailure(.request) }
        return try responses.removeFirst().get()
    }
    func rewrite(text: String, settings: AppSettings, key: String) async throws -> InferenceResult {
        XCTFail("Recognition must not independently rewrite or deliver")
        return InferenceResult(text: text, cost: 0)
    }
}

/// Intentionally ignores cancellation to reproduce late provider responses.
private actor ControlledSpeech: SpeechClient {
    private(set) var audio: [Data] = []
    private(set) var models: [String] = []
    private var pending: [Int: CheckedContinuation<InferenceResult, Error>] = [:]
    func transcribe(audio: Data, model: String, key: String) async throws -> InferenceResult {
        let index = self.audio.count
        self.audio.append(audio)
        models.append(model)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func reply(_ index: Int, _ result: Result<InferenceResult, SpeechFailure>) {
        pending.removeValue(forKey: index)?.resume(with: result.mapError { $0 as Error })
    }
    func releaseAll() {
        let saved = pending; pending = [:]
        for item in saved.values { item.resume(throwing: CancellationError()) }
    }
    func rewrite(text: String, settings: AppSettings, key: String) async throws -> InferenceResult {
        XCTFail("Unexpected rewrite")
        return InferenceResult(text: text, cost: 0)
    }
}

private actor DelayedSpeech: SpeechClient {
    private var active = 0
    private(set) var peak = 0
    private var count = 0
    func transcribe(audio: Data, model: String, key: String) async throws -> InferenceResult {
        let index = count; count += 1; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(200))
        return InferenceResult(text: "第\(index + 1)句", cost: 0)
    }
    func rewrite(text: String, settings: AppSettings, key: String) async throws -> InferenceResult {
        XCTFail("Recognition must not rewrite")
        return InferenceResult(text: text, cost: 0)
    }
}

final class RecognitionSessionTests: XCTestCase {
    private func text(_ value: String) -> Result<InferenceResult, SpeechFailure> { .success(.init(text: value, cost: 0.001)) }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("RecognitionTests-\(UUID())") }

    @MainActor private func fixture(root: URL, samples: [Float], client: any SpeechClient,
                                   policy: RecognitionPolicy = RecognitionPolicy(), settings: AppSettings = AppSettings()) throws -> (RecognitionSession, RecoveryStore) {
        let store = RecoveryStore(root: root)
        var draft = try store.create(id: UUID(), settings: settings)
        let url = try store.prepareOriginal(in: &draft)
        try WaveEncoder.pcm(samples).write(to: url)
        return (RecognitionSession(draft: draft, store: store, client: client, key: "fixture", policy: policy, onUpdate: { _ in }), store)
    }

    @MainActor private func waitFor(_ condition: @escaping @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for a controlled request", file: file, line: line)
        throw CancellationError()
    }

    @MainActor func testShortRecordingIncludesEverySampleAndNeverSendsTinyTail() async throws {
        for tail in [1, 932, 1_600, 16_000, 17_274] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let samples = Array(repeating: Float(0.08), count: 13 * 16_000) + Array(repeating: Float(0), count: 8_320)
                + Array(repeating: Float(0.02), count: tail)
            let client = ScriptedSpeech([text("前文以及最后一个词")])
            let (session, _) = try fixture(root: root, samples: samples, client: client)
            var chunker = AudioChunker(includeQuietAudio: true)
            let chunks = chunker.append(samples)
            try session.receive(chunks, seconds: Double(samples.count) / 16_000)
            let early = await client.audio
            XCTAssertTrue(early.isEmpty)
            try session.seal(.init(chunks: chunker.finish(), seconds: Double(samples.count) / 16_000))
            _ = try await session.finish()
            let requests = await client.audio
            XCTAssertEqual(requests, [WaveEncoder.encode(samples)])
            XCTAssertEqual(session.draft.rawText, "前文以及最后一个词")
            XCTAssertTrue(session.draft.completeTranscript)
        }
    }

    @MainActor func testAlreadyRecognizedLongRecordingTailReplacesPreviousTextWithoutDuplication() async throws {
        for tail in [1, 932, 1_600, 16_000, 17_274] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let count = 472_000 + tail // 29.5 seconds, exactly two hard chunks, plus the short tail.
            let samples = Array(repeating: Float(0.08), count: count)
            let client = ScriptedSpeech([text("开头"), text("主体"), text("主体，最后不要发布。")])
            let (session, _) = try fixture(root: root, samples: samples, client: client, policy: RecognitionPolicy(shortRecordingSeconds: 20))
            var chunker = AudioChunker(includeQuietAudio: true)
            try session.receive(chunker.append(Array(samples.prefix(472_000))), seconds: 29.5)
            try await waitFor { session.draft.chunks.filter { $0.result != nil }.count == 2 }
            _ = chunker.append(Array(samples.suffix(tail)))
            try session.seal(.init(chunks: chunker.finish(), seconds: Double(count) / 16_000))
            _ = try await session.finish()
            let requests = await client.audio
            XCTAssertEqual(requests.count, 3)
            XCTAssertEqual(requests.last, WaveEncoder.encode(Array(samples[232_000..<count])))
            XCTAssertEqual(session.draft.rawText, "开头\n主体，最后不要发布。")
        }
    }

    @MainActor func testMiddleFailureDoesNotPreventLaterRequestAndWholeRecordingRecovers() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let samples = Array(repeating: Float(0.08), count: 45 * 16_000)
        let client = ScriptedSpeech([text("开头"), .failure(.init(.temporary, status: 503)), text("结尾"), text("完整的开头中间结尾")])
        let (session, _) = try fixture(root: root, samples: samples, client: client)
        for index in 0..<3 {
            let range = index * 240_000..<(index + 1) * 240_000
            try session.receive([.init(data: WaveEncoder.encode(Array(samples[range])), duration: 15, overlapsPrevious: false,
                                      startSample: range.lowerBound, endSample: range.upperBound)], seconds: Double(index + 1) * 15)
        }
        try session.seal(.init(seconds: 45))
        _ = try await session.finish()
        let requests = await client.audio
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.last, WaveEncoder.encode(samples))
        XCTAssertEqual(session.draft.rawText, "完整的开头中间结尾")
        XCTAssertEqual(session.draft.attempts?.last?.source, "whole")
        XCTAssertNil(CostTotal.sum(session.draft.recognitionCosts), "A failed request's unknown cost must not disappear")
    }

    @MainActor func testEmptyFallbackPreservesBodyAndStopsBoundedly() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let samples = Array(repeating: Float(0.08), count: 30 * 16_000)
        let client = ScriptedSpeech([text("已有正文"), .failure(.init(.noText, cost: 0.001)), .failure(.init(.noText, cost: 0.002))])
        let (session, store) = try fixture(root: root, samples: samples, client: client, policy: RecognitionPolicy(shortRecordingSeconds: 20))
        for index in 0..<2 {
            let range = index * 240_000..<(index + 1) * 240_000
            try session.receive([.init(data: WaveEncoder.encode(Array(samples[range])), duration: 15, overlapsPrevious: false,
                                      startSample: range.lowerBound, endSample: range.upperBound)], seconds: Double(index + 1) * 15)
        }
        try session.seal(.init(seconds: 30))
        do { _ = try await session.finish(); XCTFail("Empty is not a complete candidate") }
        catch { XCTAssertEqual((error as? SpeechFailure)?.kind, .noText) }
        let requests = await client.audio
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(session.draft.rawText, "已有正文")
        XCTAssertFalse(session.draft.completeTranscript)
        XCTAssertEqual(store.recoverable().first?.rawText, "已有正文")
        XCTAssertEqual(session.draft.attempts?.last?.cost, 0.002)
    }

    @MainActor func testDigitalSilenceEndsNormallyButNoisyEmptyResultRemainsReviewable() async throws {
        for level: Float in [0, 0.0001, 0.1] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let samples = Array(repeating: level, count: 32_000)
            let client = ScriptedSpeech([.failure(.init(.noText))])
            let (session, _) = try fixture(root: root, samples: samples, client: client)
            try session.seal(.init(seconds: 2))
            if level == 0 {
                guard case .noSpeech = try await session.finish() else { return XCTFail("Silence is a normal outcome") }
                let requests = await client.audio; XCTAssertTrue(requests.isEmpty)
            } else {
                do { _ = try await session.finish(); XCTFail("Energy does not prove speech or its absence") }
                catch { XCTAssertEqual((error as? SpeechFailure)?.kind, .noText) }
                let requests = await client.audio; XCTAssertEqual(requests.count, 1)
            }
        }
    }

    @MainActor func testAccountAndConfigurationErrorsDoNotTriggerRepeatedRequests() async throws {
        for failure in [SpeechFailure(.account, status: 401), SpeechFailure(.account, status: 402), SpeechFailure(.request, status: 400)] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let samples = Array(repeating: Float(0.1), count: 45 * 16_000)
            let client = ScriptedSpeech([.failure(failure), .failure(failure)])
            let (session, _) = try fixture(root: root, samples: samples, client: client)
            var chunker = AudioChunker(includeQuietAudio: true)
            try session.receive(chunker.append(samples), seconds: 45)
            try session.seal(.init(chunks: chunker.finish(), seconds: 45))
            do { _ = try await session.finish(); XCTFail("Must report actionable failure") }
            catch { XCTAssertEqual(error as? SpeechFailure, failure) }
            let requests = await client.audio
            XCTAssertTrue((1...2).contains(requests.count), "At most the two already in-flight requests; no retry after an account/configuration failure")
        }
    }

    @MainActor func testLegacyShortTailUsesSavedContextAndDoesNotModifyOriginalFiles() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root)
        var draft = try store.create(id: UUID(), settings: AppSettings())
        let first = WaveEncoder.encode(Array(repeating: Float(0.1), count: 128_000))
        let tail = WaveEncoder.encode(Array(repeating: Float(0.2), count: 932))
        try store.append(.init(data: first, duration: 8, overlapsPrevious: false), to: &draft)
        draft.chunks[0].result = .init(text: "已有正文", cost: 0.001)
        try store.append(.init(data: tail, duration: 0.05825, overlapsPrevious: false), to: &draft)
        let old = draft.chunks
        let client = ScriptedSpeech([text("已有正文和末尾")])
        let session = RecognitionSession(draft: draft, store: store, client: client, key: "fixture", onUpdate: { _ in })
        try session.prepareRetry()
        _ = try await session.finish()
        XCTAssertNil(session.draft.originalAudio)
        let requests = await client.audio
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].dropFirst(44), first.dropFirst(44) + tail.dropFirst(44))
        XCTAssertEqual(try store.audio(old[0], id: draft.id), first)
        XCTAssertEqual(try store.audio(old[1], id: draft.id), tail)
        XCTAssertEqual(session.draft.rawText, "已有正文和末尾")
        XCTAssertNil(CostTotal.sum(session.draft.recognitionCosts), "An old failed request has unknown billing")
    }

    @MainActor func testInterruptedRecordingDiscoversUnsavedSamplesAndStaysMarkedInterrupted() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let samples = Array(repeating: Float(0.001), count: 2 * 16_000 + 17)
        let client = ScriptedSpeech([text("恢复的录音")])
        let (_, store) = try fixture(root: root, samples: samples, client: client)
        let draft = try XCTUnwrap(store.recoverable().first)
        XCTAssertEqual(draft.originalAudio?.sampleCount, samples.count)
        XCTAssertFalse(draft.originalAudio!.complete)
        let session = RecognitionSession(draft: draft, store: store, client: client, key: "fixture", onUpdate: { _ in })
        try session.prepareRetry()
        _ = try await session.finish()
        XCTAssertEqual(session.draft.rawText, "恢复的录音")
        XCTAssertFalse(session.draft.originalAudio!.complete, "Recovered capture must remain preview-only")
        let requests = await client.audio; XCTAssertEqual(requests, [WaveEncoder.encode(samples)])
    }

    @MainActor func testCompletedTranscriptRetryDoesNotRepeatSpeechRecognition() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root)
        var draft = try store.create(id: UUID(), settings: AppSettings())
        draft.rawText = "不要发布，先预览"; draft.completeTranscript = true
        let client = ScriptedSpeech([])
        let session = RecognitionSession(draft: draft, store: store, client: client, key: "fixture", onUpdate: { _ in })
        try session.prepareRetry(); _ = try await session.finish()
        XCTAssertEqual(session.draft.rawText, draft.rawText)
        let requests = await client.audio; XCTAssertTrue(requests.isEmpty)
    }

    @MainActor func testLongRecordingUsesBoundedContextWindowsAndDoesNotDuplicateEarlierRepair() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let samples = Array(repeating: Float(0.08), count: 135 * 16_000)
        let replies: [Result<InferenceResult, SpeechFailure>] = (0..<9).map { [2, 4].contains($0) ? .failure(.init(.temporary)) : text("句\($0)") }
        let client = ScriptedSpeech(replies + [text("句1，句2，句3"), text("句4，句5")])
        let (session, _) = try fixture(root: root, samples: samples, client: client)
        for index in 0..<9 {
            let range = index * 240_000..<(index + 1) * 240_000
            try session.receive([.init(data: WaveEncoder.encode(Array(samples[range])), duration: 15, overlapsPrevious: false,
                                      startSample: range.lowerBound, endSample: range.upperBound)], seconds: Double(index + 1) * 15)
        }
        try session.seal(.init(seconds: 135)); _ = try await session.finish()
        let requests = await client.audio
        XCTAssertEqual(requests.count, 11)
        XCTAssertTrue(requests.allSatisfy { $0.count <= 44 + 60 * 32_000 })
        XCTAssertEqual(session.draft.rawText, "句0\n句1，句2，句3\n句4，句5\n句6\n句7\n句8")
        XCTAssertEqual(session.draft.recognitionStatistics?.acceptedSource, "context")
        XCTAssertEqual(session.draft.recognitionStatistics?.recoveryRequests, 2)
        XCTAssertEqual(session.draft.recognitionStatistics?.unknownCostRequests, 2)
    }

    @MainActor func testManyMissingIntervalsStopAtRecoveryBudgetAndKeepSuccessfulRepairs() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let samples = Array(repeating: Float(0.08), count: 165 * 16_000)
        let replies: [Result<InferenceResult, SpeechFailure>] = (0..<11).map { [1, 5, 9].contains($0) ? .failure(.init(.noText)) : text("句\($0)") }
        let client = ScriptedSpeech(replies + [text("已恢复012"), text("已恢复456")])
        let (session, _) = try fixture(root: root, samples: samples, client: client)
        for index in 0..<11 {
            let range = index * 240_000..<(index + 1) * 240_000
            try session.receive([.init(data: WaveEncoder.encode(Array(samples[range])), duration: 15, overlapsPrevious: false,
                                      startSample: range.lowerBound, endSample: range.upperBound)], seconds: Double(index + 1) * 15)
        }
        try session.seal(.init(seconds: 165))
        do { _ = try await session.finish(); XCTFail("Unrepaired interval cannot auto-deliver") } catch { }
        let requests = await client.audio; XCTAssertEqual(requests.count, 13)
        XCTAssertTrue(session.draft.rawText.contains("已恢复012"))
        XCTAssertTrue(session.draft.rawText.contains("已恢复456"))
        XCTAssertTrue(session.draft.rawText.contains("句10"))
        XCTAssertFalse(session.draft.completeTranscript)
    }

    @MainActor func testFailedLegacyReplacementRetainsPreviouslyRecognizedBody() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStore(root: root)
        var draft = try store.create(id: UUID(), settings: AppSettings())
        try store.append(.init(data: WaveEncoder.encode(Array(repeating: Float(0.1), count: 128_000)), duration: 8, overlapsPrevious: false), to: &draft)
        draft.chunks[0].result = .init(text: "不能丢失的正文", cost: 0.001)
        try store.append(.init(data: WaveEncoder.encode(Array(repeating: Float(0.1), count: 932)), duration: 0.05825, overlapsPrevious: false), to: &draft)
        let client = ScriptedSpeech([.failure(.init(.noText)), .failure(.init(.noText))])
        let session = RecognitionSession(draft: draft, store: store, client: client, key: "fixture", onUpdate: { _ in })
        try session.prepareRetry()
        do { _ = try await session.finish(); XCTFail("No complete transcript") } catch { }
        XCTAssertEqual(session.draft.rawText, "不能丢失的正文")
        XCTAssertEqual(store.recoverable().first?.rawText, "不能丢失的正文")
        XCTAssertFalse(session.draft.completeTranscript)
    }

    @MainActor func testPartialOriginalWriteFallsBackToSavedChunksWithoutLosingSamples() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let samples = Array(repeating: Float(0.1), count: 64_000)
        let client = ScriptedSpeech([text("完整的已保存片段")])
        let (session, store) = try fixture(root: root, samples: Array(samples.prefix(16_000)), client: client)
        do {
            try session.seal(.init(chunks: [.init(data: WaveEncoder.encode(samples), duration: 4, overlapsPrevious: false,
                                                 startSample: 0, endSample: samples.count)], seconds: 4))
            XCTFail("Partial storage must be reported")
        } catch { }
        session.cancel()
        let draft = try XCTUnwrap(store.recoverable().first)
        XCTAssertFalse(draft.canUseOriginal)
        XCTAssertEqual(draft.seconds, 4)
        let retry = RecognitionSession(draft: draft, store: store, client: client, key: "fixture", onUpdate: { _ in })
        try retry.prepareRetry(); _ = try await retry.finish()
        let requests = await client.audio; XCTAssertEqual(requests, [WaveEncoder.encode(samples)])
        XCTAssertFalse(retry.draft.originalAudio!.complete)
    }

    @MainActor func testShortWholeRecordingTransientFailureGetsOneBoundedRetry() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let samples = Array(repeating: Float(0.08), count: 48_000)
        let client = ScriptedSpeech([.failure(.init(.temporary)), text("恢复成功")])
        let (session, _) = try fixture(root: root, samples: samples, client: client)
        try session.seal(.init(seconds: 3)); _ = try await session.finish()
        let requests = await client.audio
        XCTAssertEqual(requests, [WaveEncoder.encode(samples), WaveEncoder.encode(samples)])
        XCTAssertEqual(session.draft.rawText, "恢复成功")
    }

    @MainActor func testDurationBoundariesUpToTenMinutesKeepCompleteCoverageAndBoundedRequests() async throws {
        for seconds in [10, 15, 20, 30, 60, 120, 600] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let samples = Array(repeating: Float(0.08), count: seconds * 16_000 + 1)
            let client = ScriptedSpeech(Array(repeating: text("文字"), count: 50))
            let (session, _) = try fixture(root: root, samples: samples, client: client)
            var chunker = AudioChunker(includeQuietAudio: true)
            try session.receive(chunker.append(samples), seconds: Double(samples.count) / 16_000)
            try session.seal(.init(chunks: chunker.finish(), seconds: Double(samples.count) / 16_000))
            _ = try await session.finish()
            let requests = await client.audio
            if seconds < 30 { XCTAssertEqual(requests, [WaveEncoder.encode(samples)]) }
            else { XCTAssertTrue(requests.allSatisfy { $0.count <= 44 + 60 * 32_000 }) }
            var covered = 0
            for chunk in session.draft.chunks {
                XCTAssertLessThanOrEqual(try XCTUnwrap(chunk.startSample), covered, "No unrecognized gap at \(seconds) seconds")
                covered = max(covered, try XCTUnwrap(chunk.endSample))
            }
            XCTAssertEqual(covered, samples.count)
        }
    }

    private func fallbackSettings(_ fallback: String = "qwen/qwen3-asr-1.7b") -> AppSettings {
        var settings = AppSettings()
        settings.transcriptionModel = "fish-audio/transcribe-1"
        settings.transcriptionFallbackModel = fallback
        return settings
    }

    @MainActor private func racingSession(root: URL, client: ControlledSpeech, fallback: String = "qwen/qwen3-asr-1.7b") throws -> RecognitionSession {
        var policy = RecognitionPolicy(); policy.backupDelay = .milliseconds(80)
        let samples = Array(repeating: Float(0.1), count: 3 * 16_000)
        let (session, _) = try fixture(root: root, samples: samples, client: client, policy: policy, settings: fallbackSettings(fallback))
        try session.receive([.init(data: WaveEncoder.encode(samples), duration: 3, overlapsPrevious: false,
                                  startSample: 0, endSample: samples.count)], seconds: 3)
        try session.seal(.init(seconds: 3))
        return session
    }

    @MainActor func testWholeRecordingThresholdIncludesThirtySecondsWithoutEarlyRequests() async throws {
        for count in [25 * 16_000, 30 * 16_000, 30 * 16_000 + 1] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let samples = Array(repeating: Float(0.08), count: count)
            let client = ScriptedSpeech(Array(repeating: text("完整上下文"), count: 5))
            let (session, _) = try fixture(root: root, samples: samples, client: client)
            var chunker = AudioChunker(includeQuietAudio: true)
            try session.receive(chunker.append(Array(samples.prefix(20 * 16_000))), seconds: 20)
            try await Task.sleep(for: .milliseconds(10))
            let before = await client.audio
            XCTAssertTrue(before.isEmpty)
            let seconds = Double(count) / 16_000
            try session.receive(chunker.append(Array(samples.dropFirst(20 * 16_000))), seconds: seconds)
            try await Task.sleep(for: .milliseconds(10))
            let early = await client.audio
            if seconds <= 30 { XCTAssertTrue(early.isEmpty) }
            else { XCTAssertFalse(early.isEmpty, "Longer recordings still process while recording") }
            try session.seal(.init(chunks: chunker.finish(), seconds: seconds))
            _ = try await session.finish()
            let audio = await client.audio
            if seconds <= 30 { XCTAssertEqual(audio, [WaveEncoder.encode(samples)]) }
            XCTAssertEqual(session.draft.chunks.last?.endSample, count)
        }
    }

    @MainActor func testDisabledOrDuplicateFallbackMakesNoTimeoutRequest() async throws {
        for fallback in ["", " fish-audio/transcribe-1 "] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let client = ControlledSpeech(), session = try racingSession(root: root, client: client, fallback: fallback)
            let finished = Task { try await session.finish() }
            try await waitFor { await client.audio.count == 1 }
            try await Task.sleep(for: .milliseconds(120))
            let count = await client.audio.count
            XCTAssertEqual(count, 1)
            await client.reply(0, text("主模型结果"))
            _ = try await finished.value
            XCTAssertEqual(session.draft.recognitionStatistics?.modelFallbackRequests, 0)
        }
    }

    @MainActor func testPrimaryFailureAfterTimeoutStillAllowsFallbackToFinish() async throws {
        for failure in [SpeechFailure(.temporary), SpeechFailure(.noText), SpeechFailure(.request, status: 400)] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let client = ControlledSpeech(), session = try racingSession(root: root, client: client)
            let finished = Task { try await session.finish() }
            try await waitFor { await client.audio.count == 2 }
            await client.reply(0, .failure(failure))
            try await waitFor { session.draft.chunks.first?.failure != nil }
            XCTAssertFalse(session.draft.completeTranscript)
            await client.reply(1, text("备用识别成功"))
            _ = try await finished.value
            XCTAssertEqual(session.draft.rawText, "备用识别成功")
        }
    }

    @MainActor func testFallbackModelErrorDoesNotDefeatValidPrimary() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ControlledSpeech(), session = try racingSession(root: root, client: client)
        let finished = Task { try await session.finish() }
        try await waitFor { await client.audio.count == 2 }
        await client.reply(1, .failure(.init(.request, status: 400)))
        try await waitFor { session.draft.attempts?.last?.outcome == .failed }
        await client.reply(0, text("主模型成功"))
        _ = try await finished.value
        XCTAssertEqual(session.draft.rawText, "主模型成功")
        XCTAssertEqual(session.draft.acceptedModels, ["fish-audio/transcribe-1"])
    }

    @MainActor func testBothModelsFailPreservesAudioAndDoesNotLoop() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ControlledSpeech(), session = try racingSession(root: root, client: client)
        let finished = Task { try await session.finish() }
        try await waitFor { await client.audio.count == 2 }
        await client.reply(1, .failure(.init(.temporary)))
        await client.reply(0, .failure(.init(.noText)))
        do { _ = try await finished.value; XCTFail("Neither request produced a transcript") } catch { }
        let count = await client.audio.count
        XCTAssertEqual(count, 2)
        XCTAssertFalse(session.draft.completeTranscript)
        let saved = try XCTUnwrap(RecoveryStore(root: root).recoverable().first)
        XCTAssertTrue(saved.canUseOriginal)
        XCTAssertEqual(saved.attempts?.count, 2)
    }

    @MainActor func testLongTimeoutFallbackUsesBoundedContextAndRecordsBothModels() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let samples = Array(repeating: Float(0.08), count: 135 * 16_000)
        let client = ControlledSpeech()
        var policy = RecognitionPolicy(); policy.backupDelay = .milliseconds(250)
        let (session, _) = try fixture(root: root, samples: samples, client: client, policy: policy, settings: fallbackSettings())
        for index in 0..<9 {
            let range = index * 240_000..<(index + 1) * 240_000
            try session.receive([.init(data: WaveEncoder.encode(Array(samples[range])), duration: 15, overlapsPrevious: false,
                                      startSample: range.lowerBound, endSample: range.upperBound)], seconds: Double(index + 1) * 15)
        }
        try session.seal(.init(seconds: 135))
        let finished = Task { try await session.finish() }
        for index in 0..<8 {
            try await waitFor { await client.audio.count >= index + 1 }
            await client.reply(index, text("句\(index)"))
        }
        try await waitFor { await client.audio.count == 10 }
        let requests = await client.audio, models = await client.models
        XCTAssertLessThanOrEqual(requests[9].count, 44 + 60 * 32_000)
        XCTAssertEqual(requests[9], WaveEncoder.encode(Array(samples[(105 * 16_000)...])))
        XCTAssertEqual(models[9], "qwen/qwen3-asr-1.7b")
        await client.reply(9, text("句7，句8"))
        _ = try await finished.value
        await client.reply(8, text("迟到的最后一句"))
        XCTAssertEqual(session.draft.rawText, "句0\n句1\n句2\n句3\n句4\n句5\n句6\n句7，句8")
        XCTAssertEqual(session.draft.acceptedModels, ["fish-audio/transcribe-1", "qwen/qwen3-asr-1.7b"])
    }

    @MainActor func testTwoPrimaryRequestsRunTogetherAndOutOfOrderRepliesKeepAudioOrder() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let samples = Array(repeating: Float(0.08), count: 45 * 16_000)
        let client = ControlledSpeech()
        let (session, _) = try fixture(root: root, samples: samples, client: client)
        for index in 0..<3 {
            let range = index * 240_000..<(index + 1) * 240_000
            try session.receive([.init(data: WaveEncoder.encode(Array(samples[range])), duration: 15, overlapsPrevious: false,
                                      startSample: range.lowerBound, endSample: range.upperBound)], seconds: Double(index + 1) * 15)
        }
        try session.seal(.init(seconds: 45))
        let finished = Task { try await session.finish() }
        try await waitFor { await client.audio.count == 2 }
        try await Task.sleep(for: .milliseconds(25))
        let inFlight = await client.audio.count
        XCTAssertEqual(inFlight, 2, "A third primary request must remain queued")
        await client.reply(1, text("第二句，不要发布。"))
        try await waitFor { await client.audio.count == 3 }
        await client.reply(2, text("第三句，先预览。"))
        try await waitFor { session.draft.chunks.last?.result != nil }
        XCTAssertFalse(session.draft.completeTranscript, "Later replies cannot hide an unfinished first segment")
        await client.reply(0, text("第一句"))
        _ = try await finished.value
        XCTAssertEqual(session.draft.rawText, "第一句\n第二句，不要发布。\n第三句，先预览。")
        XCTAssertEqual(session.draft.recognitionStatistics?.requests, 3)
        XCTAssertEqual(session.draft.recognitionStatistics?.recoveryRequests, 0)
    }

    @MainActor func testControlledLatencyComparisonPreservesTranscriptAndConcurrencyLimit() async throws {
        for limit in [1, 2] {
            let root = root(); defer { try? FileManager.default.removeItem(at: root) }
            let samples = Array(repeating: Float(0.08), count: 30 * 16_000)
            let client = DelayedSpeech()
            var policy = RecognitionPolicy(shortRecordingSeconds: 20); policy.maximumConcurrentPrimaryRequests = limit
            let (session, _) = try fixture(root: root, samples: samples, client: client, policy: policy)
            for index in 0..<2 {
                let range = index * 240_000..<(index + 1) * 240_000
                try session.receive([.init(data: WaveEncoder.encode(Array(samples[range])), duration: 15, overlapsPrevious: false,
                                          startSample: range.lowerBound, endSample: range.upperBound)], seconds: Double(index + 1) * 15)
            }
            try session.seal(.init(seconds: 30))
            let started = ProcessInfo.processInfo.systemUptime
            _ = try await session.finish()
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let peak = await client.peak
            XCTAssertEqual(peak, limit)
            XCTAssertEqual(session.draft.rawText, "第1句\n第2句")
            XCTAssertEqual(session.draft.recognitionStatistics?.requests, 2)
            print("LATENCY_SCHEDULER controlledRequestMs=200 concurrency=\(limit) elapsedMs=\(Int(elapsed * 1000))")
        }
    }

    @MainActor func testCancelledParallelRequestsNeverStartQueuedWork() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let samples = Array(repeating: Float(0.08), count: 45 * 16_000)
        let client = ControlledSpeech()
        let (session, _) = try fixture(root: root, samples: samples, client: client)
        for index in 0..<3 {
            let range = index * 240_000..<(index + 1) * 240_000
            try session.receive([.init(data: WaveEncoder.encode(Array(samples[range])), duration: 15, overlapsPrevious: false,
                                      startSample: range.lowerBound, endSample: range.upperBound)], seconds: Double(index + 1) * 15)
        }
        try session.seal(.init(seconds: 45))
        let finished = Task { try await session.finish() }
        try await waitFor { await client.audio.count == 2 }
        session.cancel()
        do { _ = try await finished.value; XCTFail("Cancelled") } catch is CancellationError { }
        await client.reply(0, text("过期第一句")); await client.reply(1, text("过期第二句"))
        try await Task.sleep(for: .milliseconds(25))
        let sent = await client.audio.count
        XCTAssertEqual(sent, 2)
        XCTAssertFalse(session.draft.completeTranscript)
        XCTAssertFalse(session.draft.rawText.contains("过期"))
    }

    @MainActor func testWholeBackupCanRescueTwoStalledPrimaryRequestsWithoutStartingQueuedSegments() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let samples = Array(repeating: Float(0.08), count: 45 * 16_000)
        let client = ControlledSpeech()
        var policy = RecognitionPolicy(); policy.backupDelay = .milliseconds(30)
        let (session, _) = try fixture(root: root, samples: samples, client: client, policy: policy, settings: fallbackSettings())
        for index in 0..<3 {
            let range = index * 240_000..<(index + 1) * 240_000
            try session.receive([.init(data: WaveEncoder.encode(Array(samples[range])), duration: 15, overlapsPrevious: false,
                                      startSample: range.lowerBound, endSample: range.upperBound)], seconds: Double(index + 1) * 15)
        }
        try session.seal(.init(seconds: 45))
        let finished = Task { try await session.finish() }
        try await waitFor { await client.audio.count == 3 }
        let requests = await client.audio
        XCTAssertEqual(requests[2], WaveEncoder.encode(samples), "One separate recovery slot must remain available")
        await client.reply(2, text("完整录音恢复的最终文字"))
        _ = try await finished.value
        await client.reply(0, text("旧第一段")); await client.reply(1, text("旧第二段"))
        try await Task.sleep(for: .milliseconds(25))
        let count = await client.audio.count
        XCTAssertEqual(count, 3)
        XCTAssertEqual(session.draft.rawText, "完整录音恢复的最终文字")
        XCTAssertEqual(session.draft.recognitionStatistics?.recoveryRequests, 1)
        XCTAssertEqual(session.draft.recognitionStatistics?.cancelledRequests, 2)
    }

    @MainActor func testTailReplacementWaitsForCancelledSlotAndIgnoresItsLateResponse() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let samples = Array(repeating: Float(0.08), count: 30 * 16_000)
        let client = ControlledSpeech()
        let (session, _) = try fixture(root: root, samples: samples, client: client, policy: RecognitionPolicy(shortRecordingSeconds: 20))
        var chunker = AudioChunker(includeQuietAudio: true)
        try session.receive(chunker.append(samples), seconds: 30)
        try await waitFor { await client.audio.count == 2 }
        try session.seal(.init(chunks: chunker.finish(), seconds: 30))
        let finished = Task { try await session.finish() }
        try await Task.sleep(for: .milliseconds(25))
        let sent = await client.audio.count
        XCTAssertEqual(sent, 2, "Cancellation-ignoring old requests still occupy a slot")
        await client.reply(1, text("过期的第二段"))
        try await waitFor { await client.audio.count == 3 }
        let audio = await client.audio
        XCTAssertEqual(audio[2], WaveEncoder.encode(Array(samples[232_000...])))
        await client.reply(2, text("第二段以及短尾词，不。"))
        await client.reply(0, text("第一段"))
        _ = try await finished.value
        XCTAssertEqual(session.draft.rawText, "第一段\n第二段以及短尾词，不。")
        XCTAssertEqual(session.draft.recognitionStatistics?.cancelledRequests, 1)
    }

    @MainActor func testFastPrimaryDoesNotStartBackup() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ControlledSpeech(), session = try racingSession(root: root, client: client)
        let finished = Task { try await session.finish() }
        try await waitFor { await client.audio.count == 1 }
        await client.reply(0, text("快速结果"))
        _ = try await finished.value
        try await Task.sleep(for: .milliseconds(120))
        let requests = await client.audio; XCTAssertEqual(requests.count, 1)
    }

    @MainActor func testBackupWinsAndLatePrimaryCannotOverwriteChosenResult() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ControlledSpeech(), session = try racingSession(root: root, client: client)
        let finished = Task { try await session.finish() }
        try await waitFor { await client.audio.count == 2 }
        let models = await client.models, audio = await client.audio
        XCTAssertEqual(models, ["fish-audio/transcribe-1", "qwen/qwen3-asr-1.7b"])
        XCTAssertEqual(audio[0], audio[1], "The fallback must hear every sample of the same recording")
        await client.reply(1, text("完整备用结果"))
        _ = try await finished.value
        await client.reply(0, text("迟到的主路结果"))
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(session.draft.rawText, "完整备用结果")
        XCTAssertEqual(session.draft.attempts?.filter { $0.outcome == .cancelled }.count, 1)
        XCTAssertNil(CostTotal.sum(session.draft.recognitionCosts))
        XCTAssertEqual(session.draft.recognitionStatistics?.acceptedModels, ["qwen/qwen3-asr-1.7b"])
        XCTAssertEqual(session.draft.recognitionStatistics?.modelFallbackRequests, 1)
    }

    @MainActor func testPrimaryWinsAfterBackupHasStartedAndCompletesOnlyOnce() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ControlledSpeech(), session = try racingSession(root: root, client: client)
        var deliveries = 0
        let finished = Task { _ = try await session.finish(); deliveries += 1 }
        try await waitFor { await client.audio.count == 2 }
        await client.reply(0, text("主路结果"))
        try await finished.value
        await client.reply(1, text("备用结果"))
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(session.draft.rawText, "主路结果")
        XCTAssertEqual(session.draft.acceptedModels, ["fish-audio/transcribe-1"])
    }

    @MainActor func testEmptyBackupCannotWinRace() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ControlledSpeech(), session = try racingSession(root: root, client: client)
        var deliveries = 0
        let finished = Task { _ = try await session.finish(); deliveries += 1 }
        try await waitFor { await client.audio.count == 2 }
        await client.reply(1, text(""))
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(deliveries, 0)
        await client.reply(0, text("正文"))
        try await finished.value
        XCTAssertEqual(session.draft.rawText, "正文")
        XCTAssertEqual(deliveries, 1)
    }

    @MainActor func testBothRepliesArrivingTogetherProduceOneCompletion() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ControlledSpeech(), session = try racingSession(root: root, client: client)
        var deliveries = 0
        let finished = Task { _ = try await session.finish(); deliveries += 1 }
        try await waitFor { await client.audio.count == 2 }
        async let first: Void = client.reply(0, text("主路"))
        async let second: Void = client.reply(1, text("备用"))
        _ = await (first, second)
        try await finished.value
        XCTAssertEqual(deliveries, 1)
        XCTAssertTrue(["主路", "备用"].contains(session.draft.rawText))
    }

    @MainActor func testCancelBothRequestsAndLateRepliesCannotDeliverOrContaminateNextSession() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let client = ControlledSpeech(), session = try racingSession(root: root, client: client)
        var deliveries = 0
        let finished = Task { _ = try await session.finish(); deliveries += 1 }
        try await waitFor { await client.audio.count == 2 }
        finished.cancel(); session.cancel()
        do { try await finished.value; XCTFail("Cancelled completion must throw") } catch is CancellationError { }
        let next = try racingSession(root: root, client: client)
        let nextFinished = Task { _ = try await next.finish() }
        try await waitFor { await client.audio.count >= 3 }
        await client.reply(0, text("旧的主路")); await client.reply(1, text("旧的备用"))
        await client.reply(2, text("新一条听写"))
        try await nextFinished.value
        XCTAssertEqual(deliveries, 0)
        XCTAssertEqual(next.draft.rawText, "新一条听写")
        XCTAssertFalse(session.draft.completeTranscript)
        await client.releaseAll()
    }
}
