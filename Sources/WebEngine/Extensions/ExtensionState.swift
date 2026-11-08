import Foundation

/// One installed extension as persisted in `<root>/state.json`.
public struct InstalledExtension: Codable, Sendable, Equatable, Identifiable {
    public enum Source: String, Codable, Sendable { case webStore, unpacked }

    public let id: String
    public var name: String
    public var version: String
    public var manifestVersion: Int
    public var source: Source
    public var installedAt: Date
    public var enabled: Bool
    /// The user has seen and answered the install consent sheet. Nothing is
    /// loaded into WebKit until this is true.
    public var consented: Bool
    /// Granted API permissions (`storage`, `tabs`, …) and host match patterns.
    public var grantedPermissions: [String]
    public var grantedMatchPatterns: [String]
    /// Patterns the user explicitly refused, so WebKit won't re-prompt.
    public var deniedMatchPatterns: [String]
    public var hasRequestedOptionalAccessToAllHosts: Bool
    /// May run in private windows; off unless the user opts in.
    public var allowInPrivate: Bool

    public init(id: String, manifest: ExtensionManifest, source: Source) {
        self.id = id
        name = manifest.name
        version = manifest.version
        manifestVersion = manifest.manifestVersion
        self.source = source
        installedAt = Date()
        enabled = true
        consented = false
        grantedPermissions = []
        grantedMatchPatterns = []
        deniedMatchPatterns = []
        hasRequestedOptionalAccessToAllHosts = false
        allowInPrivate = false
    }
}

struct ExtensionStateFile: Codable, Sendable {
    var version = 1
    /// Identifier for the persistent `WKWebExtensionController` configuration,
    /// so extension storage survives relaunches and is ours alone.
    var controllerID = UUID()
    var extensions: [InstalledExtension] = []
}

/// JSON persistence, written atomically.
struct ExtensionStateStore: Sendable {
    let url: URL

    init(root: URL) { url = root.appending(path: "state.json") }

    func load() -> ExtensionStateFile {
        guard let data = try? Data(contentsOf: url),
              let file = try? decoder.decode(ExtensionStateFile.self, from: data) else { return ExtensionStateFile() }
        return file
    }

    func save(_ file: ExtensionStateFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(file).write(to: url, options: .atomic)
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// What the consent sheet shows: everything requested that isn't granted yet.
public struct ExtensionPermissionRequest: Sendable, Equatable {
    public let extensionID: String
    public let name: String
    public var permissions: [String]
    public var matchPatterns: [String]

    public var isEmpty: Bool { permissions.isEmpty && matchPatterns.isEmpty }

    /// Plain-language lines for the sheet, worst first.
    public var summary: [String] {
        var lines: [String] = []
        let hosts = matchPatterns.map { Self.host(ofPattern: $0) }
        if hosts.contains("*") {
            lines.append("Read and change all your data on all websites")
        } else if !hosts.isEmpty {
            lines.append("Read and change your data on " + Set(hosts).sorted().prefix(5).joined(separator: ", ")
                         + (hosts.count > 5 ? " and \(hosts.count - 5) more" : ""))
        }
        let phrases: [String: String] = [
            "tabs": "Read your browsing history", "history": "Read and change your browsing history",
            "cookies": "Read and change cookies", "webNavigation": "Read your browsing history",
            "clipboardWrite": "Modify data you copy and paste", "nativeMessaging": "Communicate with native apps",
            "declarativeNetRequest": "Block content on any page", "declarativeNetRequestWithHostAccess": "Block or redirect requests",
            "webRequest": "Observe network requests", "scripting": "Inject scripts into pages",
        ]
        lines += Set(permissions.compactMap { phrases[$0] }).sorted()
        return lines
    }

    /// `*://*.example.com/*` → `example.com`; `<all_urls>` and `*://*/*` → `*`.
    static func host(ofPattern pattern: String) -> String {
        guard pattern != "<all_urls>", let r = pattern.range(of: "://") else { return "*" }
        var host = pattern[r.upperBound...].prefix { $0 != "/" }
        if host.hasPrefix("*.") { host = host.dropFirst(2) }
        return host.isEmpty ? "*" : String(host)
    }
}

/// The user's answer to the consent sheet. Pass a subset to grant only part.
public struct ExtensionPermissionGrant: Sendable, Equatable {
    public let extensionID: String
    public var permissions: [String]
    public var matchPatterns: [String]
    public var allowInPrivate: Bool

    public init(extensionID: String, permissions: [String], matchPatterns: [String], allowInPrivate: Bool = false) {
        self.extensionID = extensionID
        self.permissions = permissions
        self.matchPatterns = matchPatterns
        self.allowInPrivate = allowInPrivate
    }

    /// Grant everything in a request.
    public init(_ request: ExtensionPermissionRequest, allowInPrivate: Bool = false) {
        self.init(extensionID: request.extensionID, permissions: request.permissions,
                  matchPatterns: request.matchPatterns, allowInPrivate: allowInPrivate)
    }
}
