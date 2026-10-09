import AppKit
import SwiftUI
import Observation
import OSLog
import OpenTypelessCore

enum AppPage: String, CaseIterable, Identifiable {
    case home, history, dictionary, settings
    var id: String { rawValue }
    var title: String { switch self { case .home: return "开始"; case .history: return "历史记录"; case .dictionary: return "个人词典"; case .settings: return "设置" } }
    var symbol: String { switch self { case .home: return "waveform"; case .history: return "clock"; case .dictionary: return "character.book.closed"; case .settings: return "gearshape" } }
}

@MainActor @Observable final class AppController {
    enum Phase { case idle, recording, transcribing, rewriting, inserting, ready, noSpeech, failed }
    let settings = SettingsStore()
    let learnedDictionary = LearnedDictionaryStore()
    let history = HistoryStore()
    let client = OpenRouterClient()
    let inputDevices = AudioInputDevices()
    var page: AppPage? = .home
    var dictionaryLearningMessage = ""
    var settingsPane: SettingsPane = .general
    var phase: Phase = .idle
    var seconds: Double = 0
    var level: Float = 0
    var microphoneConnecting = false
    var completedChunks = 0
    var totalChunks = 0
    var processingProgress = DictationProgress()
    var showingCompletion = false
    var resultText = ""
    var rawText = ""
    var resultMayBeIncomplete = false
    var message = ""
    var microphoneReady = AudioRecorder.permission == .authorized
    var accessibilityReady = TextInsertionService.trusted
    var shortcutReady = true
    var transcriptionModels: [ModelDescriptor] = []
    var rewriteModels: [ModelDescriptor] = []
    var loadingModels = false
    var catalogMessage = ""
    var isTesting = false
    var testResult = ""
    let recoveries: RecoveryQueue
    var canRecover: Bool { !recoveries.pending.isEmpty && phase == .failed }
    var isBusy: Bool { [.recording, .transcribing, .rewriting, .inserting].contains(phase) }
    var isProcessing: Bool { [.transcribing, .rewriting, .inserting].contains(phase) }
    var shortcutLabel: String { HotkeyService.label(settings.configuration.shortcut) }
    var phaseTitle: String {
        switch phase {
        case .idle: return "准备听写"
        case .recording: return microphoneConnecting ? "正在连接麦克风" : "正在聆听"
        case .transcribing, .rewriting, .inserting: return processingProgress.isTakingLonger ? "仍在处理" : "正在处理"
        case .ready: return "文字已就绪"
        case .noSpeech: return "未检测到清晰语音"
        case .failed: return "需要处理"
        }
    }
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let hotkeys = HotkeyService()
    @ObservationIgnored private let insertion = TextInsertionService()
    @ObservationIgnored private let correctionLearning = CorrectionLearningService()
    @ObservationIgnored private let dictionaryNotice = DictionaryNoticePanel()
    @ObservationIgnored private let recovery: RecoveryStore
    @ObservationIgnored private var overlay: RecordingPanel?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var recognition: RecognitionSession?
    @ObservationIgnored private var recognitionAttemptID: UUID?
    @ObservationIgnored private var completion: Task<Void, Never>?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var sessionKey = ""
    @ObservationIgnored private var target: TextInsertionService.Target?
    private var draft: RecoveryDraft? {
        get { recoveries.active }
        set { recoveries.active = newValue }
    }
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?
    @ObservationIgnored private var permissionRefresh: Task<Void, Never>?
    @ObservationIgnored private var recordingStart: Task<Void, Never>?
    @ObservationIgnored private var focusCapture: Task<TextInsertionService.Target?, Never>?
    @ObservationIgnored private var processingStartedAt: TimeInterval?
    @ObservationIgnored private var progressTimer: Timer?
    @ObservationIgnored private var completionFeedback: Task<Void, Never>?
    #if DEBUG
    @ObservationIgnored private var verificationCountdown: Task<Void, Never>?
    @ObservationIgnored private var verificationFailure = false
    var verificationAudioLoaded = false
    var comparingTranscription = false
    @ObservationIgnored private var overlayVerificationWindow: NSWindow?
    func scheduleDictionaryVerification() {
        guard !isBusy, ProcessInfo.processInfo.arguments.contains("--verification"),
              ProcessInfo.processInfo.environment["OPENTYPELESS_VERIFICATION_ROOT"] != nil else { return }
        // Computer Use sends background events, so it cannot reproduce the
        // user's global foreground activation. Only this isolated fixture uses
        // a supplied foreground PID; production always reads NSWorkspace.
        guard let target = insertion.dictionaryVerificationTarget(), let value = target.originalValue,
              let receipt = InsertionReceipt(baseline: value,
                range: NSRange(location: "OpenTypeless dictionary test: ".utf16.count,
                               length: "请用 CodePliot 和 扣得克斯 测试词典。".utf16.count),
                insertedText: "请用 CodePliot 和 扣得克斯 测试词典。") else {
            message = "词典验证未开始：未找到专用 TextEdit 测试文本。"; return
        }
        beginDictionaryLearning(target: target, receipt: receipt, foregroundPID: { target.signature.processID })
        message = "词典验证已开始（模拟前台、实际 AX 读取）：请改正 CodePliot 或扣得克斯。"
    }
    func showOverlayVisualVerification() {
        guard ProcessInfo.processInfo.arguments.contains("--verification") else { return }
        if overlayVerificationWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 886, height: 660),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "浮窗视觉检查"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: OverlayVisualVerification())
            window.center()
            overlayVerificationWindow = window
        }
        overlayVerificationWindow?.makeKeyAndOrderFront(nil)
    }
    func previewProcessingOverlay() {
        guard !isBusy, draft == nil, ProcessInfo.processInfo.arguments.contains("--verification") else { return }
        resetProcessingFeedback()
        resultText = ""; rawText = ""; message = ""
        seconds = 12; totalChunks = 1; completedChunks = 0
        let id = UUID()
        sessionID = id
        beginProcessingFeedback()
        phase = .transcribing; hotkeys.setBusy(true); showOverlay()
        completion = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled, self.sessionID == id else { return }
                self.processingProgress.updateCompletedChunks(1, at: ProcessInfo.processInfo.systemUptime)
                self.processingProgress.advance(to: .rewriting, at: ProcessInfo.processInfo.systemUptime)
                self.phase = .rewriting
                try await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, self.sessionID == id else { return }
                self.processingProgress.advance(to: .delivery, at: ProcessInfo.processInfo.systemUptime)
                self.phase = .inserting
                try await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, self.sessionID == id else { return }
                self.sessionID = nil
                self.hotkeys.setBusy(false)
                self.message = "进度预览已完成，未调用模型或执行粘贴。"
                self.presentDelivery(.verified)
            } catch { }
        }
    }

    func compareTranscriptionModels(alternative: String = "qwen/qwen3-asr-1.7b") {
        guard !isBusy, !comparingTranscription, ProcessInfo.processInfo.arguments.contains("--verification"),
              let url = recorder.verificationAudioURL else { return }
        // The comparison keeps its own file URL; restore normal microphone input
        // immediately so a user's Fn press cannot dictate the anonymous fixture.
        recorder.verificationAudioURL = nil; verificationAudioLoaded = false
        comparingTranscription = true
        message = "正在对比匿名样本的识别效果与耗时…"
        Task {
            defer { comparingTranscription = false }
            do {
                guard let key = try KeychainStore.read(), !key.isEmpty else { throw AppError.message("请先保存 API Key。") }
                let report = try await TranscriptionComparison.run(url: url, client: client, key: key,
                                                                  models: ["openai/whisper-large-v3-turbo", alternative])
                message = "识别对比已完成：\(report.path)"
            } catch { message = error.localizedDescription }
        }
    }
    func previewReadyOverlay(delivery: TextInsertionService.Delivery = .preview("文字已就绪")) {
        guard !isBusy, draft == nil, ProcessInfo.processInfo.arguments.contains("--verification") else { return }
        resetProcessingFeedback()
        resultText = "这是一段用于检查浮层布局的示例文字。"
        message = delivery.label
        phase = .inserting
        showOverlay()
        presentDelivery(delivery)
    }
    func chooseVerificationAudio() {
        guard !isBusy, ProcessInfo.processInfo.arguments.contains("--verification") else { return }
        let picker = NSOpenPanel()
        picker.title = "选择匿名的 16 kHz 单声道 WAV 验证音频"
        picker.allowsMultipleSelection = false; picker.canChooseDirectories = false
        picker.begin { [weak self] response in
            guard let self, response == .OK, let url = picker.url, !self.isBusy else { return }
            self.recorder.verificationAudioURL = url; self.verificationAudioLoaded = true
            self.message = "验证模式：使用所选音频，不访问麦克风。请从“开发验证”菜单启动。"
        }
    }
    func verifySilence() {
        guard !isBusy, ProcessInfo.processInfo.arguments.contains("--verification") else { return }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("opentypeless-silence-verification.wav")
            try WaveEncoder.encode(Array(repeating: 0, count: 64_000)).write(to: url, options: .atomic)
            recorder.verificationAudioURL = url; verificationAudioLoaded = true
            verificationFailure = false
            toggle()
        } catch { message = error.localizedDescription }
    }
    func scheduleVerification(failFirst: Bool = false) {
        guard !isBusy, verificationAudioLoaded else { return }
        verificationCountdown?.cancel()
        verificationFailure = failFirst
        message = "10 秒后开始匿名音频验证，请将光标放入测试输入框。"
        verificationCountdown = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, !Task.isCancelled, !self.isBusy else { return }
            self.toggle()
        }
    }
    #endif
    @ObservationIgnored private let logger = Logger(subsystem: "com.opentypeless.mac", category: "Dictation")

    init() {
        let recovery = RecoveryStore()
        self.recovery = recovery
        recoveries = RecoveryQueue(store: recovery)
        let legacyWords = settings.configuration.dictionary.components(separatedBy: .newlines)
        if learnedDictionary.migrateExistingWords(legacyWords), !settings.configuration.dictionary.isEmpty {
            settings.configuration.dictionary = ""
        }
        #if DEBUG
        recorder.onVerificationFinished = { [weak self] in self?.stop() }
        #endif
        hotkeys.onToggle = { [weak self] in
            guard let self else { return }
            self.logger.info("Shortcut toggle; phase=\(String(describing: self.phase), privacy: .public)")
            self.toggle()
        }
        hotkeys.onCancel = { [weak self] in self?.cancel() }
        recorder.onFailure = { [weak self] error in
            guard let self, self.phase == .recording else { return }
            self.fail(error)
        }
        registerShortcut()
        history.prune(days: settings.configuration.historyDays)
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.target = nil
                self.focusCapture?.cancel(); self.focusCapture = nil
                self.correctionLearning.stop()
                self.dictionaryLearningMessage = ""
                if self.phase == .recording { self.stop() }
            }
        }
    }

    func registerShortcut() { shortcutReady = hotkeys.register(settings.configuration.shortcut) }
    func refreshPermissions() {
        microphoneReady = AudioRecorder.permission == .authorized
        let wasTrusted = accessibilityReady
        accessibilityReady = TextInsertionService.trusted
        if wasTrusted != accessibilityReady || !shortcutReady { registerShortcut() }
    }
    func watchPermissionChanges() {
        permissionRefresh?.cancel()
        permissionRefresh = Task { [weak self] in
            // System Settings may stay active after a toggle. Observe the grant
            // for a bounded time and register Fn as soon as access is available.
            for _ in 0..<90 {
                guard !Task.isCancelled, let self else { return }
                self.refreshPermissions()
                if self.accessibilityReady && self.shortcutReady { return }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }
    func goTo(_ destination: AppPage) { page = destination; openMainWindow?() }
    func toggle() {
        if phase == .recording { stop() }
        else if !isBusy { start() }
    }
    func start() {
        guard !isBusy else { return }
        correctionLearning.stop(); dictionaryNotice.hide(); dictionaryLearningMessage = ""
        refreshPermissions()
        guard settings.hasKey, microphoneReady else {
            message = "请先完成密钥与麦克风设置。"
            settingsPane = settings.hasKey ? .privacy : .models
            goTo(.settings); return
        }
        do {
            guard let key = try KeychainStore.read(), !key.isEmpty else { throw AppError.message("请先保存 OpenRouter API Key。") }
            let id = UUID()
            var sessionSettings = settings.configuration
            #if DEBUG
            if verificationAudioLoaded {
                sessionSettings.saveHistory = false
                // Computer Use targets apps in the background. Never send a
                // verification paste to whichever unrelated app stays active.
                sessionSettings.autoPaste = !verificationFailure && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit"
                if verificationFailure { sessionSettings.transcriptionModel = "opentypeless/invalid-verification-model" }
            }
            #endif
            try recoveries.begin(id: id, settings: sessionSettings)
            guard var current = draft else { return }
            let originalURL = try recovery.prepareOriginal(in: &current)
            draft = current
            resetProcessingFeedback()
            sessionID = id; sessionKey = key
            let initialPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            focusCapture?.cancel(); focusCapture = nil
            target = sessionSettings.autoPaste ? insertion.capture() : nil
            if target == nil, sessionSettings.autoPaste, let initialPID,
               let preparation = insertion.prepareFocusedApplication(expectedPID: initialPID) {
                // Separate from microphone startup: a short recording may stop
                // before Chromium finishes enabling its accessibility tree.
                focusCapture = Task { [insertion] in await insertion.captureWhenReady(preparation) }
            }
            makeRecognition(current)
            resultMayBeIncomplete = false
            completedChunks = 0; totalChunks = 0; seconds = 0; rawText = ""; resultText = ""; message = ""
            processingStartedAt = nil
            microphoneConnecting = true; level = 0
            phase = .recording; hotkeys.setBusy(true); showOverlay()
            let mainWindows = NSApp.windows.filter { $0.identifier?.rawValue == "main" }
            logger.info("Recording requested; mainWindows=\(mainWindows.count, privacy: .public), visibleMainWindows=\(mainWindows.filter(\.isVisible).count, privacy: .public)")
            recordingStart = Task { [weak self] in
                // Let the compact HUD appear before synchronous hardware setup.
                await Task.yield()
                guard let self, !Task.isCancelled, self.sessionID == id, self.phase == .recording else { return }
                do {
                    try self.recorder.start(deviceUID: sessionSettings.microphoneUID, originalAudioURL: originalURL)
                    self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                        Task { @MainActor in self?.tick() }
                    }
                } catch { self.fail(error) }
            }
        } catch { fail(error) }
    }
    private func tick() {
        guard phase == .recording else { return }
        let progress = recorder.drain()
        guard phase == .recording else { return }
        seconds = progress.seconds; level = min(1, progress.level * 12)
        microphoneConnecting = recorder.isConnecting
        draft?.seconds = seconds
        do { try recognition?.receive(progress.chunks, seconds: seconds) }
        catch { fail(error); return }
        if seconds >= 600 { stop() }
    }
    private func makeRecognition(_ current: RecoveryDraft) {
        recognition?.cancel()
        let attemptID = UUID()
        recognitionAttemptID = attemptID
        let session = RecognitionSession(draft: current, store: recovery, client: client, key: sessionKey, attemptID: attemptID) { [weak self] snapshot in
            guard let self, self.sessionID == snapshot.id, self.recognitionAttemptID == attemptID else { return }
            self.draft = snapshot
            self.rawText = snapshot.rawText
            self.resultMayBeIncomplete = !snapshot.completeTranscript || snapshot.originalAudio?.complete == false
            self.totalChunks = snapshot.chunks.count
            self.completedChunks = snapshot.chunks.filter { $0.result != nil }.count
            self.processingProgress.updateCompletedChunks(self.completedChunks, at: ProcessInfo.processInfo.systemUptime)
        }
        recognition = session
        recognitionAttemptID = session.attemptID
    }
    func stop() {
        guard phase == .recording else { return }
        logger.info("Recording stop requested")
        processingStartedAt = ProcessInfo.processInfo.systemUptime
        recordingStart?.cancel(); recordingStart = nil; microphoneConnecting = false
        timer?.invalidate(); timer = nil
        let ending = recorder.stop(); level = 0; seconds = ending.seconds; draft?.seconds = seconds
        do {
            try recognition?.seal(ending)
            finishSession()
        } catch { fail(error) }
    }
    private func finishSession() {
        guard let id = sessionID, let recognition else { return }
        let attemptID = recognition.attemptID
        let processingStart = processingStartedAt ?? ProcessInfo.processInfo.systemUptime
        beginProcessingFeedback()
        phase = .transcribing
        logger.info("Transcription started; chunks=\(self.totalChunks, privacy: .public)")
        completion = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await recognition.finish()
                try Task.checkCancellation()
                guard self.sessionID == id, self.recognitionAttemptID == attemptID, var current = self.draft else { return }
                if case .noSpeech = outcome {
                    self.focusCapture?.cancel(); self.focusCapture = nil
                    self.recoveries.discardActive()
                    self.resetProcessingFeedback()
                    self.sessionID = nil; self.recognitionAttemptID = nil; self.recognition = nil
                    self.sessionKey = ""; self.target = nil; self.hotkeys.setBusy(false)
                    self.phase = .noSpeech; self.message = "未检测到清晰语音。"
                    self.rawText = ""; self.resultText = ""
                    return
                }
                let result: InferenceResult
                let rewriteStart = ProcessInfo.processInfo.systemUptime
                if let final = current.finalResult { result = final }
                else {
                    self.phase = .rewriting
                    if current.settings.mode != .transcript {
                        self.processingProgress.advance(to: .rewriting, at: ProcessInfo.processInfo.systemUptime)
                    }
                    self.logger.info("Rewrite started")
                    let rewriteSettings = DictionaryVocabulary.settings(current.settings, words: self.learnedDictionary.words, transcript: current.rawText)
                    self.logger.info("Rewrite dictionary context; words=\(rewriteSettings.vocabulary.count, privacy: .public), corrections=\(rewriteSettings.spellingCorrections.count, privacy: .public), prompt=\(RewritePrompt.version, privacy: .public)")
                    result = try await self.client.rewrite(text: current.rawText, settings: rewriteSettings, key: self.sessionKey)
                    try Task.checkCancellation()
                    guard self.sessionID == id, self.recognitionAttemptID == attemptID else { return }
                    current.finalResult = result; self.draft = current
                    try self.recovery.save(current)
                }
                self.resultText = result.text
                self.resultMayBeIncomplete = current.originalAudio?.complete == false
                self.phase = .inserting
                self.processingProgress.advance(to: .delivery, at: ProcessInfo.processInfo.systemUptime)
                let insertionStart = ProcessInfo.processInfo.systemUptime
                let textReady = insertionStart - processingStart
                self.logger.info("Final text ready; elapsed=\(textReady, privacy: .public)")
                var pastePosted: TimeInterval?
                self.hotkeys.setBusy(false)
                let delivery: TextInsertionService.Delivery
                if current.originalAudio?.complete == false {
                    delivery = .preview("录音曾中断，已恢复保存的部分，请检查后复制")
                } else if current.settings.autoPaste {
                    if self.target == nil, let pending = self.focusCapture {
                        let captured = await pending.value
                        try Task.checkCancellation()
                        guard self.sessionID == id, self.recognitionAttemptID == attemptID else { return }
                        if !pending.isCancelled { self.target = captured }
                    }
                    delivery = await self.insertion.insert(result.text, into: self.target, onPasted: { [weak self] target, expectation in
                        guard let self, self.sessionID == id else { return }
                        self.beginDictionaryLearning(target: target, expectation: expectation)
                    }) { postedAt in
                        pastePosted = postedAt - processingStart
                        self.logger.info("Paste posted; elapsed=\(postedAt - processingStart, privacy: .public)")
                    }
                }
                else { delivery = .preview("已生成结果，请复制到需要的位置") }
                guard self.sessionID == id, self.recognitionAttemptID == attemptID else { return }
                let finishedAt = ProcessInfo.processInfo.systemUptime
                var entry = HistoryEntry(rawText: current.rawText, text: result.text, mode: current.settings.mode, seconds: current.seconds,
                                         cost: CostTotal.sum(current.recognitionCosts + [result.cost]),
                                         transcriptionModel: (current.acceptedModels ?? [current.settings.transcriptionModel]).joined(separator: " + "),
                                         rewriteModel: current.settings.mode == .transcript ? nil : current.settings.rewriteModel, delivery: delivery.label)
                entry.timings = ProcessingTimings(recognition: rewriteStart - processingStart, rewriting: insertionStart - rewriteStart,
                                                 insertion: finishedAt - insertionStart, total: finishedAt - processingStart,
                                                 textReady: textReady, pastePosted: pastePosted)
                entry.recognition = current.recognitionStatistics
                var historySettings = current.settings
                historySettings.saveHistory = current.settings.saveHistory && self.settings.configuration.saveHistory
                self.history.add(entry, settings: historySettings)
                var diagnosticError: String?
                if historySettings.saveHistory && current.settings.keepsDiagnosticAudio && self.history.storageError == nil {
                    do { try self.history.preserveAudio(current, recovery: self.recovery, entryID: entry.id) }
                    catch { diagnosticError = "文字已完成，但诊断原音保存失败。" }
                }
                self.recoveries.completeActive(removingFiles: self.history.storageError == nil)
                self.message = self.history.storageError ?? diagnosticError ?? delivery.label
                self.focusCapture?.cancel(); self.focusCapture = nil
                self.draft = nil; self.sessionID = nil; self.sessionKey = ""; self.target = nil; self.recognition = nil; self.recognitionAttemptID = nil
                self.presentDelivery(delivery)
                self.logger.info("Dictation completed; delivery=\(delivery.label, privacy: .public), recognitionWait=\(rewriteStart - processingStart, privacy: .public), rewrite=\(insertionStart - rewriteStart, privacy: .public), insertion=\(finishedAt - insertionStart, privacy: .public)")
            } catch is CancellationError { }
            catch { if self.sessionID == id, self.recognitionAttemptID == attemptID { self.fail(error) } }
        }
    }
    func retry(_ id: UUID) {
        guard !isBusy, var current = recoveries.pending.first(where: { $0.id == id }) else { return }
        correctionLearning.stop(); dictionaryNotice.hide(); dictionaryLearningMessage = ""
        do {
            guard let key = try KeychainStore.read(), !key.isEmpty else {
                settingsPane = .models; goTo(.settings); return
            }
            guard recoveries.resume(id) else { return }
            resetProcessingFeedback()
            focusCapture?.cancel(); focusCapture = nil
            sessionID = current.id; sessionKey = key; target = nil; message = ""; resultMayBeIncomplete = false
            processingStartedAt = ProcessInfo.processInfo.systemUptime
            let nextSettings = settings.configuration
            if !current.completeTranscript && current.settings.transcriptionModel != nextSettings.transcriptionModel {
                for index in current.chunks.indices { current.chunks[index].result = nil }
            }
            if current.completeTranscript {
                current.settings.mode = nextSettings.mode
                current.settings.dictionary = nextSettings.dictionary
                current.settings.rewriteModel = nextSettings.rewriteModel
            } else { current.settings = nextSettings }
            #if DEBUG
            if verificationAudioLoaded { current.settings.saveHistory = false; current.settings.autoPaste = false }
            #endif
            current.finalResult = nil
            current.failureStage = nil
            draft = current; rawText = current.rawText; resultText = ""; seconds = current.seconds
            totalChunks = current.chunks.count; completedChunks = 0
            try recovery.save(current)
            makeRecognition(current)
            try recognition?.prepareRetry()
            hotkeys.setBusy(true); finishSession(); showOverlay()
        } catch { fail(error) }
    }
    func cancel() {
        correctionLearning.stop(); dictionaryNotice.hide(); dictionaryLearningMessage = ""
        guard phase != .inserting else { return }
        resetProcessingFeedback()
        logger.info("Dictation cancelled")
        focusCapture?.cancel(); focusCapture = nil
        recordingStart?.cancel(); recordingStart = nil; microphoneConnecting = false
        sessionID = nil; timer?.invalidate(); timer = nil
        _ = recorder.stop()
        recognitionAttemptID = nil; recognition?.cancel(); recognition = nil
        completion?.cancel(); completion = nil
        recoveries.discardActive()
        hotkeys.setBusy(false); sessionKey = ""; target = nil; phase = .idle; level = 0; message = "已取消"
        overlay?.hide()
    }
    private func fail(_ error: Error) {
        logger.error("Dictation failed; phase=\(String(describing: self.phase), privacy: .public)")
        focusCapture?.cancel(); focusCapture = nil
        resetProcessingFeedback()
        recordingStart?.cancel(); recordingStart = nil; microphoneConnecting = false
        timer?.invalidate(); timer = nil
        let ending = recorder.stop()
        // Keep even the tail that never reached the chunker, including on device failure.
        if phase == .recording { try? recognition?.seal(ending, complete: false) }
        recognition?.cancel(); recognition = nil; recognitionAttemptID = nil
        completion?.cancel(); completion = nil
        draft?.failureStage = phase == .recording ? "recording" : phase == .rewriting ? "rewriting" : "recognition"
        if let failure = error as? SpeechFailure { draft?.lastFailure = failure }
        sessionID = nil; sessionKey = ""; target = nil; hotkeys.setBusy(false); level = 0
        phase = .failed; message = error.localizedDescription
        if let draft {
            rawText = draft.rawText.isEmpty ? draft.partialText : draft.rawText
            resultMayBeIncomplete = !draft.completeTranscript || draft.originalAudio?.complete == false
        }
        recoveries.preserveActive()
        showOverlay()
    }
    func discardRecovery(_ id: UUID) {
        guard !isBusy else { return }
        recoveries.discardPending(id)
        if phase == .failed {
            phase = .idle; message = ""; rawText = ""; resultText = ""
            overlay?.hide()
        }
    }
    func dismissOverlay() {
        completionFeedback?.cancel(); completionFeedback = nil
        showingCompletion = false
        overlay?.hide()
    }

    private func beginProcessingFeedback() {
        resetProcessingFeedback()
        processingProgress.begin(at: ProcessInfo.processInfo.systemUptime, audioSeconds: seconds,
                                 totalChunks: totalChunks,
                                 completedChunks: draft?.completeTranscript == true ? totalChunks : completedChunks,
                                 includesRewrite: draft?.settings.mode != .transcript)
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isProcessing else { return }
                self.processingProgress.tick(at: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    private func resetProcessingFeedback() {
        progressTimer?.invalidate(); progressTimer = nil
        completionFeedback?.cancel(); completionFeedback = nil
        showingCompletion = false
        processingProgress = DictationProgress()
    }

    private func presentDelivery(_ delivery: TextInsertionService.Delivery) {
        progressTimer?.invalidate(); progressTimer = nil
        completionFeedback?.cancel()
        processingProgress.complete()
        showingCompletion = true
        phase = .ready
        completionFeedback = Task { [weak self] in
            // Keep the filled bar visible briefly. This is presentation only:
            // the text has already been delivered and Fn can start a new session.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, !Task.isCancelled, self.phase == .ready, self.showingCompletion else { return }
            switch delivery {
            case .verified, .unverified:
                self.overlay?.hide()
            case .preview:
                break
            }
            self.showingCompletion = false
            self.completionFeedback = nil
        }
    }
    func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    private func showOverlay() {
        if overlay == nil { overlay = RecordingPanel(model: self) }
        overlay?.show()
    }
    func loadModels() async {
        guard !loadingModels else { return }
        loadingModels = true; catalogMessage = ""
        defer { loadingModels = false }
        do {
            async let speech = client.models(transcription: true)
            async let text = client.models(transcription: false)
            (transcriptionModels, rewriteModels) = try await (speech, text)
            catalogMessage = "已更新 \(transcriptionModels.count) 个识别模型与 \(rewriteModels.count) 个文字模型。"
        } catch { catalogMessage = "模型列表更新失败，可继续使用已填写的模型 ID。" }
    }
    func testRewrite(_ input: String) async {
        guard !isTesting, !isBusy else { return }
        isTesting = true; testResult = ""
        defer { isTesting = false }
        do {
            guard let key = try KeychainStore.read(), !key.isEmpty else { throw AppError.message("请先在设置中保存 API Key。") }
            let rewriteSettings = DictionaryVocabulary.settings(settings.configuration, words: learnedDictionary.words, transcript: input)
            let result = try await client.rewrite(text: input, settings: rewriteSettings, key: key)
            testResult = result.text
        } catch { testResult = error.localizedDescription }
    }

    func setDictionaryLearning(_ enabled: Bool) {
        settings.configuration.learnFromCorrections = enabled
        if !enabled { correctionLearning.stop(); dictionaryNotice.hide(); dictionaryLearningMessage = "" }
    }
    func removeLearnedWord(_ id: UUID) {
        correctionLearning.stop(); dictionaryNotice.hide(); dictionaryLearningMessage = ""
        _ = learnedDictionary.exclude(id)
    }
    private func beginDictionaryLearning(target: TextInsertionService.Target, receipt: InsertionReceipt? = nil, expectation: InsertionExpectation? = nil,
                                         foregroundPID: @escaping @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
        guard settings.configuration.learnFromCorrections else { return }
        var learnedThisSession: [WordCorrection: LearnedDictionaryStore.Change] = [:]
        correctionLearning.start(target: target, receipt: receipt, expectation: expectation, foregroundPID: foregroundPID,
            enabled: { [weak self] in self?.settings.configuration.learnFromCorrections == true },
            status: { [weak self] in self?.dictionaryLearningMessage = $0.label },
            receive: { [weak self] event in
                guard let self else { return }
                switch event {
                case .learn(let correction):
                    guard let change = self.learnedDictionary.learn(correction) else { return }
                    self.dictionaryLearningMessage = "已记住词语：\(change.word.term)。"
                    learnedThisSession[correction] = change
                    self.dictionaryNotice.show(term: change.word.term) { [weak self] in
                        guard let self else { return }
                        self.correctionLearning.stop(); self.dictionaryLearningMessage = ""
                        _ = self.learnedDictionary.undo(change)
                    }
                case .undo(let correction):
                    if let change = learnedThisSession.removeValue(forKey: correction) {
                        _ = self.learnedDictionary.undo(change); self.dictionaryNotice.hide()
                    }
                }
            })
    }
}
