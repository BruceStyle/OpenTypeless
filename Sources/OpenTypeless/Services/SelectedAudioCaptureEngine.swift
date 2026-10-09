@preconcurrency import AVFoundation
import CoreMedia
import OSLog
import OpenTypelessCore

/// A capture session owns a specific microphone independently of the system's
/// default input/output pair. AVAudioEngine's shared I/O unit can renegotiate
/// back to that pair when a Bluetooth output changes format.
@MainActor final class SelectedAudioCaptureEngine: AudioCaptureEngine {
    var configurationChanged: (() -> Void)?
    private let deviceUID: String
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var sink: AudioSampleSink?
    private var observers: [NSObjectProtocol] = []
    private var deliver: (([Float]) -> Void)?
    private let captureQueue = DispatchQueue(label: "com.opentypeless.selected-microphone")
    private let logger = Logger(subsystem: "com.opentypeless.mac", category: "AudioInput")

    init(deviceUID: String) { self.deviceUID = deviceUID }

    func start(deliver: @escaping ([Float]) -> Void) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AppError.message("请先在设置中允许麦克风访问。")
        }
        self.deliver = deliver
        try reconfigure()
    }

    func reconfigure() throws {
        tearDown()
        let devices = AudioDeviceDiscovery.snapshot()
        let selected = try AudioInputSelection.resolve(uid: deviceUID, devices: devices.devices, defaultID: devices.defaultID)
        guard let deliver, let device = AVCaptureDevice(uniqueID: selected.id),
              device.isConnected, device.hasMediaType(.audio) else {
            throw AppError.message("所选麦克风已断开。请重新连接，或在设置中选择其他麦克风。")
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM,
                                AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1,
                                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw AppError.message("无法连接所选麦克风，请在设置中选择其他输入设备。")
        }
        session.beginConfiguration()
        session.addInput(input); session.addOutput(output)
        session.commitConfiguration()
        let sink = AudioSampleSink(deliver: deliver)
        output.setSampleBufferDelegate(sink, queue: captureQueue)
        self.session = session; self.output = output; self.sink = sink
        for (name, object) in [(AVCaptureSession.runtimeErrorNotification, session as AnyObject),
                               (AVCaptureDevice.wasDisconnectedNotification, device as AnyObject)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self, weak session] _ in
                Task { @MainActor in
                    guard let self, let session, self.session === session else { return }
                    self.configurationChanged?()
                }
            })
        }
        // Starting capture can block while Bluetooth or Continuity connects.
        // Keep the main run loop available for Fn/Esc and the recording HUD.
        captureQueue.async { session.startRunning() }
        logger.notice("Selected microphone capture configured; manual=true")
    }

    private func tearDown() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        output?.setSampleBufferDelegate(nil, queue: nil)
        if let session { captureQueue.async { session.stopRunning() } }
        session = nil; output = nil; sink = nil
    }
    func stop() {
        configurationChanged = nil; deliver = nil
        tearDown()
    }
}

final class AudioSampleSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let deliver: ([Float]) -> Void
    private var loggedFormat = false
    private let logger = Logger(subsystem: "com.opentypeless.mac", category: "AudioInput")
    init(deliver: @escaping ([Float]) -> Void) { self.deliver = deliver }

    static func samples(_ buffer: CMSampleBuffer) -> [Float]? {
        guard CMSampleBufferDataIsReady(buffer),
              let description = CMSampleBufferGetFormatDescription(buffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate == 16_000,
              format.mChannelsPerFrame == 1, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              let block = CMSampleBufferGetDataBuffer(buffer) else { return nil }
        let count = CMSampleBufferGetNumSamples(buffer)
        guard count > 0, CMBlockBufferGetDataLength(block) == count * MemoryLayout<Float>.size else { return nil }
        var samples = [Float](repeating: 0, count: count)
        let status = samples.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        return status == kCMBlockBufferNoErr ? samples : nil
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let samples = Self.samples(sampleBuffer) else { return }
        if !loggedFormat {
            loggedFormat = true
            logger.notice("Selected microphone samples received; rate=16000, channels=1, float32=true")
        }
        deliver(samples)
    }
}
