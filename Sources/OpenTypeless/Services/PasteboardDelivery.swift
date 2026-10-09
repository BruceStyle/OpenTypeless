import AppKit
import OpenTypelessCore

/// Clipboard ownership outlives the foreground confirmation. A following paste
/// inherits the original backup, never the previous dictation's temporary text.
@MainActor final class PasteboardDelivery {
    private struct Ownership {
        let id: UUID
        let changeCount: Int
        let backup: [[NSPasteboard.PasteboardType: Data]]
    }
    private let pasteboard: NSPasteboard
    private var ownership: Ownership?
    private var cleanup: Task<Void, Never>?

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func write(_ text: String) throws -> UUID {
        let backup: [[NSPasteboard.PasteboardType: Data]]
        if let ownership, pasteboard.changeCount == ownership.changeCount {
            backup = ownership.backup
        } else {
            var saved: [[NSPasteboard.PasteboardType: Data]] = []
            var totalBytes = 0
            for item in pasteboard.pasteboardItems ?? [] {
                var values: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) { totalBytes += data.count; values[type] = data }
                    guard totalBytes <= 16_000_000 else { throw AppError.message("剪贴板包含较大内容，请手动复制结果") }
                }
                saved.append(values)
            }
            backup = saved
        }
        cleanup?.cancel(); cleanup = nil
        pasteboard.clearContents()
        let written = pasteboard.setString(text, forType: .string)
        let id = UUID()
        ownership = Ownership(id: id, changeCount: pasteboard.changeCount, backup: backup)
        guard written else {
            restore(id)
            throw AppError.message("无法写入剪贴板，请重试")
        }
        return id
    }

    func restore(_ id: UUID, after delay: Duration) {
        guard ownership?.id == id else { return }
        cleanup?.cancel()
        // Unstructured cleanup is independent of the dictation's cancellation.
        cleanup = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.restore(id)
        }
    }

    func restore(_ id: UUID) {
        guard let saved = ownership, saved.id == id else { return }
        ownership = nil
        cleanup?.cancel(); cleanup = nil
        guard pasteboard.changeCount == saved.changeCount else { return }
        pasteboard.clearContents()
        let items = saved.backup.map { backup in
            let item = NSPasteboardItem()
            for (type, data) in backup { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}

@MainActor enum PasteConfirmation {
    static func wait(expected: String?, readValue: () -> String?,
                     sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async -> Bool {
        guard let expected else { return false }
        for _ in 0..<3 {
            do { try await sleep(.milliseconds(100)) } catch { return false }
            guard !Task.isCancelled else { return false }
            if readValue() == expected { return true }
        }
        return false
    }
}
