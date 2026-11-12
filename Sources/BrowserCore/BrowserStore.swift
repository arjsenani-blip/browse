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
            // A damaged or hand-edited session must never crash launch:
            // duplicate tab ids trapped Dictionary(uniqueKeysWithValues:), and
            // a space whose profile is missing (or no profiles) trapped profiles[0].
            var profiles = s.profiles
            for id in Set(s.spaces.map(\.profileID)) where !profiles.contains(where: { $0.id == id }) {
                profiles.append(Profile(id: id, name: "Personal"))
            }
            self.profiles = profiles
            spaces = s.spaces
            tabs = Dictionary(s.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
            space.removeFromSplits(id)
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
        var space = Space(name: name, accentHue: accentHue, profileID: profileID)
        // Settings' "archive after" is one app-wide choice; new spaces follow it.
        if let interval = spaces.first?.archiveAfter { space.archiveAfter = interval }
        spaces.append(space)
        return space
    }

    public func renameSpace(_ id: UUID, name: String, accentHue: Double? = nil) {
        mutateSpace(id) { space in
            space.name = name
            if let accentHue { space.accentHue = accentHue }
        }
    }

    /// Removes a space and its tabs. The last space can't be removed, and
    /// neither can the last normal one (private spaces don't count: they
    /// vanish with their window and would leave normal windows nothing to show).
    @discardableResult
    public func removeSpace(_ id: UUID) -> [TabID] {
        guard spaces.count > 1, let i = spaces.firstIndex(where: { $0.id == id }) else { return [] }
        let wasEphemeral = ephemeralSpaces.contains(id)
        if !wasEphemeral, !spaces.contains(where: { $0.id != id && !ephemeralSpaces.contains($0.id) }) { return [] }
        let removed = spaces[i].allTabs
        for t in removed { tabs[t] = nil }
        let profile = spaces[i].profileID
        ephemeralSpaces.remove(id)
        spaces.remove(at: i)
        if !spaces.contains(where: { $0.profileID == profile }) { profiles.removeAll { $0.id == profile } }
        if currentSpaceID == id {
            // The neighbour, but never a private window's space for a normal one.
            let candidates = spaces.indices.filter { wasEphemeral || !ephemeralSpaces.contains(spaces[$0].id) }
            let next = candidates.last { $0 < i } ?? candidates.first ?? max(0, i - 1)
            currentSpaceID = spaces[next].id
        }
        return removed
    }

    // MARK: Folders

    /// Creates an empty folder at the top of Pinned and returns its id.
    @discardableResult
    public func newFolder(in spaceID: UUID, name: String = "Untitled") -> UUID {
        let folder = Folder(name: name, position: 0)
        mutateSpace(spaceID) { space in
            // Shift top-level siblings only; nested folders keep their own order.
            space.folders = space.folders.map { var f = $0; if f.parentID == nil { f.position += 1 }; return f } + [folder]
        }
        return folder.id
    }

    /// Creates an empty subfolder at the top of `parent`. Returns nil if the
    /// parent doesn't exist or the new folder would exceed `Space.maxFolderDepth`.
    @discardableResult
    public func newSubfolder(in parent: UUID, name: String = "Untitled") -> UUID? {
        guard let space = spaces.first(where: { $0.folders.contains { $0.id == parent } }),
              space.depth(of: parent) + 1 < Space.maxFolderDepth else { return nil }
        let folder = Folder(name: name, position: 0, parentID: parent)
        mutateSpace(space.id) { sp in
            sp.folders = sp.folders.map { var f = $0; if f.parentID == parent { f.position += 1 }; return f } + [folder]
            if let pi = sp.folders.firstIndex(where: { $0.id == parent }) { sp.folders[pi].isExpanded = true }
        }
        return folder.id
    }

    /// Moves a folder (with everything inside it) under another folder, or to
    /// the top level with `toParent: nil`, at `position` among its new siblings.
    /// Refuses moves across spaces, into itself or its own subtree, and moves
    /// that would nest deeper than `Space.maxFolderDepth`. Returns success.
    @discardableResult
    public func moveFolder(_ id: UUID, toParent parent: UUID?, at position: Int? = nil) -> Bool {
        guard let space = spaces.first(where: { $0.folders.contains { $0.id == id } }),
              let folder = space.folders.first(where: { $0.id == id }) else { return false }
        if let parent {
            guard space.folders.contains(where: { $0.id == parent }),
                  parent != id, !space.descendants(of: id).contains(parent),
                  space.depth(of: parent) + 1 + space.subtreeHeight(of: id) < Space.maxFolderDepth else { return false }
        }
        let oldParent = folder.parentID, oldPosition = folder.position
        mutateSpace(space.id) { sp in
            // Close the gap in the old sibling scope…
            sp.folders = sp.folders.map { var f = $0
                if f.id != id, f.parentID == oldParent, f.position > oldPosition { f.position -= 1 }
                return f }
            // …then open a slot in the new one.
            let siblings = sp.folders.filter { $0.parentID == parent && $0.id != id }
            // Slots count the scope's tabs too: loose pinned tabs at the top level, the parent's tabs inside a folder.
            let tabCount = parent.map { p in sp.folders.first { $0.id == p }?.tabs.count ?? 0 } ?? sp.pinned.count
            let slot = min(max(0, position ?? siblings.count), siblings.count + tabCount)
            sp.folders = sp.folders.map { var f = $0
                if f.id != id, f.parentID == parent, f.position >= slot { f.position += 1 }
                return f }
            if let fi = sp.folders.firstIndex(where: { $0.id == id }) {
                sp.folders[fi].parentID = parent
                sp.folders[fi].position = slot
            }
            if let parent, let pi = sp.folders.firstIndex(where: { $0.id == parent }) { sp.folders[pi].isExpanded = true }
        }
        return true
    }

    public func updateFolder(_ id: UUID, _ change: (inout Folder) -> Void) {
        guard let si = spaces.firstIndex(where: { $0.folders.contains { $0.id == id } }),
              let fi = spaces[si].folders.firstIndex(where: { $0.id == id }) else { return }
        var f = spaces[si].folders[fi]
        change(&f)
        spaces[si].folders[fi] = f
    }

    /// Moves a tab into a folder (pinning it if needed).
    public func moveTab(_ tabID: TabID, toFolder folderID: UUID, at index: Int? = nil) {
        guard let space = spaces.first(where: { $0.folders.contains { $0.id == folderID } }) else { return }
        // A live tab can't change cookie jars: crossing profiles (or into or out
        // of a private space) must go through a fresh reopen, never a move.
        if let owner = self.space(containing: tabID), owner.id != space.id,
           owner.profileID != space.profileID || ephemeralSpaces.contains(owner.id) != ephemeralSpaces.contains(space.id) { return }
        if store_space(containing: tabID) != space.id || tabs[tabID]?.tier != .pinned {
            // Bring it into this space's pinned list first.
            mutateSpace(space.id) { $0.insert(tabID, tier: .pinned) }
            if let owner = spaces.first(where: { $0.id != space.id && $0.allTabs.contains(tabID) }) {
                mutateSpace(owner.id) { $0.remove(tabID) }
            }
            tabs[tabID]?.tier = .pinned
        }
        mutateSpace(space.id) { sp in
            sp.folders = sp.folders.map { var f = $0; f.tabs.removeAll { $0 == tabID }; return f }
            if !sp.pinned.contains(tabID) { sp.pinned.append(tabID) }
            if let fi = sp.folders.firstIndex(where: { $0.id == folderID }) {
                let i = min(index ?? sp.folders[fi].tabs.count, sp.folders[fi].tabs.count)
                sp.folders[fi].tabs.insert(tabID, at: i)
                sp.folders[fi].isExpanded = true
            }
        }
    }

    /// Takes a tab out of its folder; it stays a loose pinned tab.
    public func removeFromFolder(_ tabID: TabID) {
        guard let space = space(containing: tabID) else { return }
        mutateSpace(space.id) { sp in sp.folders = sp.folders.map { var f = $0; f.tabs.removeAll { $0 == tabID }; return f } }
    }

    /// Deletes a folder.
    /// - `closeTabs: false`: its tabs and subfolders move up one level into its
    ///   parent (loose pinned tabs at the top level), keeping their order.
    /// - `closeTabs: true`: the folder, all subfolders and every tab inside are removed.
    /// Returns the tabs that were closed.
    @discardableResult
    public func deleteFolder(_ id: UUID, closeTabs: Bool) -> [TabID] {
        guard let space = spaces.first(where: { $0.folders.contains { $0.id == id } }),
              let folder = space.folders.first(where: { $0.id == id }) else { return [] }
        let parent = folder.parentID
        if closeTabs {
            let subtree = Set([id] + space.descendants(of: id))
            let doomed = space.allTabs(inFolder: id)
            mutateSpace(space.id) { sp in
                sp.folders.removeAll { subtree.contains($0.id) }
                sp.folders = sp.folders.map { var f = $0
                    if f.parentID == parent, f.position > folder.position { f.position -= 1 }
                    return f }
            }
            for t in doomed { close(t) }
            return doomed
        }
        let children = space.subfolders(of: id)
        mutateSpace(space.id) { sp in
            sp.folders.removeAll { $0.id == id }
            // Resize the folder's slot in the parent's scope to fit its subfolders (closing it if there are none),
            // then hoist them into it.
            sp.folders = sp.folders.map { var f = $0
                if f.parentID == parent, f.position > folder.position { f.position += children.count - 1 }
                return f }
            for (offset, child) in children.enumerated() {
                if let ci = sp.folders.firstIndex(where: { $0.id == child.id }) {
                    sp.folders[ci].parentID = parent
                    sp.folders[ci].position = folder.position + offset
                }
            }
            // Tabs of a nested folder move into its parent; at the top level they become loose.
            if let parent, let pi = sp.folders.firstIndex(where: { $0.id == parent }) {
                sp.folders[pi].tabs += folder.tabs.filter { !sp.folders[pi].tabs.contains($0) }
            }
        }
        return []
    }

    private func store_space(containing id: TabID) -> UUID? { space(containing: id)?.id }

    // MARK: Split view

    /// Shows `other` beside `id` (after it, or at `index` in the split). Joins `id`'s split if it has
    /// one. Both must be in the same space; refuses a fifth pane. Returns the split's ID.
    @discardableResult
    public func split(_ id: TabID, with other: TabID, at index: Int? = nil) -> UUID? {
        guard id != other, let owner = space(containing: id), space(containing: other)?.id == owner.id else { return nil }
        var result: UUID?
        mutateSpace(owner.id) { space in
            space.removeFromSplits(other)
            if let i = space.splits.firstIndex(where: { $0.tabs.contains(id) }) {
                guard space.splits[i].tabs.count < SplitGroup.maxPanes else { return }
                let at = index ?? (space.splits[i].tabs.firstIndex(of: id)! + 1)
                space.splits[i].tabs.insert(other, at: min(max(at, 0), space.splits[i].tabs.count))
                space.splits[i].fractions = nil
                result = space.splits[i].id
            } else {
                let tabs = index == 0 ? [other, id] : [id, other]
                let group = SplitGroup(tabs: tabs)
                space.splits.append(group)
                result = group.id
            }
        }
        return result
    }

    /// Takes one tab out of its split (the rest stay split if two or more remain).
    public func removeFromSplit(_ id: TabID) {
        guard let owner = space(containing: id) else { return }
        mutateSpace(owner.id) { $0.removeFromSplits(id) }
    }

    /// Dissolves a split; its tabs stay where they are in the sidebar.
    public func separate(_ splitID: UUID) {
        guard let owner = spaces.first(where: { $0.splits.contains { $0.id == splitID } }) else { return }
        mutateSpace(owner.id) { $0.splits.removeAll { $0.id == splitID } }
    }

    public func updateSplit(_ splitID: UUID, _ change: (inout SplitGroup) -> Void) {
        guard let owner = spaces.first(where: { $0.splits.contains { $0.id == splitID } }) else { return }
        mutateSpace(owner.id) { space in
            guard let i = space.splits.firstIndex(where: { $0.id == splitID }) else { return }
            change(&space.splits[i])
        }
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
            mutateSpace(spaceID) { $0.remove(id); $0.removeFromSplits(id) }
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
                mutateSpace(space.id) { $0.remove(id); $0.removeFromSplits(id) }
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
