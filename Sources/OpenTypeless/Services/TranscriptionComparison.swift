#if DEBUG
import AVFoundation
import Foundation
import OpenTypelessCore

/// Opt-in developer evaluation. Audio is selected explicitly and never captured
/// from the microphone. Use anonymous fixtures, not a user's dictation history.
enum TranscriptionComparison {
    struct Entry: Codable {
        let sample: String
        let model: String
        let elapsedSeconds: Double
        let text: String?
        let error: String?
    }

    static func run(url: URL, client: OpenRouterClient, key: String, models: [String]) async throws -> URL {
        let samples = try readSamples(url)
        let variants: [(String, [Float])] = [
            ("clean", samples),
            ("trailing-silence-8s", samples + Array(repeating: 0, count: 128_000)),
            ("quiet-with-trailing-silence", samples.map { $0 * 0.1 } + Array(repeating: 0, count: 128_000))
        ]
        var results: [Entry] = []
        for (name, audio) in variants {
            for model in models {
                try Task.checkCancellation()
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    let result = try await client.transcribe(audio: WaveEncoder.encode(audio), model: model, key: key)
                    results.append(.init(sample: name, model: model, elapsedSeconds: ProcessInfo.processInfo.systemUptime - start,
                                         text: result.text, error: nil))
                } catch {
                    results.append(.init(sample: name, model: model, elapsedSeconds: ProcessInfo.processInfo.systemUptime - start,
                                         text: nil, error: error.localizedDescription))
                }
            }
        }
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("opentypeless-asr-comparison-\(UUID().uuidString).json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: report, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: report.path)
        return report
    }

    private static func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == 16_000, format.channelCount == 1, file.length > 0, file.length <= 16_000 * 60,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AppError.message("对比样本须为 16 kHz 单声道 WAV，长度在一分钟内。")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw AppError.message("无法读取测试音频。") }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
#endif
