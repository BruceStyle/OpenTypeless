import Foundation

public struct AudioChunk: Sendable {
    public let data: Data
    public let duration: Double
    public let overlapsPrevious: Bool
    public let startSample: Int?
    public let endSample: Int?
    public init(data: Data, duration: Double, overlapsPrevious: Bool, startSample: Int? = nil, endSample: Int? = nil) {
        self.data = data; self.duration = duration; self.overlapsPrevious = overlapsPrevious
        self.startSample = startSample; self.endSample = endSample
    }
}

public enum WaveEncoder {
    public static func encode(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        wrapPCM(pcm(samples), sampleRate: sampleRate)
    }

    public static func pcm(_ samples: [Float]) -> Data {
        let pcm = samples.map { value -> Int16 in
            let finite = value.isFinite ? value : 0
            return Int16((max(-1, min(1, finite)) * 32767).rounded()).littleEndian
        }
        return pcm.withUnsafeBytes { Data($0) }
    }

    public static func wrapPCM(_ pcm: Data, sampleRate: Int = 16_000) -> Data {
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        let size = UInt32(pcm.count)
        ascii("RIFF"); u32(36 + size); ascii("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16); ascii("data"); u32(size)
        data.append(pcm)
        return data
    }
}

/// Input is mono 16 kHz Float32. Silence triggers a natural boundary; a hard
/// boundary retains a short overlap to avoid losing a word across requests.
public struct AudioChunker {
    public static let sampleRate = 16_000
    private var samples: [Float] = []
    private var analysisBuffer: [Float] = []
    private var silenceSamples = 0
    private var speechSamples = 0
    private var overlap = false
    private var newSampleCount = 0
    private let minimumSeconds: Double
    private let maximumSeconds: Double
    private let includeQuietAudio: Bool
    private var processedSamples = 0
    private var hasNonzeroAudio = false
    public private(set) var totalSamples = 0
    public private(set) var rms: Float = 0

    public init(minimumSeconds: Double = 8, maximumSeconds: Double = 15, includeQuietAudio: Bool = false) {
        self.minimumSeconds = minimumSeconds; self.maximumSeconds = maximumSeconds
        self.includeQuietAudio = includeQuietAudio
    }

    public mutating func append(_ incoming: [Float]) -> [AudioChunk] {
        guard !incoming.isEmpty else { return [] }
        totalSamples += incoming.count
        analysisBuffer.append(contentsOf: incoming)
        var chunks: [AudioChunk] = []
        var consumed = 0
        // Measure fixed 20 ms frames. Averaging an entire device callback can
        // hide a short spoken pause and force a cut in the middle of a word.
        while analysisBuffer.count - consumed >= 320 {
            if let chunk = processFrame(Array(analysisBuffer[consumed..<(consumed + 320)])) { chunks.append(chunk) }
            consumed += 320
        }
        if consumed > 0 { analysisBuffer.removeFirst(consumed) }
        return chunks
    }

    private mutating func processFrame(_ frame: [Float]) -> AudioChunk? {
        guard !frame.isEmpty else { return nil }
        samples.append(contentsOf: frame); newSampleCount += frame.count
        processedSamples += frame.count
        hasNonzeroAudio = hasNonzeroAudio || frame.contains { $0.isFinite && abs($0) >= 0.5 / 32767 }
        rms = sqrt(frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count))
        if rms > 0.004 { speechSamples += frame.count; silenceSamples = 0 } else { silenceSamples += frame.count }
        let length = Double(samples.count) / Double(Self.sampleRate)
        let atPause = silenceSamples >= 3_840 // 240 ms, a normal punctuation pause.
        guard (length >= minimumSeconds && atPause) || length >= maximumSeconds else { return nil }
        let hardBoundary = !atPause
        let result = makeChunk()
        let tail = hardBoundary ? Array(samples.suffix(8_000)) : []
        samples = tail; overlap = hardBoundary && result != nil; speechSamples = 0; silenceSamples = 0; newSampleCount = 0
        hasNonzeroAudio = false
        return result
    }

    public mutating func finish() -> [AudioChunk] {
        defer { samples = []; analysisBuffer = []; newSampleCount = 0; speechSamples = 0; silenceSamples = 0; overlap = false; hasNonzeroAudio = false }
        var chunks: [AudioChunk] = []
        if !analysisBuffer.isEmpty, let chunk = processFrame(analysisBuffer) { chunks.append(chunk) }
        // A final short tail must not disappear merely because it is < 0.2 s.
        if newSampleCount > 0, let chunk = makeChunk() { chunks.append(chunk) }
        return chunks
    }

    private func makeChunk() -> AudioChunk? {
        guard speechSamples > 320 || (includeQuietAudio && hasNonzeroAudio) else { return nil }
        return AudioChunk(data: WaveEncoder.encode(samples), duration: Double(samples.count) / 16_000, overlapsPrevious: overlap,
                          startSample: processedSamples - samples.count, endSample: processedSamples)
    }
}

public enum TranscriptAssembler {
    public static func append(_ next: String, to previous: String, overlapping: Bool) -> String {
        let text = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previous.isEmpty else { return text }
        guard !text.isEmpty else { return previous }
        guard overlapping else { return previous + "\n" + text }
        // Only remove an exact boundary match. Never deduplicate whole sentences
        // elsewhere: repeating a requirement may be intentional.
        let a = Array(previous), b = Array(text)
        let maximum = min(40, a.count, b.count)
        if maximum >= 2 {
            for count in stride(from: maximum, through: 2, by: -1) {
                if a.suffix(count).elementsEqual(b.prefix(count)) {
                    return previous + String(b.dropFirst(count))
                }
            }
        }
        return previous + "\n" + text
    }
}
