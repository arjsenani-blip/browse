import Foundation

/// Reads Arc's sidebar (`~/Library/Application Support/Arc/StorableSidebar.json`).
///
/// Format (undocumented; reverse-engineered by arc-export, Zen, Raycast, Helium):
///
/// ```
/// { "sidebar": { "containers": [ {"global": {}}, {
///     "items":  [ "<id>", {item}, "<id>", {item}, … ],
///     "spaces": [ "<id>", {space}, … ],
///     "topAppsContainerIDs": [ {"default": true}, "<containerID>",
///                              {"custom": {"_0": {"directoryBasename": "Profile 1"}}}, "<containerID>" ]
/// } ] } }
/// ```
///
/// Swift dictionaries are serialized as flat arrays alternating key and value.
/// A space's `containerIDs` is `["unpinned", "<id>", "pinned", "<id>"]` (newer
/// files also have `newContainerIDs` with `{"pinned": {}}` markers). Container
/// ids are item ids; their `childrenIds` (or children's `parentID`) give the
/// ordered tabs (`data.tab.savedURL/savedTitle`), folders (`data.list`) and
/// split views (`data.splitView`). Space theme colors live under
/// `customInfo.windowTheme.background.single._0.style.color._0`.
///
/// The parser never traps: unknown shapes are skipped and reported in `warnings`.
public struct ArcImporter: Sendable {
    public struct Options: Sendable {
        /// Also import each space's unpinned ("Today") tabs.
        public var includeUnpinned: Bool
        /// Only import spaces/favorites belonging to this Arc profile directory
        /// ("Default", "Profile 1", …). nil imports all profiles.
        public var profile: String?
        public init(includeUnpinned: Bool = false, profile: String? = nil) {
            self.includeUnpinned = includeUnpinned
            self.profile = profile
        }
    }

    public static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Arc/StorableSidebar.json")
    }

    public var options: Options
    public init(options: Options = Options()) { self.options = options }

    public func load(from url: URL = ArcImporter.defaultPath) throws(ImportError) -> ImportPlan {
        try parse(ImportIO.read(url))
    }

    /// Throws `.malformed` only when the data isn't a JSON object at all, or has
    /// no recognizable sidebar; everything else degrades to warnings.
    public func parse(_ data: Data) throws(ImportError) -> ImportPlan {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw .malformed("Arc sidebar is not valid JSON") }
        guard let top = root as? [String: Any] else { throw .malformed("Arc sidebar root is not an object") }

        var warnings: [String] = []
        let sidebar = top["sidebar"] as? [String: Any]
        let containers = (sidebar?["containers"] as? [Any]) ?? (top["containers"] as? [Any])
        guard let containers else { throw .malformed("no sidebar.containers in Arc sidebar") }
        guard let main = Self.mainContainer(containers) else {
            throw .malformed("no main (global) container with spaces in Arc sidebar")
        }

        var graph = ItemGraph(main["items"] as? [Any] ?? [])
        if graph.items.isEmpty { warnings.append("Arc sidebar has no items; spaces are imported empty.") }

        // Favorites (Arc "top apps"), per profile.
        var favoritesByProfile: [String: [PlannedTab]] = [:]
        for (marker, containerID) in Self.markerPairs(main["topAppsContainerIDs"]) {
            let profile = Self.profileName(marker)
            favoritesByProfile[profile, default: []] += graph.tabs(under: containerID).map { PlannedTab(title: $0.title, url: $0.url) }
        }

        // Spaces.
        var spaces: [PlannedSpace] = []
        let spaceObjects = Self.objects(main["spaces"])
        if spaceObjects.isEmpty { warnings.append("Arc sidebar has no spaces.") }
        for (index, space) in spaceObjects.enumerated() {
            let profile = Self.profileName(space["profile"])
            if let wanted = options.profile, wanted != profile { continue }
            let name = ImportText.clean(space["title"])
                ?? (space["id"] as? String == "thebrowser.company.defaultPersonalSpaceID" ? "Personal" : "Space \(index + 1)")
            let ids = Self.containerIDs(space)
            var pinned: [PlannedTab] = []
            var today: [PlannedTab] = []
            if let p = ids.pinned { pinned = graph.tabs(under: p) }
            else { warnings.append("Space “\(name)” has no pinned container; imported without pinned tabs.") }
            if options.includeUnpinned, let u = ids.unpinned { today = graph.tabs(under: u) }
            spaces.append(PlannedSpace(
                name: name,
                hue: Self.hue(space) ?? ImportHue.fallback(index),
                favorites: favoritesByProfile[profile] ?? [],
                pinned: pinned,
                today: today,
                sourceProfile: profile,
                icon: Self.icon(space)
            ))
        }

        if spaces.isEmpty, !favoritesByProfile.isEmpty {
            // Favorites but no spaces: keep them rather than dropping them.
            let favs = options.profile.flatMap { favoritesByProfile[$0] } ?? favoritesByProfile.values.flatMap { $0 }
            if !favs.isEmpty { spaces.append(PlannedSpace(name: "Arc", hue: ImportHue.fallback(0), favorites: favs)) }
        }

        if graph.skippedNonWeb > 0 { warnings.append("Skipped \(graph.skippedNonWeb) Arc item(s) without a web URL (arc://, extensions, …).") }
        if graph.skippedOther > 0 { warnings.append("Skipped \(graph.skippedOther) Arc note/easel/unknown item(s).") }
        if graph.hitDepthLimit { warnings.append("Arc folders nested too deeply (or cyclic); some items were skipped.") }
        return ImportPlan(spaces: spaces, warnings: warnings)
    }

    // MARK: Container discovery

    /// The container following a `{"global": {}}` marker; failing that, any
    /// object with `spaces` (skips `littleBrowser` Little Arc sidebars).
    static func mainContainer(_ containers: [Any]) -> [String: Any]? {
        for (i, entry) in containers.enumerated() {
            guard let marker = entry as? [String: Any], marker["global"] != nil else { continue }
            if marker["spaces"] != nil || marker["items"] != nil { return marker }
            if i + 1 < containers.count, let next = containers[i + 1] as? [String: Any] { return next }
        }
        var previousIsLittle = false
        for entry in containers {
            guard let dict = entry as? [String: Any] else { previousIsLittle = false; continue }
            if dict["littleBrowser"] != nil { previousIsLittle = true; continue }
            if dict["spaces"] is [Any], !previousIsLittle { return dict }
            previousIsLittle = false
        }
        return nil
    }

    /// Objects in an alternating `[key, object, key, object]` array (or a plain
    /// array of objects, or a dictionary of objects).
    static func objects(_ raw: Any?) -> [[String: Any]] {
        if let list = raw as? [Any] { return list.compactMap { $0 as? [String: Any] } }
        if let dict = raw as? [String: Any] { return dict.keys.sorted().compactMap { dict[$0] as? [String: Any] } }
        return []
    }

    /// `[marker, "id", marker, "id"]` → pairs where a non-string marker precedes a string id.
    static func markerPairs(_ raw: Any?) -> [(marker: Any, id: String)] {
        guard let list = raw as? [Any] else { return [] }
        var result: [(Any, String)] = []
        var i = 0
        while i + 1 < list.count {
            if !(list[i] is String), let id = list[i + 1] as? String {
                result.append((list[i], id)); i += 2
            } else { i += 1 }
        }
        return result
    }

    /// `{"default": …}` → "Default"; `{"custom": {"_0": {"directoryBasename": "Profile 1"}}}` → "Profile 1".
    static func profileName(_ marker: Any?) -> String {
        let custom = (marker as? [String: Any])?["custom"] as? [String: Any]
        let inner = custom?["_0"] as? [String: Any]
        return ImportText.clean(inner?["directoryBasename"]) ?? "Default"
    }

    static func containerIDs(_ space: [String: Any]) -> (pinned: String?, unpinned: String?) {
        var pinned: String?, unpinned: String?
        for key in ["containerIDs", "newContainerIDs"] {
            guard let list = space[key] as? [Any] else { continue }
            for i in list.indices.dropLast() {
                guard let id = list[i + 1] as? String else { continue }
                let marker = list[i]
                let kind: String? = (marker as? String) ?? (marker as? [String: Any]).flatMap { d in
                    d["pinned"] != nil ? "pinned" : d["unpinned"] != nil ? "unpinned" : nil
                }
                if kind == "pinned", pinned == nil { pinned = id }
                if kind == "unpinned", unpinned == nil { unpinned = id }
            }
        }
        return (pinned, unpinned)
    }

    // MARK: Theme

    static func hue(_ space: [String: Any]) -> Double? {
        let customInfo = space["customInfo"] as? [String: Any]
        guard let theme = customInfo?["windowTheme"] else { return nil }
        // Prefer the documented single-color path, then fall back to the first
        // saturated color anywhere in the theme (gradients, palettes).
        let style = dig(theme, "background", "single", "_0", "style", "color", "_0")
        if let single = dig(style, "blendedSingleColor", "_0", "color"), let h = hue(ofColor: single) { return h }
        if let base = dig(style, "blendedGradient", "_0", "baseColors") as? [Any] {
            for c in base { if let h = hue(ofColor: c) { return h } }
        }
        var found: Double?
        var budget = 2000
        func visit(_ node: Any) {
            guard found == nil, budget > 0 else { return }
            budget -= 1
            if let h = hue(ofColor: node) { found = h; return }
            if let d = node as? [String: Any] { for k in d.keys.sorted() { visit(d[k]!) } }
            else if let a = node as? [Any] { for v in a { visit(v) } }
        }
        visit(style ?? theme)
        return found
    }

    static func hue(ofColor raw: Any?) -> Double? {
        guard let c = raw as? [String: Any],
              let r = (c["red"] as? NSNumber)?.doubleValue,
              let g = (c["green"] as? NSNumber)?.doubleValue,
              let b = (c["blue"] as? NSNumber)?.doubleValue else { return nil }
        if let a = (c["alpha"] as? NSNumber)?.doubleValue, a <= 0 { return nil }
        // Arc stores extended sRGB, occasionally slightly outside 0…1.
        func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
        return ImportHue.hue(red: clamp(r), green: clamp(g), blue: clamp(b))
    }

    static func icon(_ space: [String: Any]) -> String? {
        let iconType = dig(space, "customInfo", "iconType") as? [String: Any]
        if let e = ImportText.clean(iconType?["emoji_v2"]) { return e }
        if let n = (iconType?["emoji"] as? NSNumber)?.uint32Value, let scalar = Unicode.Scalar(n) { return String(Character(scalar)) }
        return nil
    }

    static func dig(_ node: Any?, _ path: String...) -> Any? {
        var current = node
        for key in path { current = (current as? [String: Any])?[key] }
        return current
    }
}

/// Arc's item tree: id → item, with child lookup by `childrenIds` or `parentID`.
struct ItemGraph {
    var items: [String: [String: Any]] = [:]
    var childrenByParent: [String: [String]] = [:]
    var skippedNonWeb = 0
    var skippedOther = 0
    var hitDepthLimit = false
    static let maxDepth = 32

    init(_ raw: [Any]) {
        for case let item as [String: Any] in raw {
            guard let id = item["id"] as? String else { continue }
            items[id] = item
        }
        // Stable order for the parentID fallback: original file order.
        for case let item as [String: Any] in raw {
            guard let id = item["id"] as? String, let parent = item["parentID"] as? String else { continue }
            childrenByParent[parent, default: []].append(id)
        }
    }

    func children(of id: String) -> [String] {
        if let explicit = items[id]?["childrenIds"] as? [Any] {
            let ids = explicit.compactMap { $0 as? String }.filter { items[$0] != nil }
            if !ids.isEmpty { return ids }
        }
        return childrenByParent[id] ?? []
    }

    /// Flattened web tabs under a container, depth-first in sidebar order.
    mutating func tabs(under containerID: String) -> [PlannedTab] {
        var result: [PlannedTab] = []
        var visited: Set<String> = [containerID]
        walk(containerID, path: [], depth: 0, visited: &visited, into: &result)
        return result
    }

    private mutating func walk(_ id: String, path: [String], depth: Int, visited: inout Set<String>, into result: inout [PlannedTab]) {
        guard depth < Self.maxDepth else { hitDepthLimit = true; return }
        for childID in children(of: id) {
            guard visited.insert(childID).inserted, let item = items[childID] else {
                if items[childID] != nil { hitDepthLimit = true }
                continue
            }
            let data = item["data"] as? [String: Any] ?? [:]
            if let tab = data["tab"] as? [String: Any] {
                guard let url = ImportURL.web(tab["savedURL"]) else { skippedNonWeb += 1; continue }
                // `title` is the user's rename in Arc; `savedTitle` the page title.
                let title = ImportText.clean(item["title"]) ?? ImportText.clean(tab["savedTitle"]) ?? url.host() ?? url.absoluteString
                result.append(PlannedTab(title: title, url: url, folderPath: path))
            } else if data["list"] != nil {
                let name = ImportText.clean(item["title"]) ?? "Folder"
                walk(childID, path: path + [name], depth: depth + 1, visited: &visited, into: &result)
            } else if data["splitView"] != nil || data["itemContainer"] != nil {
                walk(childID, path: path, depth: depth + 1, visited: &visited, into: &result)
            } else {
                skippedOther += 1
            }
        }
    }
}
