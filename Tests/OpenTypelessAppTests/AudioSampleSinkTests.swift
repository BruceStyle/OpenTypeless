import AVFoundation
import XCTest
@testable import OpenTypeless

final class AudioSampleSinkTests: XCTestCase {
    func testCaptureSampleBufferPreservesAmplitudeAndSilence() throws {
        let samples: [Float] = [0, 0.125, -0.75, 0.5, 0]
        let buffer = try makeBuffer(samples, sampleRate: 16_000)
        XCTAssertEqual(AudioSampleSink.samples(buffer), samples)
        XCTAssertEqual(AudioSampleSink.samples(try makeBuffer([0, 0, 0], sampleRate: 16_000)), [0, 0, 0])
    }
    func testUnexpectedDeviceFormatCannotBeMisreadAs16kHz() throws {
        XCTAssertNil(AudioSampleSink.samples(try makeBuffer([0.2, 0.4], sampleRate: 48_000)))
    }
    private func makeBuffer(_ samples: [Float], sampleRate: Double) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: true))
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
        var block: CMBlockBuffer?
        let bytes = samples.count * MemoryLayout<Float>.size
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block), noErr)
        let storage = try XCTUnwrap(block)
        samples.withUnsafeBytes { source in
            XCTAssertEqual(CMBlockBufferReplaceDataBytes(with: source.baseAddress!, blockBuffer: storage, offsetIntoDestination: 0, dataLength: bytes), noErr)
        }
        var result: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: storage, formatDescription: try XCTUnwrap(description), sampleCount: samples.count,
            presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &result), noErr)
        return try XCTUnwrap(result)
    }
}
