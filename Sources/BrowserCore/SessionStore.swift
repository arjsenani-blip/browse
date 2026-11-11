import Foundation

public struct SessionSnapshot: Codable, Sendable {
    public var version = 1
    public var profiles: [Profile]
    public var spaces: [Space]
    public var tabs: [TabRecord]
    public var archive: [ArchivedTab]
    public var currentSpaceID: UUID
}

/// Saves the session as JSON. Writes are atomic and keep the previous copy.
///
/// Never treats "can't read" as "no session": a file that exists but can't be
/// read (for example while the screen is locked, if it was ever written with
/// data protection) or decoded is set aside, not overwritten, and restored on
/// a later launch.
public struct SessionStore: Sendable {
    public let url: URL
    var previousURL: URL { url.deletingLastPathComponent().appending(path: "session.prev.json") }
    var setAsideURL: URL { url.deletingLastPathComponent().appending(path: "session.unreadable.json") }

    public init(directory: URL) {
        url = directory.appending(path: "session.json")
    }

    public func load() -> SessionSnapshot? {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            if let snap = Self.read(url) { return snap }
            // Exists but unreadable or corrupt: move it aside (rename is allowed
            // even when the contents are protected) so the next save can't clobber it.
            try? fm.removeItem(at: setAsideURL)
            try? fm.moveItem(at: url, to: setAsideURL)
        }
        // Try what we set aside earlier (now readable?), then the previous copy.
        for candidate in [setAsideURL, previousURL] where fm.fileExists(atPath: candidate.path) {
            if let snap = Self.read(candidate) { return snap }
        }
        return nil
    }

    static func read(_ url: URL) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    public func save(_ snapshot: SessionSnapshot) throws {
        let fm = FileManager.default
        let data = try JSONEncoder().encode(snapshot)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Rolling backup of the last good session.
        if Self.read(url) != nil {
            try? fm.removeItem(at: previousURL)
            try? fm.copyItem(at: url, to: previousURL)
        }
        // No file protection: the session must stay readable while the Mac is locked.
        try data.write(to: url, options: [.atomic])
        // Once a fresh session is safely written, a recovered set-aside copy is obsolete.
        if fm.fileExists(atPath: setAsideURL.path), Self.read(setAsideURL) != nil {
            try? fm.removeItem(at: setAsideURL)
        }
    }
}

public enum AppPaths {
    /// ~/Library/Application Support/Aegis, or "Aegis Dev" for development
    /// bundles (bundle ID ending in .dev), so test runs never touch real data.
    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
        return base.appending(path: dev ? "Aegis Dev" : "Aegis", directoryHint: .isDirectory)
    }
}
