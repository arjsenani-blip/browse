import Foundation
import Observation

/// The single source of truth for spaces and tabs. The sidebar applies diffs
/// from it; the web layer reports activity into it.
@MainActor
@Observable
public final class BrowserStore {
    public private(set) var profiles: [Profile]
    public private(set) var spaces: [Space]
    public private(set) var tabs: [TabID: TabRecord]
    public private(set) var archive: [ArchivedTab]
    public var currentSpaceID: UUID
    /// Spaces that must never persist or leak (private windows).
    public var ephemeralSpaces: Set<UUID> = []
    /// Recently closed, newest last, for ⇧⌘T.
    public private(set) var closed: [TabRecord] = []

    public init(snapshot: SessionSnapshot? = nil) {
        if let s = snapshot, !s.spaces.isEmpty {
            profiles = s.profiles
            spaces = s.spaces
            tabs = Dictionary(uniqueKeysWithValues: s.tabs.map { ($0.id, $0) })
            archive = s.archive
            currentSpaceID = s.spaces.contains { $0.id == s.currentSpaceID } ? s.currentSpaceID : s.spaces[0].id
            // Every restored tab starts asleep; it wakes on selection.
            for id in tabs.keys { tabs[id]?.isSleeping = true; tabs[id]?.activity = [] }
        } else {
            let personal = Profile(name: "Personal")
            let space = Space(name: "Personal", accentHue: 0.48, profileID: personal.id)
            profiles = [personal]
            spaces = [space]
            tabs = [:]
            archive = []
            currentSpaceID = space.id
        }
    }

    // MARK: Queries

    public var currentSpace: Space { spaces.first { $0.id == currentSpaceID } ?? spaces[0] }
    public var selectedTab: TabRecord? { currentSpace.selected.flatMap { tabs[$0] } }

    public func profile(for space: Space) -> Profile {
        profiles.first { $0.id == space.profileID } ?? profiles[0]
    }

    public func space(containing id: TabID) -> Space? {
        spaces.first { $0.allTabs.contains(id) }
    }

    // MARK: Tabs

    @discardableResult
    public func openTab(_ url: URL?, tier: TabTier = .today, select: Bool = true, in spaceID: UUID? = nil) -> TabID {
        let tab = TabRecord(url: url, tier: tier)
        tabs[tab.id] = tab
        mutateSpace(spaceID ?? currentSpaceID) { space in
            space.insert(tab.id, tier: tier)
            if select { space.selected = tab.id }
        }
        return tab.id
    }

    public func select(_ id: TabID) {
        guard let owner = space(containing: id) else { return }
        currentSpaceID = owner.id
        mutateSpace(owner.id) { $0.selected = id }
        tabs[id]?.lastActive = Date()
    }

    public func close(_ id: TabID) {
        guard let owner = space(containing: id), let tab = tabs[id] else { return }
        let ordered = owner.allTabs
        let index = ordered.firstIndex(of: id) ?? 0
        mutateSpace(owner.id) { space in
            space.remove(id)
            if space.selected == id {
                let rest = space.allTabs
                space.selected = rest.isEmpty ? nil : rest[min(index, rest.count - 1)]
            }
        }
        tabs[id] = nil
        // Private tabs are never reopenable (⇧⌘T would carry them into a normal space).
        if !ephemeralSpaces.contains(owner.id) {
            closed.append(tab)
            if closed.count > 50 { closed.removeFirst() }
        }
    }

    @discardableResult
    public func reopenClosed() -> TabID? {
        guard var tab = closed.popLast() else { return nil }
        tab.isSleeping = true
        tab.lastActive = Date()
        tabs[tab.id] = tab
        mutateSpace(currentSpaceID) { space in
            space.insert(tab.id, tier: tab.tier)
            space.selected = tab.id
        }
        return tab.id
    }

    public func move(_ id: TabID, to tier: TabTier, at index: Int? = nil) {
        guard let owner = space(containing: id) else { return }
        tabs[id]?.tier = tier
        mutateSpace(owner.id) { $0.insert(id, tier: tier, at: index) }
    }

    public func update(_ id: TabID, _ change: (inout TabRecord) -> Void) {
        guard var tab = tabs[id] else { return }
        change(&tab)
        if tab != tabs[id] { tabs[id] = tab }
    }

    // MARK: Spaces

    @discardableResult
    public func addSpace(name: String, accentHue: Double, newProfile: Bool) -> Space {
        var profileID = currentSpace.profileID
        if newProfile {
            let profile = Profile(name: name)
            profiles.append(profile)
            profileID = profile.id
        }
        let space = Space(name: name, accentHue: accentHue, profileID: profileID)
        spaces.append(space)
        return space
    }

    public func renameSpace(_ id: UUID, name: String, accentHue: Double? = nil) {
        mutateSpace(id) { space in
            space.name = name
            if let accentHue { space.accentHue = accentHue }
        }
    }

    /// Removes a space and its tabs. The last space can't be removed.
    @discardableResult
    public func removeSpace(_ id: UUID) -> [TabID] {
        guard spaces.count > 1, let i = spaces.firstIndex(where: { $0.id == id }) else { return [] }
        let removed = spaces[i].allTabs
        for t in removed { tabs[t] = nil }
        let profile = spaces[i].profileID
        ephemeralSpaces.remove(id)
        spaces.remove(at: i)
        if !spaces.contains(where: { $0.profileID == profile }) { profiles.removeAll { $0.id == profile } }
        if currentSpaceID == id { currentSpaceID = spaces[max(0, i - 1)].id }
        return removed
    }

    public func setIcon(_ icon: String?, for id: UUID) {
        mutateSpace(id) { $0.icon = icon }
    }

    /// Archives every today tab in a space (the sidebar's "Clear"), keeping the selected one.
    @discardableResult
    public func clearToday(in spaceID: UUID, keepSelected: Bool = true) -> [TabID] {
        guard let space = spaces.first(where: { $0.id == spaceID }) else { return [] }
        let victims = space.today.filter { !(keepSelected && $0 == space.selected) }
        let now = Date()
        for id in victims {
            guard let tab = tabs[id] else { continue }
            if !ephemeralSpaces.contains(spaceID) {
                archive.append(ArchivedTab(id: id, url: tab.url, title: tab.displayTitle, spaceID: spaceID, archived: now))
            }
            mutateSpace(spaceID) { $0.remove(id) }
            tabs[id] = nil
        }
        return victims
    }

    public func setTheme(_ theme: SpaceTheme, for id: UUID) {
        mutateSpace(id) { space in
            space.theme = theme
            space.accentHue = theme.top.mixed(with: theme.bottom, 0.5).hue
        }
    }

    /// Reorders spaces (Settings → Spaces drag).
    public func moveSpace(from: Int, to: Int) {
        guard spaces.indices.contains(from), to >= 0, to <= spaces.count else { return }
        let s = spaces.remove(at: from)
        spaces.insert(s, at: min(to, spaces.count))
    }

    public func setArchiveInterval(_ seconds: TimeInterval) {
        for i in spaces.indices { spaces[i].archiveAfter = seconds }
    }

    public func switchSpace(by delta: Int) {
        guard let i = spaces.firstIndex(where: { $0.id == currentSpaceID }) else { return }
        currentSpaceID = spaces[(i + delta + spaces.count) % spaces.count].id
    }

    // MARK: Lifecycle

    /// Applies the archive policy across all spaces. Returns archived IDs.
    @discardableResult
    public func runArchive(now: Date = Date()) -> [TabID] {
        var archivedIDs: [TabID] = []
        for space in spaces {
            for id in ArchivePolicy.tabsToArchive(in: space, tabs: tabs, now: now) {
                guard let tab = tabs[id] else { continue }
                archive.append(ArchivedTab(id: id, url: tab.url, title: tab.displayTitle, spaceID: space.id, archived: now))
                mutateSpace(space.id) { $0.remove(id) }
                tabs[id] = nil
                archivedIDs.append(id)
            }
        }
        if archive.count > 2000 { archive.removeFirst(archive.count - 2000) }
        return archivedIDs
    }

    public func snapshot() -> SessionSnapshot {
        let keptSpaces = spaces.filter { !ephemeralSpaces.contains($0.id) }
        let keptTabIDs = Set(keptSpaces.flatMap(\.allTabs))
        let keptProfiles = Set(keptSpaces.map(\.profileID))
        var saved = tabs.values.filter { keptTabIDs.contains($0.id) }
        for i in saved.indices { saved[i].activity = [] }
        let current = keptSpaces.contains { $0.id == currentSpaceID } ? currentSpaceID : (keptSpaces.first?.id ?? currentSpaceID)
        return SessionSnapshot(profiles: profiles.filter { keptProfiles.contains($0.id) }, spaces: keptSpaces, tabs: saved,
                               archive: archive.filter { !ephemeralSpaces.contains($0.spaceID) }, currentSpaceID: current)
    }

    private func mutateSpace(_ id: UUID, _ change: (inout Space) -> Void) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        change(&spaces[i])
    }
}
