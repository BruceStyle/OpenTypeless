#if DEBUG
import AVFoundation
import Foundation
import OpenTypelessCore

/// Explicit, per-launch verification only. Uses the production chunking/network/
/// insertion pipeline, but never captures or uploads ambient microphone audio.
@MainActor final class VerificationAudioCaptureEngine: AudioCaptureEngine {
    var configurationChanged: (() -> Void)?
    private let url: URL
    private let finished: () -> Void
    private var feed: Task<Void, Never>?
    init(url: URL, finished: @escaping () -> Void) { self.url = url; self.finished = finished }

    func start(deliver: @escaping ([Float]) -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == 16_000, format.channelCount == 1, file.length <= 16_000 * 120,
              let audio = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AppError.message("验证音频须为 16 kHz 单声道，且不超过两分钟。")
        }
        try file.read(into: audio)
        guard let channel = audio.floatChannelData?[0] else { throw AppError.message("无法读取验证音频。") }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(audio.frameLength)))
        feed = Task {
            var offset = 0
            while !Task.isCancelled && offset < samples.count {
                let end = min(samples.count, offset + 1_600)
                deliver(offset < samples.count ? Array(samples[offset..<end]) : Array(repeating: 0, count: 1_600))
                offset = end
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            if !Task.isCancelled { finished() }
        }
    }
    func reconfigure() throws { }
    func stop() { feed?.cancel(); feed = nil }
}
#endif
