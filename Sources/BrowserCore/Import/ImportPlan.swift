import Foundation

// MARK: - Plan

/// One tab to create from an import. `folderPath` keeps the source folder
/// nesting (outermost first) so a future folder-aware sidebar can rebuild it;
/// today the tabs are created flat, in source order, with their own titles.
public struct PlannedTab: Sendable, Equatable, Hashable {
    public var title: String
    public var url: URL
    public var folderPath: [String]

    public init(title: String, url: URL, folderPath: [String] = []) {
        self.title = title
        self.url = url
        self.folderPath = folderPath
    }
}

public struct PlannedSpace: Sendable, Equatable {
    public var name: String
    /// Accent hue 0…1.
    public var hue: Double
    public var favorites: [PlannedTab]
    public var pinned: [PlannedTab]
    /// Arc's unpinned ("today") tabs; empty unless the importer was asked for them.
    public var today: [PlannedTab]
    /// The source browser's profile directory (Arc: "Default", "Profile 1", …), if known.
    public var sourceProfile: String?
    /// Arc space emoji, if any. Informational.
    public var icon: String?

    public init(
        name: String,
        hue: Double,
        favorites: [PlannedTab] = [],
        pinned: [PlannedTab] = [],
        today: [PlannedTab] = [],
        sourceProfile: String? = nil,
        icon: String? = nil
    ) {
        self.name = name
        self.hue = hue
        self.favorites = favorites
        self.pinned = pinned
        self.today = today
        self.sourceProfile = sourceProfile
        self.icon = icon
    }
}

/// Where a bookmark sat in its source browser.
public enum BookmarkRoot: String, Sendable, Equatable, Codable {
    /// Chrome "Bookmarks bar" / Safari "Favorites" (BookmarksBar).
    case bar
    /// Chrome "Other bookmarks" / Safari "Bookmarks Menu" and loose top-level items.
    case other
    /// Chrome "Mobile bookmarks".
    case mobile
    /// Safari Reading List (only when requested).
    case readingList
}

public struct ImportedBookmark: Sendable, Equatable, Hashable {
    public var title: String
    public var url: URL
    /// Folder names from the root down, starting with the root's display name
    /// (e.g. `["Bookmarks bar", "Dev"]`).
    public var folderPath: [String]
    public var root: BookmarkRoot

    public init(title: String, url: URL, folderPath: [String], root: BookmarkRoot) {
        self.title = title
        self.url = url
        self.folderPath = folderPath
        self.root = root
    }

    /// Directly on the bookmark bar, not inside a folder on it.
    public var isTopLevelOfBar: Bool { root == .bar && folderPath.count <= 1 }
}

/// Everything an import would create, produced by the parsers (pure, off-main-safe)
/// and applied to a `BrowserStore` on the main actor.
public struct ImportPlan: Sendable, Equatable {
    public var spaces: [PlannedSpace]
    public var bookmarks: [ImportedBookmark]
    public var warnings: [String]

    public init(spaces: [PlannedSpace] = [], bookmarks: [ImportedBookmark] = [], warnings: [String] = []) {
        self.spaces = spaces
        self.bookmarks = bookmarks
        self.warnings = warnings
    }

    public var isEmpty: Bool { spaces.isEmpty && bookmarks.isEmpty }

    /// Combines plans from several sources (e.g. Arc + Chrome bookmarks).
    public func merged(with other: ImportPlan) -> ImportPlan {
        ImportPlan(spaces: spaces + other.spaces, bookmarks: bookmarks + other.bookmarks, warnings: warnings + other.warnings)
    }
}

// MARK: - Errors

public enum ImportError: Error, Sendable, Equatable {
    /// No file at the path.
    case notFound(URL)
    /// The file exists but macOS privacy protection (TCC) blocks reading it.
    /// Ask the user to grant Full Disk Access in System Settings → Privacy & Security.
    case needsFullDiskAccess(URL)
    /// Some other read failure.
    case unreadable(URL, String)
    /// The file isn't in the expected format at all.
    case malformed(String)
}

extension ImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let url): "No file at \(url.path)."
        case .needsFullDiskAccess(let url):
            "Aegis needs Full Disk Access to read \(url.lastPathComponent). Open System Settings → Privacy & Security → Full Disk Access, enable Aegis, then try again."
        case .unreadable(let url, let reason): "Couldn't read \(url.path): \(reason)"
        case .malformed(let reason): "The file isn't in a format Aegis understands: \(reason)"
        }
    }
}

// MARK: - Shared helpers

enum ImportIO {
    /// Reads a file, mapping permission failures to `.needsFullDiskAccess`.
    static func read(_ url: URL) throws(ImportError) -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw classify(error, url: url)
        }
    }

    static func classify(_ error: any Error, url: URL) -> ImportError {
        let ns = error as NSError
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
            ?? (ns.domain == NSPOSIXErrorDomain ? ns.code : nil)
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .notFound(url)
            case NSFileReadNoPermissionError: return .needsFullDiskAccess(url)
            default: break
            }
        }
        switch posix.map(Int32.init) {
        case ENOENT?: return .notFound(url)
        case EPERM?, EACCES?: return .needsFullDiskAccess(url)
        default: return .unreadable(url, ns.localizedDescription)
        }
    }
}

enum ImportURL {
    /// Only web URLs become tabs; `arc://`, `chrome://`, `javascript:`, extension
    /// pages, etc. are dropped.
    static func web(_ raw: Any?) -> URL? {
        guard let string = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty,
              let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    /// Key used to dedupe tabs within a space: lowercased scheme/host, no
    /// fragment, no trailing slash.
    static func dedupeKey(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        c.fragment = nil
        var s = c.string ?? url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

enum ImportText {
    static func clean(_ raw: Any?) -> String? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

/// Spreads fallback hues around the wheel (golden ratio), starting near the
/// default space's teal.
enum ImportHue {
    static func fallback(_ index: Int) -> Double {
        (0.48 + Double(index) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
    }

    /// Hue 0…1 of an sRGB color with components 0…1; nil for near-greys.
    static func hue(red r: Double, green g: Double, blue b: Double) -> Double? {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        guard maxC > 0, delta / maxC >= 0.08, delta > 0.02 else { return nil }
        var h: Double
        if maxC == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if maxC == g { h = (b - r) / delta + 2 }
        else { h = (r - g) / delta + 4 }
        h /= 6
        if h < 0 { h += 1 }
        return h
    }
}
