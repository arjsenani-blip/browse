import Foundation
import Testing
@testable import BrowserCore

@Suite struct URLInputTests {
    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("https://a.b/c?d=1", "https://a.b/c?d=1"),
        ("localhost:3000", "https://localhost:3000"),
        ("10.0.0.1/admin", "https://10.0.0.1/admin"),
        ("sub.domain.co.uk/path", "https://sub.domain.co.uk/path"),
    ])
    func resolvesHosts(input: String, expected: String) {
        #expect(URLInput.resolve(input)?.absoluteString == expected)
    }

    @Test(arguments: ["rust ownership", "what is 1.5", "swift.concurrency is hard", "node.js"])
    func searchesText(input: String) {
        let url = URLInput.resolve(input)
        // "node.js" is a valid-looking host (js TLD); everything else searches.
        if input == "node.js" { #expect(url?.host() == "node.js") } else { #expect(url?.host() == "duckduckgo.com") }
    }

    @Test func emptyIsNil() { #expect(URLInput.resolve("   ") == nil) }
}

@Suite @MainActor struct StoreTests {
    @Test func openSelectClose() {
        let store = BrowserStore()
        let a = store.openTab(URL(string: "https://a.com"))
        let b = store.openTab(URL(string: "https://b.com"))
        #expect(store.currentSpace.today == [b, a])
        #expect(store.selectedTab?.id == b)
        store.close(b)
        #expect(store.selectedTab?.id == a)
        #expect(store.reopenClosed() == b)
        #expect(store.currentSpace.today.contains(b))
    }

    @Test func moveBetweenTiers() {
        let store = BrowserStore()
        let a = store.openTab(URL(string: "https://a.com"))
        store.move(a, to: .pinned)
        #expect(store.currentSpace.pinned == [a])
        #expect(store.currentSpace.today.isEmpty)
        #expect(store.tabs[a]?.tier == .pinned)
        store.move(a, to: .favorite)
        #expect(store.currentSpace.favorites == [a])
    }

    @Test func archivesStaleTodayTabsOnly() {
        let store = BrowserStore()
        let old = store.openTab(URL(string: "https://old.com"))
        let pinned = store.openTab(URL(string: "https://pinned.com"))
        store.move(pinned, to: .pinned)
        let current = store.openTab(URL(string: "https://now.com"))
        let past = Date().addingTimeInterval(-48 * 3600)
        store.update(old) { $0.lastActive = past }
        store.update(pinned) { $0.lastActive = past }
        let archived = store.runArchive()
        #expect(archived == [old])
        #expect(store.tabs[pinned] != nil)
        #expect(store.tabs[current] != nil)
        #expect(store.archive.first?.url?.host() == "old.com")
    }

    @Test func snapshotRoundTripRestoresAsleep() throws {
        let store = BrowserStore()
        let a = store.openTab(URL(string: "https://a.com"))
        store.update(a) { $0.interactionState = Data([1, 2, 3]) }
        let data = try JSONEncoder().encode(store.snapshot())
        let restored = BrowserStore(snapshot: try JSONDecoder().decode(SessionSnapshot.self, from: data))
        #expect(restored.tabs[a]?.isSleeping == true)
        #expect(restored.tabs[a]?.interactionState == Data([1, 2, 3]))
        #expect(restored.currentSpace.selected == a)
    }

    @Test func spacesHaveSeparateProfilesWhenAsked() {
        let store = BrowserStore()
        let work = store.addSpace(name: "Work", accentHue: 0.6, newProfile: true)
        #expect(work.profileID != store.spaces[0].profileID)
        store.switchSpace(by: 1)
        #expect(store.currentSpaceID == work.id)
        store.switchSpace(by: 1)
        #expect(store.currentSpaceID == store.spaces[0].id)
    }
}

@Suite struct HibernationTests {
    let now = Date()
    func tab(_ minutesIdle: Double, tier: TabTier = .today, activity: TabActivity = [], url: String = "https://x.com") -> TabRecord {
        TabRecord(url: URL(string: url), tier: tier, lastActive: now.addingTimeInterval(-minutesIdle * 60), activity: activity)
    }

    @Test func sleepsIdleTodayTabs() {
        let idle = tab(45), fresh = tab(5)
        let out = HibernationPolicy.balanced.tabsToSleep([idle, fresh], foreground: [], pressure: .normal, now: now)
        #expect(out == [idle.id])
    }

    @Test func respectsExemptions() {
        let media = tab(90, activity: .playingMedia)
        let form = tab(90, activity: .unsavedForm)
        let pinned = tab(90, tier: .pinned)
        let fg = tab(90)
        let allowed = tab(90, url: "https://keep.me")
        var policy = HibernationPolicy.balanced
        policy.neverSleepHosts = ["keep.me"]
        let out = policy.tabsToSleep([media, form, pinned, fg, allowed], foreground: [fg.id], pressure: .normal, now: now)
        #expect(out.isEmpty)
    }

    @Test func pressureShortensTimeoutAndCriticalTakesPinned() {
        let t10 = tab(10), pinned = tab(1, tier: .pinned)
        #expect(HibernationPolicy.balanced.tabsToSleep([t10], foreground: [], pressure: .normal, now: now).isEmpty)
        #expect(HibernationPolicy.balanced.tabsToSleep([t10], foreground: [], pressure: .warning, now: now) == [t10.id])
        let critical = HibernationPolicy.balanced.tabsToSleep([t10, pinned], foreground: [], pressure: .critical, now: now)
        #expect(Set(critical) == [t10.id, pinned.id])
        #expect(critical.first == t10.id) // least recently used first
    }

    @Test func capsLiveBackgroundTabs() {
        var policy = HibernationPolicy.balanced
        policy.maxLiveBackgroundTabs = 3
        let tabs = (0..<6).map { tab(Double($0)) }   // all fresh, none past timeout
        let out = policy.tabsToSleep(tabs, foreground: [], pressure: .normal, now: now)
        #expect(out.count == 3)
        #expect(Set(out) == Set(tabs.suffix(3).map(\.id)))  // the oldest three
    }
}
