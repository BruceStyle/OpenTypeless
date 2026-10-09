import Foundation
import Observation
import OpenTypelessCore

@MainActor @Observable final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []
    var storageError: String?
    private var unreadable = false
    private let file = LocalFiles.root.appendingPathComponent("history.json")
    private let audioDiagnostics = AudioDiagnosticsStore()
    init() {
        if let data = try? Data(contentsOf: file) {
            do { entries = try JSONDecoder().decode([HistoryEntry].self, from: data) }
            catch { unreadable = true; storageError = "历史文件无法读取，原文件仍保留在本机。" }
        }
    }
    func add(_ entry: HistoryEntry, settings: AppSettings) {
        guard settings.saveHistory else { return }
        entries.insert(entry, at: 0)
        prune(days: settings.historyDays)
    }
    func prune(days: Int) {
        audioDiagnostics.prune()
        let cutoff = Date().addingTimeInterval(-Double(max(1, days)) * 86_400)
        entries = Array(entries.filter { $0.date >= cutoff }.prefix(1_000))
        persist()
    }
    func preserveAudio(_ draft: RecoveryDraft, recovery: RecoveryStore, entryID: UUID) throws {
        let chunks = try draft.chunks.map { (data: try recovery.audio($0, id: draft.id), overlap: $0.overlap) }
        let original = try draft.originalAudio.map { _ in WaveEncoder.wrapPCM(try recovery.originalPCM(draft)) }
        try audioDiagnostics.preserve(id: entryID, chunks: chunks, original: original)
    }
    func audioFolder(for id: UUID) -> URL? { audioDiagnostics.folder(for: id) }
    func delete(_ id: UUID) { audioDiagnostics.remove(id); entries.removeAll { $0.id == id }; persist() }
    func clear() {
        for entry in entries { audioDiagnostics.remove(entry.id) }
        unreadable = false; entries = []; persist()
    }
    private func persist() {
        guard !unreadable else { return }
        do { try LocalFiles.write(entries, to: file); storageError = nil }
        catch { storageError = "历史未能保存：\(error.localizedDescription)" }
    }
}
