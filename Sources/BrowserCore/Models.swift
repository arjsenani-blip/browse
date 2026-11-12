import Foundation

public struct TabID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
    public var description: String { raw.uuidString }
}

/// The three lifetimes a tab can have in the sidebar.
public enum TabTier: String, Codable, Sendable, CaseIterable {
    /// Grid tiles at the top of the sidebar; never auto-archived.
    case favorite
    /// Kept across days; never auto-archived.
    case pinned
    /// Today's tabs; archived after the space's archive interval.
    case today
}

public struct TabRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: TabID
    public var url: URL?
    public var title: String
    public var tier: TabTier
    public var created: Date
    public var lastActive: Date
    /// True when the tab has no live web view; it is restored from `interactionState`.
    public var isSleeping: Bool
    /// `WKWebView.interactionState` as archived data, kept while sleeping and across launches.
    public var interactionState: Data?
    /// Set by the web layer; hibernation never touches a tab while any of these hold.
    public var activity: TabActivity

    public init(
        id: TabID = TabID(),
        url: URL?,
        title: String = "",
        tier: TabTier = .today,
        created: Date = Date(),
        lastActive: Date = Date(),
        isSleeping: Bool = false,
        interactionState: Data? = nil,
        activity: TabActivity = []
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.tier = tier
        self.created = created
        self.lastActive = lastActive
        self.isSleeping = isSleeping
        self.interactionState = interactionState
        self.activity = activity
    }

    public var displayTitle: String {
        if !title.isEmpty { return title }
        return url?.host() ?? "New Tab"
    }
}

/// Live activity reported by the web layer. Any member exempts a tab from hibernation.
public struct TabActivity: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let playingMedia = TabActivity(rawValue: 1 << 0)
    public static let capturing = TabActivity(rawValue: 1 << 1)   // camera, mic or screen
    public static let unsavedForm = TabActivity(rawValue: 1 << 2)
    public static let downloading = TabActivity(rawValue: 1 << 3)
    public static let visibleInSplit = TabActivity(rawValue: 1 << 4)
}

/// A browsing identity: one persistent `WKWebsiteDataStore` (cookies, storage, cache).
public struct Profile: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

public struct Space: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    /// Hue 0…1 for the space's accent; drives selection fill and sidebar wash.
    public var accentHue: Double
    public var profileID: UUID
    /// Ordered tab IDs, per tier.
    public var favorites: [TabID]
    public var pinned: [TabID]
    public var today: [TabID]
    public var selected: TabID?
    /// Today tabs untouched this long are archived. Default 24 h; user-adjustable.
    public var archiveAfter: TimeInterval
    /// The space's gradient. nil (older sessions) derives one from `accentHue`.
    public var theme: SpaceTheme?
    public var resolvedTheme: SpaceTheme { theme ?? .from(hue: accentHue) }
    /// SF Symbol for the space's chip; nil picks one from `Space.icons` by position.
    public var icon: String?
    /// Arc-style folders inside Pinned. Optional so older sessions still decode.
    public var folderList: [Folder]?
    public var folders: [Folder] {
        get { folderList ?? [] }
        set { folderList = newValue.isEmpty ? nil : newValue }
    }

    /// The folder holding a pinned tab, if any.
    public func folder(containing id: TabID) -> Folder? { folders.first { $0.tabs.contains(id) } }
    /// Split views: tabs of this space shown side by side. Optional so older sessions still decode.
    public var splitList: [SplitGroup]?
    public var splits: [SplitGroup] {
        get { splitList ?? [] }
        set { splitList = newValue.isEmpty ? nil : newValue }
    }
    /// The split view a tab is part of, if any.
    public func split(containing id: TabID) -> SplitGroup? { splits.first { $0.tabs.contains(id) } }

    /// Drops a tab from its split; a split left with one tab dissolves.
    public mutating func removeFromSplits(_ id: TabID) {
        guard splits.contains(where: { $0.tabs.contains(id) }) else { return }
        splits = splits.compactMap { g in
            var g = g
            guard let i = g.tabs.firstIndex(of: id) else { return g }
            g.tabs.remove(at: i)
            if var f = g.fractions, f.count > i { f.remove(at: i); g.fractions = SplitGroup.normalized(f) }
            return g.tabs.count >= 2 ? g : nil
        }
    }
    public static let icons = ["house", "briefcase", "flask", "book.closed", "paintpalette", "gamecontroller",
                               "music.note", "airplane", "leaf", "graduationcap", "cart", "heart"]

    public init(
        id: UUID = UUID(),
        name: String,
        accentHue: Double,
        profileID: UUID,
        favorites: [TabID] = [],
        pinned: [TabID] = [],
        today: [TabID] = [],
        selected: TabID? = nil,
        archiveAfter: TimeInterval = 24 * 3600
    ) {
        self.id = id
        self.name = name
        self.accentHue = accentHue
        self.profileID = profileID
        self.favorites = favorites
        self.pinned = pinned
        self.today = today
        self.selected = selected
        self.archiveAfter = archiveAfter
    }

    public var allTabs: [TabID] { favorites + pinned + today }

    public mutating func remove(_ id: TabID) {
        favorites.removeAll { $0 == id }
        pinned.removeAll { $0 == id }
        today.removeAll { $0 == id }
        if folders.contains(where: { $0.tabs.contains(id) }) {
            folders = folders.map { var f = $0; f.tabs.removeAll { $0 == id }; return f }
        }
    }

    public mutating func insert(_ id: TabID, tier: TabTier, at index: Int? = nil) {
        remove(id)
        switch tier {
        case .favorite: favorites.insert(id, at: min(index ?? favorites.count, favorites.count))
        case .pinned: pinned.insert(id, at: min(index ?? pinned.count, pinned.count))
        case .today: today.insert(id, at: min(index ?? 0, today.count))
        }
    }
}

/// A tab moved out of a space by auto-archive or closing; searchable and restorable.
public struct ArchivedTab: Codable, Sendable, Identifiable, Equatable {
    public var id: TabID
    public var url: URL?
    public var title: String
    public var spaceID: UUID
    public var archived: Date
    public init(id: TabID, url: URL?, title: String, spaceID: UUID, archived: Date) {
        self.id = id
        self.url = url
        self.title = title
        self.spaceID = spaceID
        self.archived = archived
    }
}

/// Two to four tabs of one space shown side by side (or stacked) in one window.
public struct SplitGroup: Codable, Sendable, Identifiable, Equatable {
    public static let maxPanes = 4
    public var id: UUID
    /// Left to right (top to bottom when `vertical`).
    public var tabs: [TabID]
    public var vertical: Bool
    /// Pane sizes, summing to 1; nil means equal.
    public var fractions: [Double]?

    public init(id: UUID = UUID(), tabs: [TabID], vertical: Bool = false, fractions: [Double]? = nil) {
        self.id = id; self.tabs = tabs; self.vertical = vertical; self.fractions = fractions
    }

    /// Sizes for display: the stored ones if they fit the pane count, else equal.
    public var sizes: [Double] {
        if let f = fractions, f.count == tabs.count { return f }
        return Array(repeating: 1 / Double(max(tabs.count, 1)), count: tabs.count)
    }

    /// Scales to sum 1, with every pane at least 15%.
    public static func normalized(_ f: [Double]) -> [Double]? {
        guard !f.isEmpty else { return nil }
        let clamped = f.map { max($0, 0.15) }
        let sum = clamped.reduce(0, +)
        return clamped.map { $0 / sum }
    }
}

/// A folder in a space's Pinned section. Its tabs are pinned tabs.
///
/// Folders can nest: `parentID` names the containing folder (nil = top level).
/// `position` is the folder's slot among its siblings: for a top-level folder,
/// among the loose pinned tabs and other top-level folders; for a subfolder,
/// among its parent's tabs and subfolders. (The sidebar currently renders one
/// level; nesting support in the model is ready for the UI. See docs/subfolders.md.)
public struct Folder: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    /// SF Symbol; nil shows the folder glyph.
    public var icon: String?
    public var isExpanded: Bool
    public var tabs: [TabID]
    public var position: Int
    /// Containing folder; nil at the top level. Optional so older sessions decode.
    public var parentID: UUID?

    public init(id: UUID = UUID(), name: String = "Untitled", icon: String? = nil, isExpanded: Bool = true,
                tabs: [TabID] = [], position: Int = 0, parentID: UUID? = nil) {
        self.id = id; self.name = name; self.icon = icon; self.isExpanded = isExpanded
        self.tabs = tabs; self.position = position; self.parentID = parentID
    }
}

/// A top-level entry in Pinned, in display order.
public enum PinnedEntry: Equatable, Sendable {
    case tab(TabID)
    case folder(Folder)
}

public extension Space {
    /// Deepest nesting allowed: a top-level folder is depth 0, so this permits
    /// folders four levels deep (matches the research recommendation).
    static let maxFolderDepth = 4

    /// Top-level Pinned: loose pinned tabs and top-level folders, interleaved by folder position.
    var pinnedEntries: [PinnedEntry] {
        let inFolders = Set(folders.flatMap(\.tabs))
        return interleave(tabs: pinned.filter { !inFolders.contains($0) }, folders: subfolders(of: nil))
    }

    /// A folder's contents: its tabs and direct subfolders, interleaved by subfolder position.
    func entries(in folderID: UUID) -> [PinnedEntry] {
        guard let folder = folders.first(where: { $0.id == folderID }) else { return [] }
        return interleave(tabs: folder.tabs, folders: subfolders(of: folderID))
    }

    /// Direct children of a folder (nil = top level), in position order.
    func subfolders(of parent: UUID?) -> [Folder] {
        folders.filter { $0.parentID == parent }.sorted { $0.position < $1.position }
    }

    /// 0 for a top-level folder, 1 for its subfolders, and so on.
    func depth(of folderID: UUID) -> Int { ancestors(of: folderID).count }

    /// Containing folders, nearest first. Stops on a broken or cyclic chain.
    func ancestors(of folderID: UUID) -> [UUID] {
        var chain: [UUID] = []
        var current = folders.first { $0.id == folderID }?.parentID
        while let id = current, !chain.contains(id), chain.count <= folders.count {
            chain.append(id)
            current = folders.first { $0.id == id }?.parentID
        }
        return chain
    }

    /// Every folder nested anywhere under this one.
    func descendants(of folderID: UUID) -> [UUID] {
        var result: [UUID] = []
        var queue = subfolders(of: folderID).map(\.id)
        while let id = queue.first {
            queue.removeFirst()
            guard !result.contains(id) else { continue }
            result.append(id)
            queue += subfolders(of: id).map(\.id)
        }
        return result
    }

    /// Levels below this folder (0 if it has no subfolders).
    func subtreeHeight(of folderID: UUID) -> Int {
        let kids = subfolders(of: folderID)
        return kids.isEmpty ? 0 : 1 + (kids.map { subtreeHeight(of: $0.id) }.max() ?? 0)
    }

    /// Every tab in a folder and all of its subfolders.
    func allTabs(inFolder folderID: UUID) -> [TabID] {
        ([folderID] + descendants(of: folderID)).flatMap { id in folders.first { $0.id == id }?.tabs ?? [] }
    }

    private func interleave(tabs: [TabID], folders: [Folder]) -> [PinnedEntry] {
        var entries: [PinnedEntry] = tabs.map { .tab($0) }
        for f in folders { entries.insert(.folder(f), at: min(max(0, f.position), entries.count)) }
        return entries
    }
}
