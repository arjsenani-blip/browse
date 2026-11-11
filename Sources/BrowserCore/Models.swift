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

/// A folder in a space's Pinned section (one level, like most Arc use). Its
/// tabs are pinned tabs; `position` is where the folder sits among the
/// top-level pinned items (loose tabs and folders).
public struct Folder: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    /// SF Symbol; nil shows the folder glyph.
    public var icon: String?
    public var isExpanded: Bool
    public var tabs: [TabID]
    public var position: Int

    public init(id: UUID = UUID(), name: String = "Untitled", icon: String? = nil, isExpanded: Bool = true, tabs: [TabID] = [], position: Int = 0) {
        self.id = id; self.name = name; self.icon = icon; self.isExpanded = isExpanded; self.tabs = tabs; self.position = position
    }
}

/// A top-level entry in Pinned, in display order.
public enum PinnedEntry: Equatable, Sendable {
    case tab(TabID)
    case folder(Folder)
}

public extension Space {
    /// Loose pinned tabs and folders interleaved by folder position.
    var pinnedEntries: [PinnedEntry] {
        let inFolders = Set(folders.flatMap(\.tabs))
        var entries: [PinnedEntry] = pinned.filter { !inFolders.contains($0) }.map { .tab($0) }
        for f in folders.sorted(by: { $0.position < $1.position }) {
            entries.insert(.folder(f), at: min(max(0, f.position), entries.count))
        }
        return entries
    }
}
