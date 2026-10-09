import Foundation

enum LocalFiles {
    static var root: URL {
        #if DEBUG
        // Isolate UI verification data from the user's dictionary and history.
        // Available only with the explicit verification launch flag.
        if ProcessInfo.processInfo.arguments.contains("--verification"),
           let path = ProcessInfo.processInfo.environment["OPENTYPELESS_VERIFICATION_ROOT"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenTypeless", isDirectory: true)
    }
    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try prepare(url.deletingLastPathComponent())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
