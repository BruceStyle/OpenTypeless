import AppKit
import ApplicationServices
import CryptoKit
import OSLog
import OpenTypelessCore

@MainActor final class TextInsertionService {
    private let logger = Logger(subsystem: "com.opentypeless.mac", category: "Insertion")
    private let clipboard = PasteboardDelivery()
    struct Target {
        let element: AXUIElement
        let window: AXUIElement
        let signature: FocusSignature
        let originalValue: String?
        let application: String
    }
    struct CapturePreparation {
        let pid: pid_t
        let window: AXUIElement
        let needsChromiumWarmup: Bool
    }
    enum Delivery {
        case verified, unverified, preview(String)
        var label: String {
            switch self { case .verified: return "已回填"; case .unverified: return "已尝试粘贴，请核对输入框"; case .preview(let reason): return reason }
        }
    }
    static var trusted: Bool { AXIsProcessTrusted() }
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func prepareFocusedApplication(expectedPID: pid_t) -> CapturePreparation? {
        guard Self.trusted, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier == expectedPID,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.08)
        guard let window = focusedWindow(application) else { return nil }
        // Electron documents this attribute for assistive applications. Other
        // apps can report unsupported; no system preference is changed.
        let result = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        logger.info("Accessibility preparation; app=\(app.bundleIdentifier ?? "unknown", privacy: .public), attribute=AXManualAccessibility, status=\(result.rawValue, privacy: .public)")
        // Current Codex uses BrowserCrApplication, not Electron. Chromium's
        // setter can enable accessibility yet return an error from
        // super, so confirm readiness by finding the input, not by this status.
        let needsChromiumWarmup = app.bundleIdentifier == "com.openai.codex" && result != .success
        if needsChromiumWarmup {
            let enhanced = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            logger.info("Accessibility preparation; app=\(app.bundleIdentifier ?? "unknown", privacy: .public), attribute=AXEnhancedUserInterface, status=\(enhanced.rawValue, privacy: .public)")
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID else { return nil }
        return CapturePreparation(pid: expectedPID, window: window, needsChromiumWarmup: needsChromiumWarmup)
    }
    func captureWhenReady(_ preparation: CapturePreparation) async -> Target? {
        let application = AXUIElementCreateApplication(preparation.pid)
        AXUIElementSetMessagingTimeout(application, 0.08)
        let started = ProcessInfo.processInfo.systemUptime
        let target: Target? = await FocusCaptureRetry.wait(
            delays: preparation.needsChromiumWarmup ? FocusCaptureRetry.chromiumDelays : FocusCaptureRetry.standardDelays,
            isOriginalWindowFocused: {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == preparation.pid,
                      let window = self.focusedWindow(application) else { return false }
                return CFEqual(window, preparation.window)
            }, capture: {
                guard let target = self.capture(), CFEqual(target.window, preparation.window) else { return nil }
                return target
            })
        logger.info("Deferred focus capture; captured=\(target != nil, privacy: .public), chromium=\(preparation.needsChromiumWarmup, privacy: .public), elapsed=\(ProcessInfo.processInfo.systemUptime - started, privacy: .public)")
        return target
    }
    private func focusedWindow(_ application: AXUIElement) -> AXUIElement? {
        guard let raw = attribute(application, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }
    func capture() -> Target? {
        guard Self.trusted, let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            logger.notice("Capture unavailable: permission, foreground app, or own window")
            return nil
        }
        let target = capture(in: app)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return nil }
        return target
    }
    #if DEBUG
    func dictionaryVerificationTarget() -> Target? {
        guard Self.trusted, ProcessInfo.processInfo.arguments.contains("--verification"),
              ProcessInfo.processInfo.environment["OPENTYPELESS_VERIFICATION_ROOT"] != nil,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first,
              let target = capture(in: app),
              target.originalValue == "OpenTypeless dictionary test: 请用 CodePliot 和 扣得克斯 测试词典。" else { return nil }
        return target
    }
    #endif
    private func capture(in app: NSRunningApplication) -> Target? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        let resolution = FocusedTextInput.locate(in: application, pid: app.processIdentifier)
        guard let element = resolution.element, let window = resolution.window else {
            logger.notice("Capture unavailable; stage=\(resolution.stage, privacy: .public), source=\(resolution.source, privacy: .public), app=\(app.bundleIdentifier ?? "unknown", privacy: .public), appError=\(resolution.appError, privacy: .public), systemError=\(resolution.systemError, privacy: .public), windowError=\(resolution.windowError, privacy: .public), rootRole=\(resolution.rootRole, privacy: .public), visited=\(resolution.visited, privacy: .public), limitReached=\(resolution.limitReached, privacy: .public)")
            return nil
        }
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success, elementPID == app.processIdentifier else { return nil }
        let value = attribute(element, kAXValueAttribute) as? String
        let signature = signature(element, pid: app.processIdentifier)
        let role = attribute(element, kAXRoleAttribute) as? String ?? "unknown"
        logger.notice("Focus check: app=\(app.bundleIdentifier ?? "unknown", privacy: .public), role=\(role, privacy: .public), hasValue=\(value != nil, privacy: .public), hasSelection=\(signature.selectionLocation != nil, privacy: .public)")
        guard signature.editable, !signature.secure else {
            logger.notice("Capture refused: editable=\(signature.editable, privacy: .public), secure=\(signature.secure, privacy: .public)")
            return nil
        }
        logger.info("Captured editable target; pid=\(app.processIdentifier, privacy: .public), source=\(resolution.source, privacy: .public), hasSelection=\(signature.selectionLocation != nil, privacy: .public)")
        return Target(element: element, window: window, signature: signature, originalValue: value, application: app.localizedName ?? "原应用")
    }

    func insert(_ text: String, into original: Target?,
                onPasted: ((Target, InsertionExpectation) -> Void)? = nil,
                onVerified: ((Target, InsertionReceipt) -> Void)? = nil,
                onPosted: ((TimeInterval) -> Void)? = nil) async -> Delivery {
        guard let original else {
            logger.notice("Insertion skipped: initial target unavailable")
            return .preview("录音开始时没有定位到输入框，请复制结果")
        }
        guard let current = capture() else {
            logger.notice("Insertion skipped: current target unavailable")
            return .preview("当前没有定位到输入框，请复制结果")
        }
        let sameElement = CFEqual(original.element, current.element), sameWindow = CFEqual(original.window, current.window)
        guard InsertionPolicy.permits(original: original.signature, current: current.signature,
                                      sameElement: sameElement, sameWindow: sameWindow) else {
            let valueChanged = original.signature.valueDigest != current.signature.valueDigest
            let selectionChanged = original.signature.selectionLocation != current.signature.selectionLocation
                || original.signature.selectionLength != current.signature.selectionLength
            logger.notice("Insertion skipped: sameElement=\(sameElement, privacy: .public), sameWindow=\(sameWindow, privacy: .public), valueChanged=\(valueChanged, privacy: .public), selectionChanged=\(selectionChanged, privacy: .public)")
            return .preview("输入位置已改变或无法确认，请复制结果")
        }
        let expected: String?
        if let value = original.originalValue,
           let location = original.signature.selectionLocation, let length = original.signature.selectionLength,
           location >= 0, length >= 0, location <= (value as NSString).length,
           length <= (value as NSString).length - location {
            expected = (value as NSString).replacingCharacters(in: NSRange(location: location, length: length), with: text)
        } else {
            // Cmd-V uses the real caret. AXSelectedTextRange is only needed to
            // verify the result; it is not a prerequisite for pasting into a
            // focused, editable, unchanged input.
            expected = nil
        }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return .preview("无法创建粘贴操作，请复制结果")
        }
        guard !Task.isCancelled else { return .preview("听写已取消") }
        let ticket: UUID
        do { ticket = try clipboard.write(text) }
        catch { return .preview(error.localizedDescription) }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        let postedAt = ProcessInfo.processInfo.systemUptime
        onPosted?(postedAt)
        if let value = original.originalValue {
            let range = original.signature.selectionLocation.flatMap { location in
                original.signature.selectionLength.map { NSRange(location: location, length: $0) }
            }
            if let expectation = InsertionExpectation(before: value, selection: range, insertedText: text) {
                // Learning confirms its own readback asynchronously. A slow or
                // reformatted web field must not depend on the 300 ms HUD check.
                onPasted?(original, expectation)
            }
        }
        // Give slow targets the original 1.25 s clipboard lifetime, without
        // keeping the dictation busy. Successful readback permits earlier cleanup.
        clipboard.restore(ticket, after: .milliseconds(1250))
        let verified = await PasteConfirmation.wait(expected: expected) {
            self.attribute(original.element, kAXValueAttribute) as? String
        }
        if verified { clipboard.restore(ticket, after: .milliseconds(250)) }
        if verified, let expected, let location = original.signature.selectionLocation,
           let receipt = InsertionReceipt(baseline: expected, range: NSRange(location: location, length: text.utf16.count), insertedText: text) {
            onVerified?(original, receipt)
        }
        logger.info("Paste confirmation; verified=\(verified, privacy: .public), possible=\(expected != nil, privacy: .public), elapsed=\(ProcessInfo.processInfo.systemUptime - postedAt, privacy: .public)")
        return verified ? .verified : .unverified
    }
    private func signature(_ element: AXUIElement, pid: pid_t) -> FocusSignature {
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
        let value = attribute(element, kAXValueAttribute) as? String
        var range: CFRange?
        if let raw = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
            var selected = CFRange()
            if AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &selected) { range = selected }
        }
        let editableAttribute = attribute(element, "AXEditable") as? Bool
        let explicitlyEditable = editableAttribute == true || settable(element, kAXValueAttribute) || settable(element, kAXSelectedTextAttribute)
        let editable = isInputRole(role) && (attribute(element, kAXEnabledAttribute) as? Bool != false)
            && editableAttribute != false && (explicitlyEditable || range != nil)
        let digest = value.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        return FocusSignature(processID: pid, valueDigest: digest, selectionLocation: range?.location,
                              selectionLength: range?.length, editable: editable,
                              secure: subrole == kAXSecureTextFieldSubrole || attribute(element, "AXProtectedContent") as? Bool == true,
                              explicitlyEditable: explicitlyEditable)
    }
    private func isInputRole(_ role: String) -> Bool {
        [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
    }
    private func settable(_ element: AXUIElement, _ name: String) -> Bool {
        var value = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &value) == .success && value.boolValue
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
