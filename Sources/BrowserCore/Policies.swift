import Foundation

/// System memory pressure, as delivered by `DispatchSource.makeMemoryPressureSource`.
public enum MemoryPressure: Int, Sendable, Comparable {
    case normal, warning, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Decides which tabs to put to sleep. Pure: the web layer executes the result.
public struct HibernationPolicy: Sendable, Equatable {
    /// Idle time before a background tab sleeps under normal pressure.
    public var idleTimeout: TimeInterval
    /// Idle time under a pressure warning.
    public var pressuredTimeout: TimeInterval
    /// Never keep more than this many live background tabs.
    public var maxLiveBackgroundTabs: Int
    /// Hosts the user has excluded.
    public var neverSleepHosts: Set<String>

    public static let balanced = HibernationPolicy(idleTimeout: 30 * 60, pressuredTimeout: 5 * 60, maxLiveBackgroundTabs: 12, neverSleepHosts: [])

    public init(idleTimeout: TimeInterval, pressuredTimeout: TimeInterval, maxLiveBackgroundTabs: Int, neverSleepHosts: Set<String>) {
        self.idleTimeout = idleTimeout
        self.pressuredTimeout = pressuredTimeout
        self.maxLiveBackgroundTabs = maxLiveBackgroundTabs
        self.neverSleepHosts = neverSleepHosts
    }

    /// Returns the tabs to hibernate, least recently used first.
    /// - Parameters:
    ///   - tabs: every tab in every window.
    ///   - foreground: tabs currently on screen (selected in a window); never slept.
    public func tabsToSleep(_ tabs: [TabRecord], foreground: Set<TabID>, pressure: MemoryPressure, now: Date) -> [TabID] {
        let candidates = tabs
            .filter { !$0.isSleeping && !foreground.contains($0.id) }
            .filter { tab in
                if !tab.activity.isEmpty { return false }
                if let host = tab.url?.host(), neverSleepHosts.contains(host) { return false }
                // Pinned and favorite tabs stay live unless memory is critical.
                if tab.tier != .today && pressure < .critical { return false }
                return true
            }
            .sorted { $0.lastActive < $1.lastActive }

        if pressure == .critical { return candidates.map(\.id) }

        let timeout = pressure == .warning ? pressuredTimeout : idleTimeout
        var result = candidates.filter { now.timeIntervalSince($0.lastActive) >= timeout }.map(\.id)

        // Cap the live count: sleep the oldest of what's left over the limit.
        let live = tabs.filter { !$0.isSleeping && !foreground.contains($0.id) }.count - result.count
        if live > maxLiveBackgroundTabs {
            let chosen = Set(result)
            let extra = candidates.filter { !chosen.contains($0.id) }.prefix(live - maxLiveBackgroundTabs)
            result += extra.map(\.id)
        }
        return result
    }
}

/// Today tabs untouched for the space's interval move to the archive.
public enum ArchivePolicy {
    public static func tabsToArchive(in space: Space, tabs: [TabID: TabRecord], now: Date) -> [TabID] {
        space.today.filter { id in
            guard id != space.selected, let tab = tabs[id] else { return false }
            guard tab.activity.isEmpty else { return false }
            return now.timeIntervalSince(tab.lastActive) >= space.archiveAfter
        }
    }
}
