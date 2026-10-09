import AVFoundation
import Foundation
import OpenTypelessCore

// A standalone CLI: no microphone, app launch, history, paste, or recovery writes.
// The existing API key is accepted through stdin, never argv or a saved file.
private struct Fixture: Codable {
    let id: String
    let path: String
    let reference: String
    let expectsSpeech: Bool
}

private struct Plan {
    struct Part { let audio: AudioChunk; let availableAt: Double }
    let fixture: Fixture
    let audio: Data
    let seconds: Double
    let parts: [Part]

    init(_ fixture: Fixture) throws {
        self.fixture = fixture
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: fixture.path))
        guard file.processingFormat.sampleRate == 16_000,
              file.processingFormat.channelCount == 1,
              file.length > 0, file.length <= 16_000 * 180,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AppError.message("Benchmark input must be 16 kHz mono, up to 180 seconds.")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw AppError.message("Unreadable benchmark PCM.") }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        seconds = Double(samples.count) / 16_000
        audio = WaveEncoder.encode(samples)
        var chunker = AudioChunker()
        var emitted: [Part] = []
        for start in stride(from: 0, to: samples.count, by: 1_600) {
            let end = min(samples.count, start + 1_600)
            for chunk in chunker.append(Array(samples[start..<end])) {
                emitted.append(.init(audio: chunk, availableAt: Double(end) / 16_000))
            }
        }
        for chunk in chunker.finish() { emitted.append(.init(audio: chunk, availableAt: seconds)) }
        parts = emitted
    }
}

private struct RequestRecord: Codable {
    let sequence: Int
    let sample: String
    let round: Int
    let route: String
    let operation: String
    let part: Int?
    let audioSeconds: Double?
    var elapsed: Double = 0
    var status = "pending"
    var cost: Double?
    var error: String?
}

private actor Journal {
    private var records: [RequestRecord] = []
    private var knownCost: Double = 0
    func reserve(sample: String, round: Int, route: String, operation: String, part: Int?, seconds: Double?) throws -> Int {
        guard records.count < 90, knownCost < 0.50 else { throw AppError.message("Benchmark request or reported-cost limit reached.") }
        let sequence = records.count
        records.append(.init(sequence: sequence, sample: sample, round: round, route: route, operation: operation, part: part, audioSeconds: seconds))
        return sequence
    }
    func finish(_ sequence: Int, started: Double, result: InferenceResult?, error: Error?) {
        records[sequence].elapsed = uptime() - started
        records[sequence].cost = result?.cost
        records[sequence].status = error == nil ? "ok" : errorKind(error!)
        records[sequence].error = error?.localizedDescription
        knownCost += result?.cost ?? 0
    }
    func snapshot() -> [RequestRecord] { records }
}

private struct Outcome: Codable {
    let sample: String
    let round: Int
    var strategy: String
    var status: String
    let audioSeconds: Double
    let chunks: Int
    let completedChunks: Int
    var recognitionAfterStop: Double
    var rewriteSeconds: Double
    var totalAfterStop: Double
    var raw: String
    var text: String
    var error: String?
    var usedFallback: Bool
    var sharesSegmentedRun: Bool
    let requestRoutes: [String]
}

private struct Report: Codable {
    let created: String
    let transcriptionModel: String
    let rewriteModel: String
    let fixtureOrigin: String
    let methodology: String
    let fixtures: [Fixture]
    let outcomes: [Outcome]
    let requests: [RequestRecord]
}

private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
private func errorKind(_ error: Error) -> String {
    error.localizedDescription.contains("没有识别出文字") ? "empty" : "error"
}
private func waitUntil(_ deadline: Double) async throws {
    let remaining = deadline - uptime()
    if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
}

private actor MeasuredClient {
    let client = OpenRouterClient()
    let journal: Journal
    let key: String
    let settings: AppSettings
    init(journal: Journal, key: String) { self.journal = journal; self.key = key; settings = AppSettings() }

    func transcribe(_ data: Data, sample: String, round: Int, route: String, part: Int?, seconds: Double) async throws -> InferenceResult {
        let sequence = try await journal.reserve(sample: sample, round: round, route: route, operation: "transcribe", part: part, seconds: seconds)
        let started = uptime()
        do {
            let result = try await client.transcribe(audio: data, model: settings.transcriptionModel, key: key)
            await journal.finish(sequence, started: started, result: result, error: nil)
            return result
        } catch {
            await journal.finish(sequence, started: started, result: nil, error: error)
            throw error
        }
    }
    func rewrite(_ raw: String, sample: String, round: Int, route: String) async throws -> InferenceResult {
        let sequence = try await journal.reserve(sample: sample, round: round, route: route, operation: "rewrite", part: nil, seconds: nil)
        let started = uptime()
        do {
            let result = try await client.rewrite(text: raw, settings: settings, key: key)
            await journal.finish(sequence, started: started, result: result, error: nil)
            return result
        } catch {
            await journal.finish(sequence, started: started, result: nil, error: error)
            throw error
        }
    }
}

@main struct TranscriptionBenchmark {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data(("Benchmark stopped: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 4 else { throw AppError.message("Usage: TranscriptionBenchmark --prepare|--run manifest.json report.json") }
        let mode = arguments[1]
        guard mode == "--prepare" || mode == "--run" else { throw AppError.message("Unknown benchmark mode.") }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        guard fixtures.count == 5, Set(fixtures.map(\.id)).count == fixtures.count else { throw AppError.message("Expected exactly five distinct anonymous fixtures.") }
        let plans = try fixtures.map(Plan.init)
        for plan in plans {
            let durations = plan.parts.map { String(format: "%.3f", $0.audio.duration) }.joined(separator: ",")
            print("PLAN \(plan.fixture.id) seconds=\(String(format: "%.3f", plan.seconds)) parts=[\(durations)]")
        }
        // An invariant of the fixture generator: this case must reproduce an isolated short tail.
        guard let tail = plans.first(where: { $0.fixture.id == "speech-stop-click" }),
              tail.parts.count == 2, tail.parts.last!.audio.duration < 0.1 else {
            throw AppError.message("Short-tail fixture did not reproduce the intended boundary.")
        }
        guard mode == "--run" else { return }
        guard let key = readLine(), !key.trimmingCharacters(in: .whitespaces).isEmpty else { throw AppError.message("API key must be supplied on stdin.") }
        let journal = Journal()
        let client = MeasuredClient(journal: journal, key: key)
        let settings = AppSettings()
        var outcomes: [Outcome] = []
        let created = ISO8601DateFormatter().string(from: Date())
        let reportURL = URL(fileURLWithPath: arguments[3])
        func save() async throws {
            let report = Report(created: created, transcriptionModel: settings.transcriptionModel, rewriteModel: settings.rewriteModel,
                fixtureOrigin: "Anonymous local Tingting speech and synthetic clicks; no microphone or user recordings.",
                methodology: "Two rounds. Pair order alternates. Segmented audio is released on its real recording timeline using production AudioChunker and serial task dependencies. Full-file requests start at logical stop. Both use production OpenRouterClient, TranscriptAssembler and rewrite settings. Hybrid shares the segmented trial; only an ASR failure triggers one new full-file request after stop. No paste/UI timing. Unknown failed-request costs stay unknown.",
                fixtures: fixtures, outcomes: outcomes, requests: await journal.snapshot())
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
        }
        for round in 1...2 {
            let ordered = round == 1 ? plans : Array(plans.reversed())
            for (index, plan) in ordered.enumerated() {
                let wholeFirst = (index + round).isMultiple(of: 2)
                if wholeFirst {
                    print("START round=\(round) sample=\(plan.fixture.id) strategy=whole")
                    let outcome = await whole(plan, round: round, client: client)
                    outcomes.append(outcome); emit(outcome); try await save()
                }
                print("START round=\(round) sample=\(plan.fixture.id) strategy=segmented+hybrid playback=\(String(format: "%.1f", plan.seconds))s")
                let pair = try await segmented(plan, round: round, client: client)
                outcomes.append(contentsOf: pair)
                pair.forEach(emit); try await save()
                if !wholeFirst {
                    print("START round=\(round) sample=\(plan.fixture.id) strategy=whole")
                    let outcome = await whole(plan, round: round, client: client)
                    outcomes.append(outcome); emit(outcome); try await save()
                }
            }
        }
        print("COMPLETE outcomes=\(outcomes.count) requests=\(await journal.snapshot().count)")
    }

    private static func finish(_ raw: String, plan: Plan, round: Int, strategy: String, route: String,
                               stop: Double, recognizedAt: Double, completed: Int, fallback: Bool,
                               client: MeasuredClient) async -> Outcome {
        let rewriteStarted = uptime()
        do {
            let result = try await client.rewrite(raw, sample: plan.fixture.id, round: round, route: route)
            return Outcome(sample: plan.fixture.id, round: round, strategy: strategy, status: "ok", audioSeconds: plan.seconds,
                chunks: plan.parts.count, completedChunks: completed, recognitionAfterStop: max(0, recognizedAt - stop),
                rewriteSeconds: uptime() - rewriteStarted, totalAfterStop: max(0, uptime() - stop), raw: raw, text: result.text,
                error: nil, usedFallback: fallback, sharesSegmentedRun: strategy == "hybrid", requestRoutes: fallback ? ["segmented", "fallback"] : [route])
        } catch {
            return Outcome(sample: plan.fixture.id, round: round, strategy: strategy, status: "rewrite-error", audioSeconds: plan.seconds,
                chunks: plan.parts.count, completedChunks: completed, recognitionAfterStop: max(0, recognizedAt - stop),
                rewriteSeconds: uptime() - rewriteStarted, totalAfterStop: max(0, uptime() - stop), raw: raw, text: "",
                error: error.localizedDescription, usedFallback: fallback, sharesSegmentedRun: strategy == "hybrid", requestRoutes: fallback ? ["segmented", "fallback"] : [route])
        }
    }

    private static func whole(_ plan: Plan, round: Int, client: MeasuredClient) async -> Outcome {
        let stop = uptime()
        do {
            let result = try await client.transcribe(plan.audio, sample: plan.fixture.id, round: round, route: "whole", part: nil, seconds: plan.seconds)
            return await finish(result.text, plan: plan, round: round, strategy: "whole", route: "whole", stop: stop,
                                recognizedAt: uptime(), completed: 1, fallback: false, client: client)
        } catch {
            return failed(plan, round: round, strategy: "whole", stop: stop, completed: 0, error: error, fallback: false)
        }
    }

    private static func segmented(_ plan: Plan, round: Int, client: MeasuredClient) async throws -> [Outcome] {
        let started = uptime()
        let stop = started + plan.seconds
        var jobs: [Task<InferenceResult, Error>] = []
        for (index, part) in plan.parts.enumerated() {
            try await waitUntil(started + part.availableAt)
            let previous = jobs.last
            let task = Task<InferenceResult, Error> {
                if let previous { _ = try await previous.value }
                return try await client.transcribe(part.audio.data, sample: plan.fixture.id, round: round, route: "segmented", part: index, seconds: part.audio.duration)
            }
            jobs.append(task)
        }
        try await waitUntil(stop)
        var completed: [InferenceResult] = []
        do {
            guard !jobs.isEmpty else { throw AppError.message("No chunks produced.") }
            for job in jobs { completed.append(try await job.value) }
            var raw = ""
            for (result, part) in zip(completed, plan.parts) {
                raw = TranscriptAssembler.append(result.text, to: raw, overlapping: part.audio.overlapsPrevious)
            }
            let outcome = await finish(raw, plan: plan, round: round, strategy: "segmented", route: "segmented", stop: stop,
                recognizedAt: uptime(), completed: completed.count, fallback: false, client: client)
            var hybrid = outcome; hybrid.strategy = "hybrid"; hybrid.sharesSegmentedRun = true
            return [outcome, hybrid]
        } catch {
            jobs.forEach { $0.cancel() }
            var failure = failed(plan, round: round, strategy: "segmented", stop: stop, completed: completed.count, error: error, fallback: false)
            failure.raw = zip(completed, plan.parts).reduce("") { TranscriptAssembler.append($1.0.text, to: $0, overlapping: $1.1.audio.overlapsPrevious) }
            print("FALLBACK round=\(round) sample=\(plan.fixture.id) reason=\(failure.status)")
            do {
                let result = try await client.transcribe(plan.audio, sample: plan.fixture.id, round: round, route: "fallback", part: nil, seconds: plan.seconds)
                let hybrid = await finish(result.text, plan: plan, round: round, strategy: "hybrid", route: "fallback", stop: stop,
                    recognizedAt: uptime(), completed: completed.count, fallback: true, client: client)
                return [failure, hybrid]
            } catch {
                return [failure, failed(plan, round: round, strategy: "hybrid", stop: stop, completed: completed.count, error: error, fallback: true)]
            }
        }
    }

    private static func failed(_ plan: Plan, round: Int, strategy: String, stop: Double, completed: Int, error: Error, fallback: Bool) -> Outcome {
        Outcome(sample: plan.fixture.id, round: round, strategy: strategy, status: errorKind(error), audioSeconds: plan.seconds,
            chunks: plan.parts.count, completedChunks: completed, recognitionAfterStop: max(0, uptime() - stop), rewriteSeconds: 0,
            totalAfterStop: max(0, uptime() - stop), raw: "", text: "", error: error.localizedDescription, usedFallback: fallback,
            sharesSegmentedRun: strategy == "hybrid", requestRoutes: fallback ? ["segmented", "fallback"] : [strategy])
    }
    private static func emit(_ outcome: Outcome) {
        print("RESULT round=\(outcome.round) sample=\(outcome.sample) strategy=\(outcome.strategy) status=\(outcome.status) recognition=\(String(format: "%.3f", outcome.recognitionAfterStop)) total=\(String(format: "%.3f", outcome.totalAfterStop))")
        fflush(stdout)
    }
}
