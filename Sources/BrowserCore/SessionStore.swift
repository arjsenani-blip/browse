import Foundation

public struct SessionSnapshot: Codable, Sendable {
    public var version = 1
    public var profiles: [Profile]
    public var spaces: [Space]
    public var tabs: [TabRecord]
    public var archive: [ArchivedTab]
    public var currentSpaceID: UUID
}

/// Saves the session as JSON with file protection. Writes are atomic.
public struct SessionStore: Sendable {
    public let url: URL

    public init(directory: URL) {
        url = directory.appending(path: "session.json")
    }

    public func load() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    public func save(_ snapshot: SessionSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

public enum AppPaths {
    /// ~/Library/Application Support/Aegis
    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Aegis", directoryHint: .isDirectory)
    }
}
