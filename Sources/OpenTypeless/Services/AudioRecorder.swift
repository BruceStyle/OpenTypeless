import AVFoundation
import Foundation
import OSLog
import OpenTypelessCore

private final class RecordingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunker = AudioChunker(includeQuietAudio: true)
    private var pending: [AudioChunk] = []
    private var closed = false
    private let original: ContinuousAudioFile?
    init(original: ContinuousAudioFile? = nil) { self.original = original }
    func append(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        original?.append(samples)
        pending += chunker.append(samples)
    }
    func drain(finishing: Bool = false) -> RecordingProgress {
        lock.lock(); defer { lock.unlock() }
        if finishing && !closed { pending += chunker.finish(); closed = true }
        let value = RecordingProgress(chunks: pending, seconds: Double(chunker.totalSamples) / 16_000,
                                      level: chunker.rms, storageError: finishing ? original?.finish() : nil)
        pending.removeAll(keepingCapacity: true)
        return value
    }
}

/// A narrow hardware boundary lets tests exercise route changes without a microphone.
@MainActor protocol AudioCaptureEngine: AnyObject {
    var configurationChanged: (() -> Void)? { get set }
    func start(deliver: @escaping ([Float]) -> Void) throws
    func reconfigure() throws
    func stop()
}

@MainActor private final class SystemAudioCaptureEngine: AudioCaptureEngine {
    var configurationChanged: (() -> Void)?
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var deliver: (([Float]) -> Void)?
    private var hasTap = false
    private let logger = Logger(subsystem: "com.opentypeless.mac", category: "AudioInput")

    func start(deliver: @escaping ([Float]) -> Void) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AppError.message("请先在设置中允许麦克风访问。")
        }
        self.deliver = deliver
        // Observe before starting: Bluetooth may change format during engine.start().
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: nil) { [weak self] _ in
            // Never stop or destroy the engine on its internal notification queue.
            Task { @MainActor in self?.configurationChanged?() }
        }
        try reconfigure()
    }

    func reconfigure() throws {
        engine.stop()
        let input = engine.inputNode
        if hasTap { input.removeTap(onBus: 0); hasTap = false }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let deliver,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw AppError.message("没有可用的麦克风，请检查系统音频输入设备。")
        }
        logger.notice("Configuring system input: rate=\(format.sampleRate, privacy: .public), channels=\(format.channelCount, privacy: .public)")
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { incoming, _ in
            // A stale callback may arrive while the device is renegotiating its format.
            guard incoming.format == format else { return }
            let capacity = AVAudioFrameCount(ceil(Double(incoming.frameLength) * 16_000 / format.sampleRate)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if consumed { state.pointee = .noDataNow; return nil }
                consumed = true; state.pointee = .haveData; return incoming
            }
            guard error == nil, status != .error, let channel = output.floatChannelData?[0] else { return }
            deliver(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
        }
        hasTap = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil; configurationChanged = nil
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        deliver = nil
    }
}

@MainActor final class AudioRecorder {
    private let makeEngine: (String?) -> AudioCaptureEngine
    private let settleDelay: Duration
    private var engine: AudioCaptureEngine?
    private var buffer: RecordingBuffer?
    private var session: UUID?
    private var reconnect: Task<Void, Never>?
    private var attempts = 0
    private var lastSeconds: Double = 0
    private var lastProgress = ProcessInfo.processInfo.systemUptime
    private var configuredAt = ProcessInfo.processInfo.systemUptime
    private let logger = Logger(subsystem: "com.opentypeless.mac", category: "AudioInput")
    private(set) var isConnecting = false
    var onFailure: ((Error) -> Void)?
    #if DEBUG
    var verificationAudioURL: URL?
    var onVerificationFinished: (() -> Void)?
    #endif

    init(makeEngine: ((String?) -> AudioCaptureEngine)? = nil, settleDelay: Duration = .milliseconds(200)) {
        self.makeEngine = makeEngine ?? { uid in
            if let uid, !uid.isEmpty { return SelectedAudioCaptureEngine(deviceUID: uid) }
            return SystemAudioCaptureEngine()
        }
        self.settleDelay = settleDelay
    }

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static func requestPermission() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }

    func start(deviceUID: String? = nil, originalAudioURL: URL? = nil) throws {
        _ = stop()
        let original = try originalAudioURL.map { try ContinuousAudioFile(url: $0) }
        let id = UUID(), storage = RecordingBuffer(original: original)
        let capture: AudioCaptureEngine
        #if DEBUG
        capture = verificationAudioURL.map { url in
            VerificationAudioCaptureEngine(url: url) { [weak self] in self?.onVerificationFinished?() }
        } ?? makeEngine(deviceUID)
        #else
        capture = makeEngine(deviceUID)
        #endif
        session = id; buffer = storage; engine = capture
        attempts = 0; lastSeconds = 0; isConnecting = true
        lastProgress = ProcessInfo.processInfo.systemUptime; configuredAt = lastProgress
        capture.configurationChanged = { [weak self] in
            guard let self, self.session == id else { return }
            self.logger.info("Input configuration changed; retaining session and reconnecting")
            self.scheduleReconnect(id: id)
        }
        do {
            try capture.start { samples in storage.append(samples) }
            logger.info("Capture started; waiting for input samples")
        } catch {
            // Device formats can be temporarily unavailable during a Bluetooth transition.
            logger.info("Input startup interrupted; retrying after device settles")
            scheduleReconnect(id: id)
        }
    }

    private func scheduleReconnect(id: UUID) {
        guard session == id else { return }
        reconnect?.cancel(); isConnecting = true
        reconnect = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: self.settleDelay) } catch { return }
            guard !Task.isCancelled, self.session == id, let capture = self.engine else { return }
            guard self.attempts < 4 else {
                self.reconnect = nil
                self.logger.error("Input reconnect exhausted")
                self.onFailure?(AppError.message("麦克风连接中断。请检查耳机或系统输入设备，再重试这段听写。"))
                return
            }
            self.attempts += 1
            do {
                try capture.reconfigure()
                self.configuredAt = ProcessInfo.processInfo.systemUptime
                self.lastProgress = self.configuredAt
                self.reconnect = nil
                self.logger.info("Input reconnected; attempt=\(self.attempts, privacy: .public)")
            } catch {
                self.scheduleReconnect(id: id)
            }
        }
    }

    func drain() -> RecordingProgress {
        let progress = buffer?.drain() ?? RecordingProgress()
        guard let session else { return progress }
        let now = ProcessInfo.processInfo.systemUptime
        if progress.seconds > lastSeconds {
            if isConnecting { logger.info("Input samples received; recording continues") }
            isConnecting = false; lastProgress = now; lastSeconds = progress.seconds
            if now - configuredAt > 2 { attempts = 0 }
        } else if now - lastProgress > 4, reconnect == nil {
            logger.info("Input stalled; reconnecting")
            scheduleReconnect(id: session)
        }
        return progress
    }

    func stop() -> RecordingProgress {
        session = nil; reconnect?.cancel(); reconnect = nil
        engine?.stop(); engine = nil
        let result = buffer?.drain(finishing: true) ?? RecordingProgress()
        if buffer != nil { logger.info("Capture stopped; seconds=\(result.seconds, privacy: .public)") }
        buffer = nil; isConnecting = false
        return result
    }
}
