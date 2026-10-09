import XCTest
import OpenTypelessCore
@testable import OpenTypeless

@MainActor private final class FakeCaptureEngine: AudioCaptureEngine {
    var configurationChanged: (() -> Void)?
    var deliver: (([Float]) -> Void)?
    var reconfigurations = 0
    var onReconfigure: (() -> Void)?
    var failReconfigure = false
    var stopped = false
    func start(deliver: @escaping ([Float]) -> Void) throws { self.deliver = deliver }
    func reconfigure() throws {
        reconfigurations += 1; onReconfigure?()
        if failReconfigure { throw NSError(domain: "TestInput", code: 1) }
    }
    func stop() { stopped = true }
}

final class AudioRecorderTests: XCTestCase {
    @MainActor func testContinuousOriginalIsWrittenDuringCaptureAndRetainsSilenceQuietSpeechAndFinalSample() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OriginalCapture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("recording.pcm")
        let engine = FakeCaptureEngine()
        let recorder = AudioRecorder(makeEngine: { _ in engine })
        try recorder.start(originalAudioURL: url)
        let silence = Array(repeating: Float(0), count: 128_000)
        engine.deliver?(silence)
        for _ in 0..<100 {
            if (try Data(contentsOf: url)).count == silence.count * 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(try Data(contentsOf: url).count, silence.count * 2, "Must persist before stop")
        let quiet = Array(repeating: Float(0.0001), count: 16_013)
        engine.deliver?(quiet)
        engine.deliver?([0.5])
        let ending = recorder.stop()
        XCTAssertNil(ending.storageError)
        XCTAssertEqual(try Data(contentsOf: url), WaveEncoder.pcm(silence + quiet + [0.5]))
        XCTAssertEqual(ending.seconds, Double(silence.count + quiet.count + 1) / 16_000, accuracy: 0.00001)
        engine.deliver?([1, 1, 1]) // a stale capture callback after stop must not append.
        XCTAssertEqual(try Data(contentsOf: url).count, (silence.count + quiet.count + 1) * 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    @MainActor func testCannotStartRecordingWithoutWritableOriginalDestination() async throws {
        let engine = FakeCaptureEngine()
        let recorder = AudioRecorder(makeEngine: { _ in engine })
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("recording.pcm")
        XCTAssertThrowsError(try recorder.start(originalAudioURL: missing))
        XCTAssertNil(engine.deliver)
    }

    @MainActor func testSelectedMicrophoneReachesCaptureEngineAndRemainsFixedDuringReconnect() async throws {
        let engine = FakeCaptureEngine()
        var selections: [String?] = []
        let recorder = AudioRecorder(makeEngine: { uid in selections.append(uid); return engine }, settleDelay: .milliseconds(1))
        let reconnected = expectation(description: "Selected device reconnects")
        engine.onReconfigure = { reconnected.fulfill() }
        try recorder.start(deviceUID: "selected-headset")
        engine.configurationChanged?()
        await fulfillment(of: [reconnected], timeout: 2)
        XCTAssertEqual(selections.count, 1)
        XCTAssertEqual(selections[0], "selected-headset")
        _ = recorder.stop()
        try recorder.start()
        XCTAssertEqual(selections.count, 2)
        XCTAssertNil(selections[1])
        _ = recorder.stop()
    }
    @MainActor func testBluetoothFormatChangePreservesSessionAndCapturedAudio() async throws {
        let engine = FakeCaptureEngine()
        let recorder = AudioRecorder(makeEngine: { _ in engine }, settleDelay: .milliseconds(1))
        let reconnected = expectation(description: "Capture restarts after format change")
        engine.onReconfigure = { reconnected.fulfill() }
        recorder.onFailure = { _ in XCTFail("A format change must not finish or fail dictation") }
        try recorder.start()
        engine.deliver?(Array(repeating: 0.1, count: 1_600))
        XCTAssertEqual(recorder.drain().seconds, 0.1, accuracy: 0.0001)
        engine.configurationChanged?()
        XCTAssertTrue(recorder.isConnecting)
        await fulfillment(of: [reconnected], timeout: 2)
        engine.deliver?(Array(repeating: 0.2, count: 3_200))
        let progress = recorder.drain()
        XCTAssertEqual(progress.seconds, 0.3, accuracy: 0.0001)
        XCTAssertFalse(recorder.isConnecting)
        let final = recorder.stop()
        XCTAssertEqual(final.chunks.count, 1)
        XCTAssertEqual(final.chunks.first?.data.count, 44 + 4_800 * 2)
        XCTAssertEqual(engine.reconfigurations, 1)
    }

    @MainActor func testCancelDuringReconnectDoesNotRestartMicrophone() async throws {
        let engine = FakeCaptureEngine()
        let recorder = AudioRecorder(makeEngine: { _ in engine }, settleDelay: .milliseconds(15))
        let unwanted = expectation(description: "No restart after cancel"); unwanted.isInverted = true
        engine.onReconfigure = { unwanted.fulfill() }
        try recorder.start()
        let staleNotification = engine.configurationChanged
        engine.configurationChanged?()
        _ = recorder.stop()
        staleNotification?()
        await fulfillment(of: [unwanted], timeout: 0.1)
        XCTAssertTrue(engine.stopped)
        XCTAssertFalse(recorder.isConnecting)
        XCTAssertEqual(recorder.drain().seconds, 0)
    }

    @MainActor func testRepeatedFormatNotificationsAreCoalesced() async throws {
        let engine = FakeCaptureEngine()
        let recorder = AudioRecorder(makeEngine: { _ in engine }, settleDelay: .milliseconds(10))
        let reconnected = expectation(description: "One restart for a format-change burst")
        engine.onReconfigure = { reconnected.fulfill() }
        try recorder.start()
        for _ in 0..<8 { engine.configurationChanged?() }
        await fulfillment(of: [reconnected], timeout: 2)
        XCTAssertEqual(engine.reconfigurations, 1)
        _ = recorder.stop()
    }

    @MainActor func testUnavailableMicrophoneHasBoundedRetriesAndKeepsAudio() async throws {
        let engine = FakeCaptureEngine(); engine.failReconfigure = true
        let recorder = AudioRecorder(makeEngine: { _ in engine }, settleDelay: .milliseconds(1))
        let failed = expectation(description: "Report connection error after bounded retries")
        recorder.onFailure = { error in
            XCTAssertTrue(error.localizedDescription.contains("麦克风连接中断"))
            failed.fulfill()
        }
        try recorder.start()
        engine.deliver?(Array(repeating: 0.1, count: 3_200))
        engine.configurationChanged?()
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(engine.reconfigurations, 4)
        XCTAssertEqual(recorder.stop().chunks.count, 1, "The buffered tail must remain available for recovery")
    }
}
