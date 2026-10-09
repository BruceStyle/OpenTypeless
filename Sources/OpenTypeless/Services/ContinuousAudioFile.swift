import Foundation
import OpenTypelessCore

/// PCM is appended on a private serial queue, never on the audio callback.
/// A headerless file remains readable after interruption; WAV headers are made at request time.
final class ContinuousAudioFile: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.opentypeless.original-audio", qos: .userInitiated)
    private var handle: FileHandle?
    private var failure: Error?
    private var closed = false

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw AppError.message("无法保存录音，请检查本机可用空间。")
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ samples: [Float]) {
        queue.async { [self] in
            guard !closed, failure == nil else { return }
            do { try handle?.write(contentsOf: WaveEncoder.pcm(samples)) }
            catch { failure = error }
        }
    }

    func finish() -> Error? {
        queue.sync {
            guard !closed else { return failure }
            closed = true
            do { try handle?.synchronize(); try handle?.close() }
            catch { if failure == nil { failure = error } }
            handle = nil
            return failure
        }
    }

    deinit { try? handle?.close() }
}

struct RecordingProgress {
    var chunks: [AudioChunk] = []
    var seconds: Double = 0
    var level: Float = 0
    var storageError: Error?
}
