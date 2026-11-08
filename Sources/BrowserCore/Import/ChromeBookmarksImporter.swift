import Foundation

/// A Chromium-based browser whose profile stores a `Bookmarks` JSON file.
public struct ChromiumBrowser: Sendable, Equatable, Hashable {
    public var name: String
    /// User-data directory relative to the home folder (holds `Default/`, `Profile 1/`, …).
    public var userDataPath: String
    /// Opera keeps `Bookmarks` directly in the user-data directory (no profile folders).
    public var flatProfile: Bool

    public init(name: String, userDataPath: String, flatProfile: Bool = false) {
        self.name = name
        self.userDataPath = userDataPath
        self.flatProfile = flatProfile
    }

    public func userDataDirectory(home: URL) -> URL {
        home.appending(path: userDataPath, directoryHint: .isDirectory)
    }

    /// `Default/Bookmarks` (or `Bookmarks` for flat profiles).
    public func defaultBookmarksURL(home: URL) -> URL {
        let dir = userDataDirectory(home: home)
        return flatProfile ? dir.appending(path: "Bookmarks") : dir.appending(path: "Default/Bookmarks")
    }
}

/// Parses Chromium's `Bookmarks` file:
///
/// ```
/// { "checksum": "…", "version": 1,
///   "roots": { "bookmark_bar": {"type": "folder", "name": "Bookmarks bar", "children": [ … ]},
///              "other": {…}, "synced": {…} } }
/// ```
/// Nodes are `{"type": "url", "name", "url", …}` or `{"type": "folder", "name", "children"}`.
public struct ChromeBookmarksImporter: Sendable {
    public static let knownChromiumBrowsers: [ChromiumBrowser] = [
        ChromiumBrowser(name: "Google Chrome", userDataPath: "Library/Application Support/Google/Chrome"),
        ChromiumBrowser(name: "Google Chrome Beta", userDataPath: "Library/Application Support/Google/Chrome Beta"),
        ChromiumBrowser(name: "Google Chrome Canary", userDataPath: "Library/Application Support/Google/Chrome Canary"),
        ChromiumBrowser(name: "Chromium", userDataPath: "Library/Application Support/Chromium"),
        ChromiumBrowser(name: "Brave", userDataPath: "Library/Application Support/BraveSoftware/Brave-Browser"),
        ChromiumBrowser(name: "Microsoft Edge", userDataPath: "Library/Application Support/Microsoft Edge"),
        ChromiumBrowser(name: "Vivaldi", userDataPath: "Library/Application Support/Vivaldi"),
        ChromiumBrowser(name: "Arc", userDataPath: "Library/Application Support/Arc/User Data"),
        ChromiumBrowser(name: "Dia", userDataPath: "Library/Application Support/Dia/User Data"),
        ChromiumBrowser(name: "Opera", userDataPath: "Library/Application Support/com.operasoftware.Opera", flatProfile: true),
    ]

    /// Default-profile `Bookmarks` paths for every known Chromium browser,
    /// whether or not they exist. `ImportSources.detect()` also finds `Profile N`.
    public static var knownChromiumBookmarkPaths: [(browser: String, url: URL)] {
        knownChromiumBookmarkPaths(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    public static func knownChromiumBookmarkPaths(home: URL) -> [(browser: String, url: URL)] {
        knownChromiumBrowsers.map { ($0.name, $0.defaultBookmarksURL(home: home)) }
    }

    public init() {}

    public func load(from url: URL) throws(ImportError) -> ImportPlan {
        try parse(ImportIO.read(url))
    }

    public func parse(_ data: Data) throws(ImportError) -> ImportPlan {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) }
        catch { throw .malformed("Bookmarks file is not valid JSON") }
        guard let top = root as? [String: Any], let roots = top["roots"] as? [String: Any] else {
            throw .malformed("Bookmarks file has no \"roots\"")
        }

        var walker = Walker()
        let known: [(key: String, fallbackName: String, root: BookmarkRoot)] = [
            ("bookmark_bar", "Bookmarks bar", .bar),
            ("other", "Other bookmarks", .other),
            ("synced", "Mobile bookmarks", .mobile),
        ]
        for entry in known {
            guard let node = roots[entry.key] as? [String: Any] else { continue }
            let name = ImportText.clean(node["name"]) ?? entry.fallbackName
            walker.walkChildren(of: node, path: [name], root: entry.root, depth: 0)
        }
        // Unknown extra roots (some forks add their own, e.g. Vivaldi "trash" is skipped).
        for key in roots.keys.sorted() where !known.contains(where: { $0.key == key }) && key != "trash" {
            guard let node = roots[key] as? [String: Any] else { continue }
            walker.walkChildren(of: node, path: [ImportText.clean(node["name"]) ?? key], root: .other, depth: 0)
        }

        var warnings: [String] = []
        if walker.skipped > 0 { warnings.append("Skipped \(walker.skipped) bookmark(s) without a web URL (javascript:, chrome://, …).") }
        if walker.malformed > 0 { warnings.append("Ignored \(walker.malformed) malformed bookmark node(s).") }
        return ImportPlan(bookmarks: walker.result, warnings: warnings)
    }

    private struct Walker {
        var result: [ImportedBookmark] = []
        var skipped = 0
        var malformed = 0

        mutating func walkChildren(of node: [String: Any], path: [String], root: BookmarkRoot, depth: Int) {
            guard depth < 64, let children = node["children"] as? [Any] else { return }
            for child in children {
                guard let child = child as? [String: Any] else { malformed += 1; continue }
                let type = child["type"] as? String
                if type == "folder" || (type == nil && child["children"] != nil) {
                    walkChildren(of: child, path: path + [ImportText.clean(child["name"]) ?? "Folder"], root: root, depth: depth + 1)
                } else if type == "url" || child["url"] != nil {
                    guard let url = ImportURL.web(child["url"]) else { skipped += 1; continue }
                    let title = ImportText.clean(child["name"]) ?? url.host() ?? url.absoluteString
                    result.append(ImportedBookmark(title: title, url: url, folderPath: path, root: root))
                } else {
                    malformed += 1
                }
            }
        }
    }
}
