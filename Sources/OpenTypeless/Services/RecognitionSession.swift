import Foundation
import OSLog
import OpenTypelessCore

struct RecognitionPolicy {
    // Conservative starting values, not claims of optimality. Keep them injectable for comparison.
    var shortRecordingSeconds: Double = 30
    var shortTailSeconds: Double = 2
    var maximumWholeSeconds: Double = 120
    var maximumRecoveryWindowSeconds: Double = 60
    var maximumRecoveryRequests = 2
    var maximumConcurrentPrimaryRequests = 2
    var backupDelay: Duration = .seconds(8)
}

/// One object per attempt (including manual retries). It owns recognition and recovery;
/// only its single completion may proceed to rewriting and delivery.
@MainActor final class RecognitionSession {
    enum Completion { case transcript, noSpeech }
    private enum State { case recording, processing, finished, cancelled }
    let attemptID: UUID
    private(set) var draft: RecoveryDraft
    private let store: RecoveryStore
    private let client: any SpeechClient
    private let key: String
    private let policy: RecognitionPolicy
    private let onUpdate: (RecoveryDraft) -> Void
    private var state: State = .recording
    private var jobs: [String: Task<Void, Never>] = [:]
    private var queuedAt: [String: TimeInterval] = [:]
    private let logger = Logger(subsystem: "com.opentypeless.mac", category: "Recognition")
    private var backup: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var continuation: CheckedContinuation<Completion, Error>?
    private var fatalFailure: SpeechFailure?
    private var recoveryFailure: SpeechFailure?
    private var recoveryRequests = 0
    private var wholeWasPrimary = false
    private var wholeWasAttempted = false
    private var silent = false
    private var storageFailure: Error?
    private var sealed = false

    init(draft: RecoveryDraft, store: RecoveryStore, client: any SpeechClient, key: String, attemptID: UUID = UUID(),
         policy: RecognitionPolicy = RecognitionPolicy(), onUpdate: @escaping (RecoveryDraft) -> Void) {
        self.draft = draft; self.store = store; self.client = client; self.key = key
        self.attemptID = attemptID
        self.policy = policy; self.onUpdate = onUpdate
        if self.draft.attempts == nil {
            self.draft.attempts = draft.chunks.map { chunk in
                if let result = chunk.result {
                    return RecoveryDraft.Attempt(source: "legacy", trigger: "previous-attempt", outcome: .succeeded, cost: result.cost)
                }
                // Old drafts cannot tell us whether a missing segment was sent
                // or billed. Preserve that uncertainty when displaying total cost.
                return RecoveryDraft.Attempt(source: "legacy", trigger: "previous-attempt-unknown", outcome: .failed, cost: nil)
            }
        }
        for index in self.draft.attempts!.indices where self.draft.attempts![index].outcome == .running {
            self.draft.attempts![index].outcome = .cancelled
        }
    }

    func receive(_ chunks: [AudioChunk], seconds: Double) throws {
        guard state == .recording, !sealed else { return }
        if let storageFailure { throw storageFailure }
        draft.seconds = seconds
        draft.originalAudio?.sampleCount = Int((seconds * 16_000).rounded())
        for chunk in chunks { try store.append(chunk, to: &draft) }
        if seconds > policy.shortRecordingSeconds { scheduleMissing() }
        if !chunks.isEmpty { try publish() } else { onUpdate(draft) }
    }

    func seal(_ ending: RecordingProgress, complete: Bool = true) throws {
        guard state == .recording, !sealed else { return }
        sealed = true
        draft.seconds = ending.seconds
        for chunk in ending.chunks { try store.append(chunk, to: &draft) }
        if draft.originalAudio != nil {
            let count = try store.originalSampleCount(draft)
            draft.originalAudio?.sampleCount = count
            let intact = ending.storageError == nil && count == Int((ending.seconds * 16_000).rounded())
            draft.originalAudio?.intact = intact
            draft.originalAudio?.complete = complete && intact
            try publish()
            guard ending.storageError == nil, count == Int((ending.seconds * 16_000).rounded()) else {
                throw AppError.message("原音保存不完整，已保留现有录音和文字。请检查可用空间后恢复。")
            }
            try planOriginal(count: count)
        } else { try planLegacyTail() }
        draft.rawText = draft.partialText
        try publish()
    }

    /// Rebuilds only the captured range. A crashed recording stays marked interrupted.
    func prepareRetry() throws {
        for index in draft.chunks.indices { draft.chunks[index].failure = nil }
        draft.lastFailure = nil
        if !draft.completeTranscript {
            if draft.canUseOriginal {
                let count = try store.originalSampleCount(draft)
                draft.originalAudio?.sampleCount = count
                draft.seconds = Double(count) / 16_000
                try planOriginal(count: count)
            } else {
                try planLegacyTail()
                if draft.chunks.isEmpty, let count = draft.originalAudio?.sampleCount, count > 0 {
                    // A partially written original may be the only surviving audio.
                    // It remains explicitly interrupted and cannot auto-paste.
                    for start in stride(from: 0, to: count, by: Int(policy.maximumRecoveryWindowSeconds * 16_000)) {
                        let end = min(count, start + Int(policy.maximumRecoveryWindowSeconds * 16_000))
                        try store.append(store.originalChunk(draft, range: start..<end), to: &draft)
                    }
                }
            }
            draft.rawText = draft.partialText
        }
        try publish()
    }

    func finish() async throws -> Completion {
        try Task.checkCancellation()
        if let storageFailure { throw storageFailure }
        guard state == .recording else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                state = .processing
                if draft.completeTranscript { resolve(.success(.transcript)); return }
                if silent { resolve(.success(.noSpeech)); return }
                guard !draft.chunks.isEmpty else {
                    resolve(.failure(AppError.message("麦克风尚未提供音频，请检查输入设备。"))); return
                }
                scheduleMissing()
                if draft.settings.effectiveTranscriptionFallbackModel != nil {
                    deadline = Task { [weak self, policy] in
                        do { try await Task.sleep(for: policy.backupDelay) } catch { return }
                        guard let self, self.state == .processing else { return }
                        self.startRecovery(trigger: "slow-primary")
                    }
                }
                evaluate()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        guard state != .finished, state != .cancelled else { return }
        state = .cancelled
        stopWork()
        try? publish()
        continuation?.resume(throwing: CancellationError()); continuation = nil
    }

    private func publish() throws {
        onUpdate(draft)
        try store.save(draft)
    }

    private func planOriginal(count: Int) throws {
        guard count > 0 else { return }
        let pcm = try store.originalPCM(draft)
        // An energy threshold is not speech detection. Only exact digital silence
        // is discarded locally; uncertain/noisy empty results remain reviewable.
        silent = pcm.allSatisfy { $0 == 0 }
        if silent { return }
        if draft.seconds <= policy.shortRecordingSeconds || draft.chunks.isEmpty {
            if draft.seconds <= policy.maximumWholeSeconds {
                try replace(0..<draft.chunks.count, with: store.originalChunk(draft, range: 0..<count))
                wholeWasPrimary = true
                return
            }
        }
        // A crash may have saved samples after the last persisted chunk.
        var end = draft.chunks.last?.endSample ?? 0
        while end < count {
            let next = min(count, end + Int(policy.maximumRecoveryWindowSeconds * 16_000))
            let remaining = try store.originalPCM(draft, range: end..<next)
            if !remaining.allSatisfy({ $0 == 0 }) {
                try store.append(store.originalChunk(draft, range: end..<next), to: &draft)
            }
            end = next
        }
        guard draft.chunks.count >= 2, let tail = draft.chunks.last,
              let start = tail.startSample, let end = tail.endSample,
              Double(end - start) / 16_000 <= policy.shortTailSeconds else { return }
        let previous = draft.chunks[draft.chunks.count - 2]
        guard let previousStart = previous.startSample else { return }
        let audio = try store.originalChunk(draft, range: previousStart..<end, overlap: previous.overlap)
        try replace((draft.chunks.count - 2)..<draft.chunks.count, with: audio)
    }

    private func planLegacyTail() throws {
        guard draft.chunks.count >= 2, let last = draft.chunks.last, last.result == nil else { return }
        let tail = try store.audio(last, id: draft.id)
        guard tail.count >= 44, Double(tail.count - 44) / 32_000 <= policy.shortTailSeconds else { return }
        let previous = draft.chunks[draft.chunks.count - 2]
        let before = try store.audio(previous, id: draft.id)
        guard before.count >= 44 else { return }
        var pcm = Data(before.dropFirst(44))
        // Old files contain the chunker's fixed 0.5-second overlap. This is a
        // recovery of saved pieces, not a reconstruction of discarded audio.
        pcm.append(tail.dropFirst(44 + (last.overlap ? min(16_000, tail.count - 44) : 0)))
        try replace((draft.chunks.count - 2)..<draft.chunks.count,
                    with: AudioChunk(data: WaveEncoder.wrapPCM(pcm), duration: Double(pcm.count) / 32_000,
                                     overlapsPrevious: previous.overlap))
    }

    private func replace(_ indices: Range<Int>, with audio: AudioChunk) throws {
        let replaced = Array(draft.chunks[indices])
        // Persist the replacement before removing metadata for the old pieces.
        try store.append(audio, to: &draft, saving: false)
        var replacement = draft.chunks.removeLast()
        replacement.previousText = replaced.reduce("") { text, chunk in
            TranscriptAssembler.append(chunk.result?.text ?? chunk.previousText ?? "", to: text, overlapping: chunk.overlap)
        }
        draft.chunks.replaceSubrange(indices, with: [replacement])
        // A cancelled request still occupies its slot until it actually exits.
        // This keeps replacement/late-response races within the concurrency cap.
        for chunk in replaced { jobs[chunk.file]?.cancel(); queuedAt.removeValue(forKey: chunk.file) }
        // Retain already recognized text in a replacement if its new request fails.
        // The separate rawText is never considered complete until every range succeeds.
    }

    private func scheduleMissing() {
        guard state == .processing || (state == .recording && draft.seconds > policy.shortRecordingSeconds),
              fatalFailure == nil, storageFailure == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for chunk in draft.chunks where chunk.result == nil && chunk.failure == nil && queuedAt[chunk.file] == nil {
            queuedAt[chunk.file] = now
        }
        let limit = max(1, min(2, policy.maximumConcurrentPrimaryRequests))
        for chunk in draft.chunks where chunk.result == nil && chunk.failure == nil && jobs[chunk.file] == nil {
            guard jobs.count < limit else { break }
            schedule(chunk)
        }
    }

    private func schedule(_ chunk: RecoveryDraft.Chunk) {
        let job = Task { [weak self] in
            guard let self else { return }
            defer {
                self.jobs.removeValue(forKey: chunk.file)
                self.queuedAt.removeValue(forKey: chunk.file)
                self.scheduleMissing()
            }
            guard !Task.isCancelled, self.state == .recording || self.state == .processing,
                  self.draft.chunks.contains(where: { $0.file == chunk.file }) else { return }
            guard self.fatalFailure == nil else { return }
            do {
                let audio = try self.store.audio(chunk, id: self.draft.id)
                let queueWait = ProcessInfo.processInfo.systemUptime - (self.queuedAt[chunk.file] ?? ProcessInfo.processInfo.systemUptime)
                self.logger.info("Recognition request started; queueWait=\(max(0, queueWait), privacy: .public), activePrimary=\(self.jobs.count, privacy: .public)")
                let result = try await self.request(audio, source: "primary", trigger: "planned")
                guard !Task.isCancelled else { return }
                self.received(.success(result), file: chunk.file)
            } catch {
                guard !Task.isCancelled else { return }
                self.received(.failure(SpeechFailure.classify(error)), file: chunk.file)
            }
        }
        jobs[chunk.file] = job
    }

    private func request(_ audio: Data, source: String, trigger: String, model: String? = nil) async throws -> InferenceResult {
        try Task.checkCancellation()
        let requestedModel = model ?? draft.settings.transcriptionModel
        let attempt = RecoveryDraft.Attempt(source: source, trigger: trigger, model: requestedModel,
                                           isModelFallback: requestedModel != draft.settings.transcriptionModel)
        draft.attempts?.append(attempt)
        try publish()
        do {
            let result = try await client.transcribe(audio: audio, model: requestedModel, key: key)
            try Task.checkCancellation()
            guard state == .recording || state == .processing else { throw CancellationError() }
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SpeechFailure(.noText, cost: result.cost) }
            record(attempt.id, result: .success(result))
            return result
        } catch {
            if state == .recording || state == .processing {
                if Task.isCancelled { markCancelled(attempt.id) }
                else { record(attempt.id, result: .failure(SpeechFailure.classify(error))) }
            }
            throw error
        }
    }

    private func record(_ id: UUID, result: Result<InferenceResult, SpeechFailure>) {
        guard let index = draft.attempts?.firstIndex(where: { $0.id == id }) else { return }
        let started = draft.attempts![index].started
        draft.attempts?[index].elapsed = Date().timeIntervalSince(started)
        switch result {
        case .success(let value):
            draft.attempts?[index].outcome = .succeeded; draft.attempts?[index].cost = value.cost
        case .failure(let failure):
            draft.attempts?[index].outcome = failure.kind == .noText ? .empty : .failed
            draft.attempts?[index].failure = failure; draft.attempts?[index].cost = failure.cost
        }
    }

    private func markCancelled(_ id: UUID) {
        if let index = draft.attempts?.firstIndex(where: { $0.id == id }) { draft.attempts?[index].outcome = .cancelled }
    }

    private func received(_ result: Result<InferenceResult, SpeechFailure>, file: String) {
        guard state == .recording || state == .processing,
              let index = draft.chunks.firstIndex(where: { $0.file == file }) else { return }
        switch result {
        case .success(let value):
            draft.chunks[index].result = value; draft.chunks[index].failure = nil
            draft.chunks[index].model = draft.settings.transcriptionModel
        case .failure(let failure):
            draft.chunks[index].failure = failure
            if !failure.permitsRecovery { fatalFailure = failure }
        }
        let partial = draft.partialText
        if !partial.isEmpty { draft.rawText = partial }
        do { try publish(); evaluate() }
        catch { storageFailure = error; resolve(.failure(error)) }
    }

    private func evaluate() {
        guard state == .processing else { return }
        if draft.chunks.allSatisfy({ $0.result != nil }), !draft.partialText.isEmpty {
            accept(draft.partialText, source: draft.acceptedSource ?? "primary",
                   models: draft.chunks.map { $0.model ?? draft.settings.transcriptionModel }); return
        }
        // An already running alternate model can still succeed after a
        // model-specific primary error. Do not start more work in that case.
        if let fatalFailure {
            if backup == nil { resolve(.failure(fatalFailure)) }
            return
        }
        guard draft.chunks.allSatisfy({ $0.result != nil || $0.failure != nil }), backup == nil else { return }
        startRecovery(trigger: "incomplete-primary")
    }

    private func startRecovery(trigger: String) {
        guard state == .processing, backup == nil else { return }
        guard fatalFailure == nil else { evaluate(); return }
        let fallbackModel = trigger == "slow-primary" ? draft.settings.effectiveTranscriptionFallbackModel : nil
        guard trigger != "slow-primary" || fallbackModel != nil else { return }
        guard recoveryRequests < policy.maximumRecoveryRequests, !wholeWasAttempted else {
            failIfPrimaryFinished(); return
        }
        do {
            let audio: Data
            let replacedFiles: [String]?
            let source: String
            if draft.canUseOriginal && draft.seconds <= policy.maximumWholeSeconds && (!wholeWasPrimary || fallbackModel != nil) {
                audio = WaveEncoder.wrapPCM(try store.originalPCM(draft)); replacedFiles = nil
                source = "whole"; wholeWasAttempted = true
            } else {
                // A short whole recording already produced no text: sending the
                // same audio again is not a diagnosis of silence.
                if wholeWasPrimary, fallbackModel == nil, draft.chunks.first?.failure?.kind == .noText { failIfPrimaryFinished(); return }
                // Very long/interrupted recordings use a bounded window with
                // neighbours; never send an unbounded original to the fallback.
                guard let failed = draft.chunks.firstIndex(where: {
                    fallbackModel != nil ? $0.result == nil : $0.failure != nil
                }) else {
                    failIfPrimaryFinished(); return
                }
                var lower = max(0, failed - 1), upper = min(draft.chunks.count, failed + 2)
                if draft.canUseOriginal {
                    // Prefer both neighbours, then shrink to a bounded interval.
                    while lower < failed, let start = draft.chunks[lower].startSample, let end = draft.chunks[upper - 1].endSample,
                          Double(end - start) / 16_000 > policy.maximumRecoveryWindowSeconds { lower += 1 }
                    while upper > failed + 1, let start = draft.chunks[lower].startSample, let end = draft.chunks[upper - 1].endSample,
                          Double(end - start) / 16_000 > policy.maximumRecoveryWindowSeconds { upper -= 1 }
                }
                let chunks = Array(draft.chunks[lower..<upper])
                if draft.canUseOriginal, let start = chunks.first?.startSample, let end = chunks.last?.endSample,
                   Double(end - start) / 16_000 <= policy.maximumRecoveryWindowSeconds {
                    audio = try store.originalChunk(draft, range: start..<end).data
                } else if !draft.canUseOriginal {
                    var pcm = Data()
                    for (index, chunk) in chunks.enumerated() {
                        let wav = try store.audio(chunk, id: draft.id)
                        guard wav.count >= 44 else { throw AppError.message("保存的音频无法读取。") }
                        pcm.append(wav.dropFirst(44 + (index > 0 && chunk.overlap ? min(16_000, wav.count - 44) : 0)))
                    }
                    guard Double(pcm.count) / 32_000 <= policy.maximumRecoveryWindowSeconds else { failIfPrimaryFinished(); return }
                    audio = WaveEncoder.wrapPCM(pcm)
                } else { failIfPrimaryFinished(); return }
                replacedFiles = chunks.map(\.file); source = "context"
            }
            recoveryRequests += 1
            backup = Task { [weak self] in
                guard let self else { return }
                do {
                    let requestedModel = fallbackModel ?? self.draft.settings.transcriptionModel
                    let result = try await self.request(audio, source: source, trigger: trigger, model: requestedModel)
                    guard self.state == .processing, !Task.isCancelled else { return }
                    self.backup = nil
                    if let files = replacedFiles {
                        try self.acceptWindow(result, files: files, audio: audio, model: requestedModel)
                        self.scheduleMissing(); self.evaluate()
                    } else { self.accept(result.text, source: "whole", models: [requestedModel]) }
                } catch {
                    guard self.state == .processing, !Task.isCancelled else { return }
                    self.backup = nil
                    self.recoveryFailure = SpeechFailure.classify(error)
                    do { try self.publish() } catch { self.resolve(.failure(error)); return }
                    // A failed backup never defeats a primary that is still running.
                    self.failIfPrimaryFinished()
                }
            }
        } catch { resolve(.failure(error)) }
    }

    private func acceptWindow(_ result: InferenceResult, files: [String], audio: Data, model: String) throws {
        guard let first = draft.chunks.firstIndex(where: { $0.file == files.first }),
              let last = draft.chunks.firstIndex(where: { $0.file == files.last }) else { return }
        // The text and its covered audio interval move together. A later repair
        // must never replace half of an earlier merged interval and duplicate it.
        let replacement = AudioChunk(data: audio, duration: Double(audio.count - 44) / 32_000,
                                     overlapsPrevious: draft.chunks[first].overlap,
                                     startSample: draft.chunks[first].startSample, endSample: draft.chunks[last].endSample)
        try replace(first..<(last + 1), with: replacement)
        draft.chunks[first].result = result
        draft.chunks[first].model = model
        draft.rawText = draft.partialText
        draft.acceptedSource = "context"
        try publish()
    }

    private func failIfPrimaryFinished() {
        guard state == .processing, backup == nil else { return }
        guard fatalFailure != nil || draft.chunks.allSatisfy({ $0.result != nil || $0.failure != nil }) else { return }
        let failure = fatalFailure ?? recoveryFailure ?? draft.chunks.compactMap(\.failure).first ?? SpeechFailure(.noText)
        resolve(.failure(failure))
    }

    private func accept(_ text: String, source: String, models: [String]) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft.rawText = text; draft.completeTranscript = true; draft.lastFailure = nil
        draft.acceptedSource = source
        var seen = Set<String>()
        draft.acceptedModels = models.filter { seen.insert($0).inserted }
        resolve(.success(.transcript))
    }

    private func resolve(_ result: Result<Completion, Error>) {
        guard state == .processing else { return }
        state = .finished
        stopWork()
        if case .failure(let error) = result { draft.lastFailure = SpeechFailure.classify(error) }
        do { try publish(); continuation?.resume(with: result) }
        catch { continuation?.resume(throwing: error) }
        continuation = nil
    }

    private func stopWork() {
        deadline?.cancel(); deadline = nil; backup?.cancel(); backup = nil
        jobs.values.forEach { $0.cancel() }; jobs = [:]; queuedAt = [:]
        for index in draft.attempts?.indices ?? [].indices where draft.attempts?[index].outcome == .running {
            draft.attempts?[index].outcome = .cancelled
        }
    }
}
