import Foundation

/// Parses Safari's `~/Library/Safari/Bookmarks.plist` (binary plist).
///
/// Nodes carry `WebBookmarkType`:
/// - `WebBookmarkTypeList`: folder with `Title` and `Children`. Top-level
///   titles `BookmarksBar` (shown as "Favorites"), `BookmarksMenu`, and
///   `com.apple.ReadingList`.
/// - `WebBookmarkTypeLeaf`: `URLString`, title in `URIDictionary.title`.
/// - `WebBookmarkTypeProxy`: the History entry; skipped.
///
/// `~/Library/Safari` is TCC-protected: without Full Disk Access the read fails
/// with EPERM, surfaced as `ImportError.needsFullDiskAccess`.
public struct SafariBookmarksImporter: Sendable {
    public static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Safari/Bookmarks.plist")
    }

    /// Settings deep link for the Full Disk Access pane (for the onboarding UI).
    public static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    public var includeReadingList: Bool
    public init(includeReadingList: Bool = false) { self.includeReadingList = includeReadingList }

    public func load(from url: URL = SafariBookmarksImporter.defaultPath) throws(ImportError) -> ImportPlan {
        try parse(ImportIO.read(url))
    }

    public func parse(_ data: Data) throws(ImportError) -> ImportPlan {
        let root: Any
        do { root = try PropertyListSerialization.propertyList(from: data, format: nil) }
        catch { throw .malformed("Bookmarks.plist is not a property list") }
        guard let top = root as? [String: Any], top["Children"] != nil || top["WebBookmarkType"] != nil else {
            throw .malformed("Bookmarks.plist has no bookmark tree")
        }

        var walker = Walker(includeReadingList: includeReadingList)
        walker.walkChildren(of: top, path: [], root: .other, depth: 0)
        var warnings: [String] = []
        if walker.skipped > 0 { warnings.append("Skipped \(walker.skipped) Safari bookmark(s) without a web URL.") }
        if walker.malformed > 0 { warnings.append("Ignored \(walker.malformed) malformed Safari bookmark node(s).") }
        return ImportPlan(bookmarks: walker.result, warnings: warnings)
    }

    private struct Walker {
        let includeReadingList: Bool
        var result: [ImportedBookmark] = []
        var skipped = 0
        var malformed = 0

        mutating func walkChildren(of node: [String: Any], path: [String], root: BookmarkRoot, depth: Int) {
            guard depth < 64, let children = node["Children"] as? [Any] else { return }
            for child in children {
                guard let child = child as? [String: Any] else { malformed += 1; continue }
                switch child["WebBookmarkType"] as? String {
                case "WebBookmarkTypeList":
                    let title = (child["Title"] as? String) ?? ""
                    var childRoot = root
                    var name = ImportText.clean(title) ?? "Folder"
                    if depth == 0 {
                        switch title {
                        case "BookmarksBar": childRoot = .bar; name = "Favorites"
                        case "BookmarksMenu": childRoot = .other; name = "Bookmarks Menu"
                        case "com.apple.ReadingList":
                            guard includeReadingList else { continue }
                            childRoot = .readingList; name = "Reading List"
                        default: break
                        }
                    }
                    walkChildren(of: child, path: path + [name], root: childRoot, depth: depth + 1)
                case "WebBookmarkTypeLeaf":
                    guard let url = ImportURL.web(child["URLString"]) else { skipped += 1; continue }
                    let uri = child["URIDictionary"] as? [String: Any]
                    let title = ImportText.clean(uri?["title"]) ?? ImportText.clean(child["Title"]) ?? url.host() ?? url.absoluteString
                    result.append(ImportedBookmark(title: title, url: url, folderPath: path, root: root))
                case "WebBookmarkTypeProxy":
                    continue
                default:
                    malformed += 1
                }
            }
        }
    }
}
