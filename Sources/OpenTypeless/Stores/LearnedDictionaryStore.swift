import Foundation
import Observation
import OpenTypelessCore

@MainActor @Observable final class LearnedDictionaryStore {
    struct Change: Equatable {
        let word: LearnedWord
        let previous: LearnedWord?
    }
    private(set) var words: [LearnedWord] = []
    private(set) var storageError: String?
    private let file: URL
    private var readable = true
    private struct Document: Codable { var version = 1; var words: [LearnedWord] }
    var active: [LearnedWord] { words.filter { $0.status == .active }.sorted { $0.updatedAt > $1.updatedAt } }

    init(root: URL = LocalFiles.root) {
        file = root.appendingPathComponent("learned-dictionary.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
            guard document.version == 1 else { throw AppError.message("词典版本不受支持") }
            words = document.words
        } catch {
            readable = false
            storageError = "个人词典无法读取，已保留原文件和旧词条。"
        }
    }
    /// The in-field edit is the confirmation. Return a receipt for each new
    /// spelling relationship so undo can retain an older word and its aliases.
    @discardableResult func learn(_ correction: WordCorrection, now: Date = Date()) -> Change? {
        guard CorrectionClassifier.validTerm(correction.original),
              CorrectionClassifier.validTerm(correction.replacement) else { return nil }
        var next = words
        if let index = next.firstIndex(where: { $0.term.caseInsensitiveCompare(correction.replacement) == .orderedSame }) {
            let previous = next[index]
            guard previous.status == .active || hasRoomForWord else { return nil }
            next[index].term = correction.replacement; next[index].status = .active
            if previous.status == .excluded {
                // A new deliberate edit confirms this relationship again; old
                // removed aliases must not silently return with it.
                next[index].variants = [correction.original]
            } else if !next[index].variants.contains(correction.original) {
                next[index].variants = Array((next[index].variants + [correction.original]).suffix(8))
            }
            next[index].confirmations += 1; next[index].updatedAt = now
            guard save(next), previous.term != next[index].term || previous.variants != next[index].variants || previous.status != .active else { return nil }
            return Change(word: next[index], previous: previous)
        }
        guard hasRoomForWord else { return nil }
        let word = LearnedWord(term: correction.replacement, variants: [correction.original],
                               status: .active, updatedAt: now)
        next.append(word)
        return save(next) ? Change(word: word, previous: nil) : nil
    }
    /// Save the unified dictionary first. Only a successful result permits the
    /// caller to clear the old settings field; retries do not revive removals.
    @discardableResult func migrateExistingWords(_ legacy: [String]) -> Bool {
        guard readable else { return false }
        var next = words
        for index in next.indices where next[index].status == .pending { next[index].status = .active }
        var seen = Set(next.map { $0.term.lowercased() })
        for term in legacy.map({ String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)) }) where !term.isEmpty {
            guard seen.insert(term.lowercased()).inserted else { continue }
            next.append(LearnedWord(term: term, variants: [], status: .active, updatedAt: .distantPast, confirmations: 0))
        }
        return next == words || save(next)
    }
    @discardableResult func undo(_ change: Change) -> Bool {
        guard let index = words.firstIndex(where: { $0.id == change.word.id }),
              words[index].term == change.word.term, words[index].variants == change.word.variants,
              words[index].status == .active else { return false }
        var next = words
        if let previous = change.previous { next[index] = previous }
        else { next[index].status = .excluded; next[index].updatedAt = Date() }
        return save(next)
    }
    @discardableResult func edit(_ id: UUID, term: String) -> Bool {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CorrectionClassifier.validTerm(term), let index = words.firstIndex(where: { $0.id == id }) else { return false }
        var next = words
        // Editing cannot leave two active versions of the same canonical term.
        if let other = next.firstIndex(where: { $0.id != id && $0.term.caseInsensitiveCompare(term) == .orderedSame }) {
            next[other].term = term; next[other].status = .active; next[other].updatedAt = Date()
            next[other].variants = Array(Set(next[other].variants + next[index].variants)).sorted().prefix(8).map { $0 }
            next.remove(at: index)
        } else {
            next[index].term = term; next[index].status = .active; next[index].updatedAt = Date()
        }
        return save(next)
    }
    @discardableResult func exclude(_ id: UUID) -> Bool {
        guard let index = words.firstIndex(where: { $0.id == id }) else { return false }
        var next = words
        next[index].status = .excluded; next[index].updatedAt = Date()
        return save(next)
    }
    private var hasRoomForWord: Bool {
        guard active.count < 2_000 else {
            storageError = "个人词典已满，请移除不再使用的词条。"; return false
        }
        return true
    }
    private func save(_ next: [LearnedWord]) -> Bool {
        guard readable else { return false }
        do {
            try LocalFiles.write(Document(words: next), to: file)
            words = next; storageError = nil; return true
        } catch {
            storageError = "个人词典未能保存：\(error.localizedDescription)"; return false
        }
    }
}
