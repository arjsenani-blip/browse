import Foundation

/// How bookmark imports (Chrome-family, Safari) map onto spaces.
///
/// Bookmarks are a reference library, not a tab strip, so they all land in one
/// new space, "Imported Bookmarks":
/// - The first `favoritesLimit` (8) bookmarks sitting *directly* on the bookmark
///   bar become favorites (the grid tiles mirror the bar's most-used role).
/// - Everything else, in source order (bar → folders → other → mobile), becomes
///   pinned tabs, capped at `pinnedLimit` (200) after URL dedup. The overflow is
///   counted in `ImportSummary.overCapSkipped` and reported as a warning; the
///   full list remains available in `ImportPlan.bookmarks` for a future
///   bookmarks store.
public enum ImportPolicy {
    public static let bookmarksSpaceName = "Imported Bookmarks"
    public static let favoritesLimit = 8
    public static let pinnedLimit = 200
    public static let bookmarksSpaceHue = 0.09
}

public struct SpaceRename: Sendable, Equatable {
    public var spaceID: UUID
    public var name: String
    public var accentHue: Double
}

public struct ImportSummary: Sendable, Equatable {
    /// Spaces the import created, in plan order (excludes a reused space).
    public var createdSpaceIDs: [UUID] = []
    /// The empty default space that received the first planned space's tabs.
    public var reusedSpaceID: UUID?
    /// `BrowserStore` has no rename API yet, so the reused space keeps its old
    /// name/hue; the caller should apply these once one exists.
    public var pendingRenames: [SpaceRename] = []
    public var favoritesAdded = 0
    public var pinnedAdded = 0
    public var todayAdded = 0
    /// Tabs skipped because the same URL was already in that space.
    public var duplicatesSkipped = 0
    /// Bookmarks beyond `ImportPolicy.pinnedLimit`.
    public var overCapSkipped = 0
    public var warnings: [String] = []

    public var tabsAdded: Int { favoritesAdded + pinnedAdded + todayAdded }
    /// Every space that received imported tabs (reused first, then created).
    public var touchedSpaceIDs: [UUID] { (reusedSpaceID.map { [$0] } ?? []) + createdSpaceIDs }
}

extension ImportPlan {
    /// The "Imported Bookmarks" space for this plan's bookmarks, uncapped; nil when there are none.
    func bookmarksSpace() -> PlannedSpace? {
        guard !bookmarks.isEmpty else { return nil }
        var favorites: [PlannedTab] = []
        var favoriteKeys: Set<String> = []
        var pinned: [PlannedTab] = []
        for b in bookmarks {
            let tab = PlannedTab(title: b.title, url: b.url, folderPath: b.folderPath)
            if b.isTopLevelOfBar, favorites.count < ImportPolicy.favoritesLimit,
               favoriteKeys.insert(ImportURL.dedupeKey(b.url)).inserted {
                favorites.append(tab)
            } else {
                pinned.append(tab)
            }
        }
        return PlannedSpace(name: ImportPolicy.bookmarksSpaceName, hue: ImportPolicy.bookmarksSpaceHue, favorites: favorites, pinned: pinned)
    }
}

@MainActor
extension BrowserStore {
    /// Creates spaces and sleeping tabs from a plan. No web views are created:
    /// every tab is a record with `isSleeping = true` and wakes on selection.
    ///
    /// - The first planned space reuses the current space when it is the store's
    ///   only space and has no tabs (a fresh install); see `pendingRenames`.
    /// - Tabs are deduped by URL within each space (across tiers, and against
    ///   tabs already there); favorites win over pinned over today.
    /// - Bookmarks go into one "Imported Bookmarks" space per `ImportPolicy`.
    /// - `newProfilesPerSpace`: each created space gets its own profile (separate
    ///   cookies/storage, like Arc profiles); otherwise new spaces share the
    ///   current space's profile.
    @discardableResult
    public func apply(_ plan: ImportPlan, newProfilesPerSpace: Bool) -> ImportSummary {
        var summary = ImportSummary()
        summary.warnings = plan.warnings

        var planned = plan.spaces.map { (space: $0, pinnedCap: Int?.none) }
        if let bookmarks = plan.bookmarksSpace() {
            planned.append((bookmarks, ImportPolicy.pinnedLimit))
        }
        guard !planned.isEmpty else { return summary }

        let originalSpaceID = currentSpaceID
        var reusable: UUID? = (spaces.count == 1 && currentSpace.allTabs.isEmpty) ? currentSpace.id : nil

        for (space, pinnedCap) in planned {
            let targetID: UUID
            if let reuse = reusable {
                reusable = nil
                targetID = reuse
                summary.reusedSpaceID = reuse
                if let existing = spaces.first(where: { $0.id == reuse }),
                   existing.name != space.name || existing.accentHue != space.hue {
                    summary.pendingRenames.append(SpaceRename(spaceID: reuse, name: space.name, accentHue: space.hue))
                }
            } else {
                // addSpace derives a shared profile from the current space.
                currentSpaceID = originalSpaceID
                targetID = addSpace(name: space.name, accentHue: space.hue, newProfile: newProfilesPerSpace).id
                summary.createdSpaceIDs.append(targetID)
            }

            var seen = Set((spaces.first { $0.id == targetID }?.allTabs ?? []).compactMap { tabs[$0]?.url.map(ImportURL.dedupeKey) })
            func fresh(_ list: [PlannedTab], cap: Int? = nil) -> [PlannedTab] {
                var kept: [PlannedTab] = []
                for tab in list {
                    guard seen.insert(ImportURL.dedupeKey(tab.url)).inserted else { summary.duplicatesSkipped += 1; continue }
                    if let cap, kept.count >= cap { summary.overCapSkipped += 1; continue }
                    kept.append(tab)
                }
                return kept
            }

            let favorites = fresh(space.favorites)
            let pinned = fresh(space.pinned, cap: pinnedCap)
            let today = fresh(space.today)
            for tab in favorites { addSleepingTab(tab, tier: .favorite, in: targetID) }
            for tab in pinned { addSleepingTab(tab, tier: .pinned, in: targetID) }
            // `.today` inserts at the top, so add in reverse to keep source order.
            for tab in today.reversed() { addSleepingTab(tab, tier: .today, in: targetID) }
            summary.favoritesAdded += favorites.count
            summary.pinnedAdded += pinned.count
            summary.todayAdded += today.count
        }

        currentSpaceID = originalSpaceID
        if summary.overCapSkipped > 0 {
            summary.warnings.append("Imported the first \(ImportPolicy.pinnedLimit) bookmarks as pinned tabs; \(summary.overCapSkipped) more were not added.")
        }
        return summary
    }

    private func addSleepingTab(_ tab: PlannedTab, tier: TabTier, in spaceID: UUID) {
        let id = openTab(tab.url, tier: tier, select: false, in: spaceID)
        update(id) { record in
            record.isSleeping = true
            record.title = tab.title
        }
    }
}
