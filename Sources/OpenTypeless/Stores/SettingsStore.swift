import Foundation
import Observation
import OpenTypelessCore

@MainActor @Observable final class SettingsStore {
    var configuration: AppSettings { didSet { persist() } }
    var hasKey = false
    var storageError: String?
    private let file = LocalFiles.root.appendingPathComponent("settings.json")
    init() {
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            configuration = decoded
        } else { configuration = AppSettings() }
        refreshKeyStatus()
    }
    func refreshKeyStatus() {
        do { hasKey = try KeychainStore.read()?.isEmpty == false }
        catch { storageError = error.localizedDescription; hasKey = false }
    }
    func saveKey(_ key: String) throws { try KeychainStore.save(key); hasKey = true }
    func removeKey() throws { try KeychainStore.remove(); hasKey = false }
    private func persist() {
        do { try LocalFiles.write(configuration, to: file); storageError = nil }
        catch { storageError = "设置未能保存：\(error.localizedDescription)" }
    }
}
