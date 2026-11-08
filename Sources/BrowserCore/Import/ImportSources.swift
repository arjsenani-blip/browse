import Foundation

/// A browser data source found on this Mac, for the onboarding import picker.
public struct ImportSource: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable, Hashable {
        /// Arc's sidebar (spaces, pinned tabs, favorites).
        case arcSidebar
        /// A Chromium profile's `Bookmarks` JSON.
        case chromiumBookmarks(browser: String, profile: String)
        /// Safari's `Bookmarks.plist`.
        case safariBookmarks
    }

    public enum Status: Sendable, Equatable {
        case readable
        /// Present (or presumed present) but blocked by privacy protection.
        case needsFullDiskAccess
    }

    public var kind: Kind
    public var url: URL
    public var status: Status
    public var id: String { url.path }

    public var displayName: String {
        switch kind {
        case .arcSidebar: "Arc — spaces, pinned tabs & favorites"
        case .chromiumBookmarks(let browser, let profile): profile == "Default" ? "\(browser) bookmarks" : "\(browser) bookmarks (\(profile))"
        case .safariBookmarks: "Safari bookmarks"
        }
    }

    /// Parses the source into a plan. Call off the main actor; Arc files can be several MB.
    public func load(arcOptions: ArcImporter.Options = .init()) throws(ImportError) -> ImportPlan {
        switch kind {
        case .arcSidebar: try ArcImporter(options: arcOptions).load(from: url)
        case .chromiumBookmarks: try ChromeBookmarksImporter().load(from: url)
        case .safariBookmarks: try SafariBookmarksImporter().load(from: url)
        }
    }
}

public enum ImportSources {
    /// Sources present on this Mac. `home` is injectable for tests.
    public static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ImportSource] {
        let fm = FileManager.default
        var found: [ImportSource] = []

        let arc = home.appending(path: "Library/Application Support/Arc/StorableSidebar.json")
        if fm.isReadableFile(atPath: arc.path) {
            found.append(ImportSource(kind: .arcSidebar, url: arc, status: .readable))
        }

        for browser in ChromeBookmarksImporter.knownChromiumBrowsers {
            if browser.flatProfile {
                let url = browser.defaultBookmarksURL(home: home)
                if fm.isReadableFile(atPath: url.path) {
                    found.append(ImportSource(kind: .chromiumBookmarks(browser: browser.name, profile: "Default"), url: url, status: .readable))
                }
                continue
            }
            let dir = browser.userDataDirectory(home: home)
            guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            let profiles = entries.filter { $0 == "Default" || $0.hasPrefix("Profile ") }
                .sorted { a, b in
                    if a == "Default" { return b != "Default" }
                    if b == "Default" { return false }
                    return a.localizedStandardCompare(b) == .orderedAscending
                }
            for profile in profiles {
                let url = dir.appending(path: profile).appending(path: "Bookmarks")
                if fm.isReadableFile(atPath: url.path) {
                    found.append(ImportSource(kind: .chromiumBookmarks(browser: browser.name, profile: profile), url: url, status: .readable))
                }
            }
        }

        let safari = home.appending(path: "Library/Safari/Bookmarks.plist")
        switch probe(safari) {
        case .readable: found.append(ImportSource(kind: .safariBookmarks, url: safari, status: .readable))
        case .blocked: found.append(ImportSource(kind: .safariBookmarks, url: safari, status: .needsFullDiskAccess))
        case .missing: break
        }
        return found
    }

    enum Probe { case readable, blocked, missing }

    /// Opens the file to learn the truth: TCC can allow `stat` yet fail `open`,
    /// and can hide the file entirely (stat fails with EPERM) — the latter is
    /// still reported as blocked when Safari's folder exists.
    static func probe(_ url: URL) -> Probe {
        let fd = open(url.path, O_RDONLY)
        if fd >= 0 { close(fd); return .readable }
        switch errno {
        case EPERM, EACCES: return .blocked
        case ENOENT:
            // Without FDA, listing ~/Library/Safari also fails with EPERM.
            let dir = url.deletingLastPathComponent().path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return .missing }
            return (try? FileManager.default.contentsOfDirectory(atPath: dir)) == nil ? .blocked : .missing
        default: return .missing
        }
    }
}
