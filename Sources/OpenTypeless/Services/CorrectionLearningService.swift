import AppKit
import ApplicationServices
import OSLog
import OpenTypelessCore

/// Owns one short observation; a generation check discards reads that finish
/// after cancellation or a new dictation. It never writes to the target field.
@MainActor final class CorrectionLearningService {
    enum Status: String {
        case awaitingPaste, observing, unconfirmed, unavailable, finished
        var label: String {
            switch self {
            case .awaitingPaste: return "正在确认本次回填，随后开始学习。"
            case .observing: return "正在观察本次回填后的纠词，最长 60 秒。"
            case .unconfirmed: return "最近一次未能确认回填文字，没有启动学习。"
            case .unavailable: return "输入位置已改变或无法读取，本次学习已结束。"
            case .finished: return "本次词语观察已结束。"
            }
        }
    }
    private let logger = Logger(subsystem: "com.opentypeless.mac", category: "DictionaryLearning")
    private var task: Task<Void, Never>?
    private var reader: CorrectionAXReader?
    private var generation = UUID()

    func stop() {
        generation = UUID(); task?.cancel(); task = nil
        reader?.stopNotifications(); reader = nil
    }
    func start(target: TextInsertionService.Target, receipt: InsertionReceipt? = nil, expectation: InsertionExpectation? = nil,
               foregroundPID: @escaping @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
               enabled: @escaping @MainActor () -> Bool,
               status: @escaping @MainActor (Status) -> Void = { _ in },
               receive: @escaping @MainActor (CorrectionObservation.Event) -> Void) {
        stop()
        let reader = CorrectionAXReader(target: target)
        self.reader = reader
        var notificationsStarted = false
        var confirmingPaste = receipt == nil
        start(receipt: receipt, expectation: expectation, enabled: enabled, read: {
            guard foregroundPID() == target.signature.processID,
                  TextInsertionService.trusted else { return nil }
            if !notificationsStarted { reader.startNotifications(); notificationsStarted = true }
            let text = await reader.read(forceValue: confirmingPaste)
            guard foregroundPID() == target.signature.processID else { return nil }
            return text
        }, status: { value in
            if value == .observing { confirmingPaste = false }
            status(value)
        }, receive: receive)
    }
    // Injectable read path keeps lifecycle tests independent of AX permissions.
    func start(receipt: InsertionReceipt? = nil, expectation: InsertionExpectation? = nil, enabled: @escaping @MainActor () -> Bool,
               read: @escaping @MainActor () async -> String?,
               interval: Duration = .milliseconds(750),
               now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
               status: @escaping @MainActor (Status) -> Void = { _ in },
               receive: @escaping @MainActor (CorrectionObservation.Event) -> Void) {
        task?.cancel(); generation = UUID()
        let id = generation
        task = Task { [weak self] in
            guard self?.generation == id, !Task.isCancelled, enabled() else { return }
            let startedAt = now()
            var state = receipt.map { CorrectionObservation(receipt: $0, now: startedAt) }
            self?.report(state == nil ? .awaitingPaste : .observing, status)
            while !Task.isCancelled, state?.ended != true {
                do { try await Task.sleep(for: state == nil ? min(interval, .milliseconds(250)) : interval) } catch { break }
                guard let self, self.generation == id, enabled(), now() - startedAt < CorrectionObservation.lifetime else { break }
                if state == nil, now() - startedAt >= 5 { self.report(.unconfirmed, status); break }
                let rawText = await read()
                let text = expectation == nil ? rawText : rawText.map(InputTextNormalization.field)
                guard !Task.isCancelled, self.generation == id, enabled() else { break }
                if state == nil {
                    guard let text else { self.report(.unavailable, status); break }
                    if let receipt = expectation?.receipt(in: text) {
                        state = CorrectionObservation(receipt: receipt, now: startedAt)
                        self.report(.observing, status)
                    }
                } else {
                    if let event = state?.sample(text, now: now()) { receive(event) }
                    if state?.ended == true { self.report(text == nil ? .unavailable : .finished, status) }
                }
            }
            if let self, self.generation == id {
                if now() - startedAt >= CorrectionObservation.lifetime { self.report(.finished, status) }
                self.stop()
            }
        }
    }
    private func report(_ value: Status, _ receive: (Status) -> Void) {
        logger.info("Correction observation state=\(value.rawValue, privacy: .public)")
        receive(value)
    }
}

/// AX calls run on one utility queue with a short IPC timeout, so a stalled
/// target app cannot hold up recording, model output, or the app's main thread.
private final class CorrectionAXReader: @unchecked Sendable {
    private let target: TextInsertionService.Target
    private let application: AXUIElement
    private let queue = DispatchQueue(label: "com.opentypeless.dictionary-ax", qos: .utility)
    private var observer: AXObserver?
    // Accessed only on the main actor. Notifications permit skipping unchanged
    // value reads; periodic focus checks still end observation on target changes.
    @MainActor private var changed = true
    @MainActor private var lastValue: String?
    @MainActor private var lastFullRead: TimeInterval = 0
    init(target: TextInsertionService.Target) {
        self.target = target
        application = AXUIElementCreateApplication(target.signature.processID)
        AXUIElementSetMessagingTimeout(application, 0.08)
        AXUIElementSetMessagingTimeout(target.element, 0.08)
    }
    @MainActor func startNotifications() {
        var value: AXObserver?
        let result = AXObserverCreate(target.signature.processID, { _, _, _, context in
            guard let context else { return }
            let reader = Unmanaged<CorrectionAXReader>.fromOpaque(context).takeUnretainedValue()
            // The source is attached to the main run loop; no asynchronous
            // callback may outlive the retained reader and its removed source.
            MainActor.assumeIsolated { reader.changed = true }
        }, &value)
        guard result == .success, let value,
              AXObserverAddNotification(value, target.element, kAXValueChangedNotification as CFString,
                                        Unmanaged.passUnretained(self).toOpaque()) == .success else { return }
        observer = value
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(value), .commonModes)
    }
    @MainActor func stopNotifications() {
        guard let observer else { return }
        AXObserverRemoveNotification(observer, target.element, kAXValueChangedNotification as CFString)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }
    @MainActor func read(forceValue: Bool = false) async -> String? {
        let now = ProcessInfo.processInfo.systemUptime
        // Also read once every 3 s when a target claims notification support but
        // fails to emit it (common in custom web editors).
        let readValue = forceValue || observer == nil || changed || now - lastFullRead >= 3
        changed = false
        let previous = lastValue
        let value: String? = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.readTarget(readValue: readValue, previous: previous))
            }
        }
        if readValue { lastFullRead = now; lastValue = value }
        return value
    }
    private func readTarget(readValue: Bool, previous: String?) -> String? {
        let resolution = FocusedTextInput.locate(in: application, pid: target.signature.processID)
        guard let focused = resolution.element,
              CFEqual(focused, target.element),
              let window = resolution.window, CFEqual(window, target.window),
              attribute(focused, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              attribute(focused, "AXProtectedContent") as? Bool != true,
              attribute(focused, kAXEnabledAttribute) as? Bool != false else { return nil }
        // Containers are resolved exactly as in capture; identity must still
        // match the original field and window, never merely the same app.
        guard readValue else { return previous }
        guard let text = attribute(focused, kAXValueAttribute) as? String, text.utf16.count <= 32_768 else { return nil }
        let final = FocusedTextInput.locate(in: application, pid: target.signature.processID)
        guard let stillFocused = final.element, CFEqual(stillFocused, target.element),
              let finalWindow = final.window, CFEqual(finalWindow, target.window) else { return nil }
        return text
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.08)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
