import Foundation
import OpenTypelessCore

struct RecoveryDraft: Codable, Identifiable {
    struct Chunk: Codable {
        var file: String
        var overlap: Bool
        var result: InferenceResult?
        var startSample: Int?
        var endSample: Int?
        var failure: SpeechFailure?
        var previousText: String?
        var model: String?
    }
    struct OriginalAudio: Codable {
        var file = "recording.pcm"
        var sampleCount = 0
        var complete = false
        var intact: Bool?
    }
    struct Attempt: Codable {
        enum Outcome: String, Codable { case running, succeeded, empty, failed, cancelled }
        var id = UUID()
        var source: String
        var trigger: String
        var started = Date()
        var elapsed: Double?
        var outcome: Outcome = .running
        var cost: Double?
        var failure: SpeechFailure?
        var model: String?
        var isModelFallback: Bool?
    }
    var id: UUID
    var created = Date()
    var settings: AppSettings
    var seconds: Double = 0
    var chunks: [Chunk] = []
    var rawText = ""
    var completeTranscript = false
    var finalResult: InferenceResult?
    // Optional fields keep pre-upgrade recovery records readable.
    var originalAudio: OriginalAudio?
    var attempts: [Attempt]?
    var lastFailure: SpeechFailure?
    var acceptedSource: String?
    var acceptedModels: [String]?
    var failureStage: String?
    var hasContent: Bool { !chunks.isEmpty || !rawText.isEmpty || finalResult != nil || (originalAudio?.sampleCount ?? 0) > 0 }
    var recognitionCosts: [Double?] { attempts.map { $0.map(\.cost) } ?? chunks.map { $0.result?.cost } }
    var canUseOriginal: Bool { originalAudio != nil && originalAudio?.intact != false }
    var recognitionStatistics: RecognitionStatistics? {
        guard let attempts else { return nil }
        return RecognitionStatistics(requests: attempts.count, recoveryRequests: attempts.filter { $0.source == "whole" || $0.source == "context" }.count,
                                     failedRequests: attempts.filter { $0.outcome == .empty || $0.outcome == .failed }.count,
                                     cancelledRequests: attempts.filter { $0.outcome == .cancelled }.count,
                                     unknownCostRequests: attempts.filter { $0.cost == nil }.count,
                                     knownCost: attempts.compactMap(\.cost).reduce(0, +), acceptedSource: acceptedSource,
                                     slowBackupRequests: attempts.filter { $0.trigger == "slow-primary" }.count,
                                     modelFallbackRequests: attempts.filter { $0.isModelFallback == true }.count,
                                     acceptedModels: acceptedModels)
    }
    var partialText: String {
        chunks.reduce("") { text, chunk in
            TranscriptAssembler.append(chunk.result?.text ?? chunk.previousText ?? "", to: text, overlapping: chunk.overlap)
        }
    }
}

@MainActor final class RecoveryStore {
    private let root: URL
    init(root: URL = LocalFiles.root.appendingPathComponent("Recovery", isDirectory: true)) {
        self.root = root
    }
    func create(id: UUID, settings: AppSettings) throws -> RecoveryDraft {
        let draft = RecoveryDraft(id: id, settings: settings)
        try save(draft)
        return draft
    }
    func save(_ draft: RecoveryDraft) throws {
        try LocalFiles.write(draft, to: directory(draft.id).appendingPathComponent("session.json"))
    }
    func append(_ chunk: AudioChunk, to draft: inout RecoveryDraft, saving: Bool = true) throws {
        let file = "chunk-\(UUID().uuidString).wav"
        let destination = directory(draft.id).appendingPathComponent(file)
        try chunk.data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        draft.chunks.append(.init(file: file, overlap: chunk.overlapsPrevious, startSample: chunk.startSample, endSample: chunk.endSample))
        if saving { try save(draft) }
    }
    func audio(_ chunk: RecoveryDraft.Chunk, id: UUID) throws -> Data {
        guard chunk.file.hasPrefix("chunk-"), chunk.file.hasSuffix(".wav"), !chunk.file.contains("/"), !chunk.file.contains("..") else {
            throw AppError.message("恢复记录中的音频路径无效。")
        }
        return try Data(contentsOf: directory(id).appendingPathComponent(chunk.file))
    }

    func prepareOriginal(in draft: inout RecoveryDraft) throws -> URL {
        draft.originalAudio = .init(); draft.attempts = []
        try save(draft)
        return try originalURL(draft)
    }

    func originalURL(_ draft: RecoveryDraft) throws -> URL {
        guard draft.originalAudio?.file == "recording.pcm" else { throw AppError.message("恢复记录中的原音路径无效。") }
        return directory(draft.id).appendingPathComponent("recording.pcm")
    }

    func originalSampleCount(_ draft: RecoveryDraft) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: originalURL(draft).path)
        return ((attributes[.size] as? NSNumber)?.intValue ?? 0) / 2
    }

    func originalPCM(_ draft: RecoveryDraft, range: Range<Int>? = nil) throws -> Data {
        let count = try originalSampleCount(draft)
        let range = range ?? 0..<count
        guard range.lowerBound >= 0, range.upperBound <= count else { throw AppError.message("保存的原音不完整，请检查录音后重试。") }
        let handle = try FileHandle(forReadingFrom: originalURL(draft)); defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound * 2))
        let data = try handle.read(upToCount: range.count * 2) ?? Data()
        guard data.count == range.count * 2 else { throw AppError.message("无法完整读取录音。") }
        return data
    }

    func originalChunk(_ draft: RecoveryDraft, range: Range<Int>, overlap: Bool = false) throws -> AudioChunk {
        AudioChunk(data: WaveEncoder.wrapPCM(try originalPCM(draft, range: range)), duration: Double(range.count) / 16_000,
                   overlapsPrevious: overlap, startSample: range.lowerBound, endSample: range.upperBound)
    }
    func recoverable(now: Date = Date()) -> [RecoveryDraft] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return urls.compactMap { url -> RecoveryDraft? in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("session.json")),
                  var draft = try? JSONDecoder().decode(RecoveryDraft.self, from: data), url.lastPathComponent == draft.id.uuidString else { return nil }
            guard now.timeIntervalSince(draft.created) <= 86_400 else { try? FileManager.default.removeItem(at: url); return nil }
            if draft.originalAudio != nil {
                if let count = try? originalSampleCount(draft) {
                    if count < (draft.originalAudio?.sampleCount ?? 0) { draft.originalAudio?.intact = false; draft.originalAudio?.complete = false }
                    draft.originalAudio?.sampleCount = count
                    draft.seconds = max(draft.seconds, Double(count) / 16_000)
                } else { draft.originalAudio?.intact = false; draft.originalAudio?.complete = false }
            }
            if !draft.completeTranscript, draft.rawText.isEmpty { draft.rawText = draft.partialText }
            return draft.hasContent ? draft : nil
        }.sorted { $0.created > $1.created }
    }
    func remove(_ id: UUID) { try? FileManager.default.removeItem(at: directory(id)) }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
}
