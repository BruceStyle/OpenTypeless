import Foundation
import Observation
import OpenTypelessCore

/// A failed session waits separately from the next recording. Its files stay in
/// place until that specific session succeeds, is discarded, or expires.
@MainActor @Observable final class RecoveryQueue {
    var active: RecoveryDraft?
    private(set) var pending: [RecoveryDraft]
    @ObservationIgnored private let store: RecoveryStore

    init(store: RecoveryStore) {
        self.store = store
        pending = store.recoverable()
    }

    func begin(id: UUID, settings: AppSettings) throws {
        preserveActive()
        active = try store.create(id: id, settings: settings)
    }

    func preserveActive() {
        guard let current = active else { return }
        if current.hasContent {
            try? store.save(current)
            pending.removeAll { $0.id == current.id }
            pending.append(current)
            pending.sort { $0.created > $1.created }
        } else { store.remove(current.id) }
        active = nil
    }

    @discardableResult func resume(_ id: UUID) -> Bool {
        guard active == nil, let index = pending.firstIndex(where: { $0.id == id }) else { return false }
        active = pending.remove(at: index)
        return true
    }

    func completeActive(removingFiles: Bool) {
        if removingFiles { discardActive() }
        else { preserveActive() }
    }

    func discardActive() {
        if let active { store.remove(active.id) }
        active = nil
    }

    func discardPending(_ id: UUID) {
        guard pending.contains(where: { $0.id == id }) else { return }
        store.remove(id)
        pending.removeAll { $0.id == id }
    }
}
