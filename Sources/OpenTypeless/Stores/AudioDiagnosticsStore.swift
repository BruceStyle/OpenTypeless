import Foundation
import OpenTypelessCore

/// Short-lived, opt-in copies of the original and planned recognition intervals.
/// Separate from Recovery so completed dictations never become recovery drafts.
@MainActor final class AudioDiagnosticsStore {
    private struct Manifest: Codable {
        let created: Date
        let expires: Date
        let overlaps: [Bool]
        var hasContinuousOriginal: Bool?
    }
    private let root: URL
    init(root: URL = LocalFiles.root.appendingPathComponent("AudioDiagnostics", isDirectory: true)) { self.root = root }

    func preserve(id: UUID, chunks: [(data: Data, overlap: Bool)], original: Data? = nil, now: Date = Date()) throws {
        guard !chunks.isEmpty || original != nil else { return }
        let folder = directory(id)
        try LocalFiles.prepare(folder)
        do {
            for (index, chunk) in chunks.enumerated() {
                let url = folder.appendingPathComponent("chunk-\(index).wav")
                try chunk.data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            if let original {
                let url = folder.appendingPathComponent("recording.wav")
                try original.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            try LocalFiles.write(Manifest(created: now, expires: now.addingTimeInterval(86_400), overlaps: chunks.map(\.overlap), hasContinuousOriginal: original != nil),
                                 to: folder.appendingPathComponent("manifest.json"))
        } catch {
            remove(id)
            throw error
        }
        prune(now: now)
    }

    func folder(for id: UUID, now: Date = Date()) -> URL? {
        let folder = directory(id)
        guard let manifest = manifest(in: folder), manifest.expires > now else { return nil }
        return folder
    }

    func prune(now: Date = Date()) {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        var retained: [(id: UUID, created: Date)] = []
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            guard let metadata = manifest(in: folder), metadata.expires > now else { remove(id); continue }
            retained.append((id, metadata.created))
        }
        for entry in retained.sorted(by: { $0.created > $1.created }).dropFirst(10) { remove(entry.id) }
    }

    func remove(_ id: UUID) { try? FileManager.default.removeItem(at: directory(id)) }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func manifest(in folder: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }
}
