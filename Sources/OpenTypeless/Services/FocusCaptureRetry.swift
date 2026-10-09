import Foundation

enum FocusCaptureRetry {
    static let standardDelays: [Duration] = [.milliseconds(80), .milliseconds(160), .milliseconds(240)]
    // Chromium debounces AXEnhancedUserInterface for two seconds. Keep polling
    // beyond that delay without sending another request that resets its timer.
    static let chromiumDelays = standardDelays + Array(repeating: Duration.milliseconds(400), count: 7)

    @MainActor static func wait<T>(delays: [Duration], isOriginalWindowFocused: () -> Bool,
                                   capture: () -> T?,
                                   sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async -> T? {
        for delay in delays {
            guard !Task.isCancelled, isOriginalWindowFocused() else { return nil }
            do { try await sleep(delay) } catch { return nil }
            guard !Task.isCancelled, isOriginalWindowFocused() else { return nil }
            if let target = capture() {
                guard !Task.isCancelled, isOriginalWindowFocused() else { return nil }
                return target
            }
        }
        return nil
    }
}
