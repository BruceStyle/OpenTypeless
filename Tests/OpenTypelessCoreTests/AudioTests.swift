import XCTest
@testable import OpenTypelessCore

final class AudioTests: XCTestCase {
    func testWaveHeaderAndClipping() {
        let data = WaveEncoder.encode([-2, 0, 2, .nan])
        XCTAssertEqual(data.count, 52)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(Array(data[24..<28]), [0x80, 0x3e, 0, 0]) // 16000 Hz
        XCTAssertEqual(Array(data[44..<52]), [1, 128, 0, 0, 255, 127, 0, 0])
    }
    func testSilenceDoesNotCreateRequests() {
        var chunker = AudioChunker(minimumSeconds: 1, maximumSeconds: 2)
        var chunks: [AudioChunk] = []
        for _ in 0..<50 { chunks += chunker.append(Array(repeating: 0, count: 1_600)) }
        chunks += chunker.finish()
        XCTAssertTrue(chunks.isEmpty)
        XCTAssertEqual(chunker.totalSamples, 80_000)
    }
    func testHardBoundaryKeepsTailAndDoesNotDuplicateFinalOverlap() {
        var chunker = AudioChunker(minimumSeconds: 1, maximumSeconds: 2)
        var chunks: [AudioChunk] = []
        for _ in 0..<20 { chunks += chunker.append(Array(repeating: 0.1, count: 1_600)) }
        XCTAssertEqual(chunks.count, 1)
        XCTAssertFalse(chunks[0].overlapsPrevious)
        XCTAssertTrue(chunker.finish().isEmpty, "An overlap alone is not a new audio segment")
    }
    func testShortFinalSpeechIsKeptAfterBoundary() {
        var chunker = AudioChunker(minimumSeconds: 1, maximumSeconds: 2)
        for _ in 0..<20 { _ = chunker.append(Array(repeating: 0.1, count: 1_600)) }
        _ = chunker.append(Array(repeating: 0.1, count: 800))
        let last = chunker.finish()
        XCTAssertEqual(last.count, 1)
        XCTAssertTrue(last[0].overlapsPrevious)
        XCTAssertEqual(last[0].duration, 0.55, accuracy: 0.001)
    }
    func testNaturalSilenceBoundaryHasNoOverlap() {
        var chunker = AudioChunker(minimumSeconds: 1, maximumSeconds: 2)
        var chunks: [AudioChunk] = []
        for _ in 0..<10 { chunks += chunker.append(Array(repeating: 0.1, count: 1_600)) }
        for _ in 0..<6 { chunks += chunker.append(Array(repeating: 0, count: 1_600)) }
        _ = chunker.append(Array(repeating: 0.1, count: 1_600))
        chunks += chunker.finish()
        XCTAssertEqual(chunks.count, 2)
        XCTAssertFalse(chunks[1].overlapsPrevious)
    }
    func testTranscriptBoundaryDeduplicationPreservesIntentionalRepetition() {
        XCTAssertEqual(TranscriptAssembler.append("不要改公共组件。", to: "不要改公共组件。", overlapping: false), "不要改公共组件。\n不要改公共组件。")
        XCTAssertEqual(TranscriptAssembler.append("公共组件，先预览。", to: "不要改公共组件", overlapping: true), "不要改公共组件，先预览。")
        XCTAssertEqual(TranscriptAssembler.append("改成 SwiftUI。", to: "使用 React。", overlapping: true), "使用 React。\n改成 SwiftUI。")
    }
    func testFiveMinuteSpeechStaysBoundedAndPreservesSamples() {
        var chunker = AudioChunker()
        var chunks: [AudioChunk] = []
        for _ in 0..<3_000 { chunks += chunker.append(Array(repeating: 0.08, count: 1_600)) }
        chunks += chunker.finish()
        XCTAssertEqual(chunker.totalSamples, 4_800_000)
        XCTAssertTrue(chunks.allSatisfy { $0.duration <= 15.11 })
        let uniqueDuration = chunks.reduce(0) { $0 + $1.duration - ($1.overlapsPrevious ? 0.5 : 0) }
        XCTAssertEqual(uniqueDuration, 300, accuracy: 0.01)
    }
    func testLongDictationStartsUploadingBeforeStopAndKeepsEverySample() {
        var chunker = AudioChunker()
        var chunks: [AudioChunk] = []
        for _ in 0..<368 { chunks += chunker.append(Array(repeating: 0.08, count: 1_600)) }
        XCTAssertEqual(chunks.count, 2, "A 36.8-second dictation must already have submitted two chunks before stop")
        let tail = chunker.finish()
        XCTAssertEqual(tail.count, 1)
        XCTAssertLessThan(tail[0].duration, 8)
        chunks += tail
        let uniqueDuration = chunks.reduce(0) { $0 + $1.duration - ($1.overlapsPrevious ? 0.5 : 0) }
        XCTAssertEqual(uniqueDuration, 36.8, accuracy: 0.01)
    }
    func testBriefPunctuationPauseSplitsWithoutCuttingTheNextPhrase() {
        var chunker = AudioChunker()
        let samples = Array(repeating: Float(0.08), count: 9 * 16_000)
            + Array(repeating: Float(0), count: 4_160)
            + Array(repeating: Float(0.08), count: 16_007)
        var chunks: [AudioChunk] = []
        // Deliberately misaligned callback sizes must not hide the 260 ms pause.
        for start in stride(from: 0, to: samples.count, by: 1_013) {
            chunks += chunker.append(Array(samples[start..<min(samples.count, start + 1_013)]))
        }
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].duration, 9.24, accuracy: 0.001)
        chunks += chunker.finish()
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { !$0.overlapsPrevious })
        let joined = chunks.reduce(Data()) { $0 + $1.data.dropFirst(44) }
        XCTAssertEqual(joined, WaveEncoder.encode(samples).dropFirst(44), "No samples, including the incomplete final frame, may disappear")
    }
}
