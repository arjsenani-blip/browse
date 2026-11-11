import Foundation
import Testing
@testable import BrowserCore

@Suite struct SearchEngineTests {
    @Test func everyEngineBuildsAnHTTPSSearchURL() {
        for engine in SearchEngine.allCases {
            let url = URLInput.resolve("swift concurrency", searchTemplate: engine.template)
            #expect(url?.scheme == "https", "\(engine)")
            #expect(url?.host() == engine.host, "\(engine)")
            #expect(url?.absoluteString.contains("swift%20concurrency") == true, "\(engine)")
        }
    }
}

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

    @Test func removeSpaceDropsTabsAndProfile() {
        let store = BrowserStore()
        let work = store.addSpace(name: "Work", accentHue: 0.6, newProfile: true)
        store.currentSpaceID = work.id
        let t = store.openTab(URL(string: "https://w.com"))
        #expect(store.removeSpace(work.id) == [t])
        #expect(store.tabs[t] == nil)
        #expect(store.spaces.count == 1)
        #expect(store.profiles.count == 1)
        #expect(store.currentSpaceID == store.spaces[0].id)
        #expect(store.removeSpace(store.spaces[0].id).isEmpty)   // last space stays
        #expect(store.spaces.count == 1)
    }

    @Test func damagedSessionsRestoreInsteadOfCrashing() {
        let source = BrowserStore()
        let t = source.openTab(URL(string: "https://a.com"))
        var snap = source.snapshot()
        snap.tabs += snap.tabs              // duplicate tab ids
        snap.profiles = []                  // profile list lost
        let restored = BrowserStore(snapshot: snap)
        #expect(restored.tabs[t] != nil)
        #expect(restored.profile(for: restored.currentSpace).id == restored.currentSpace.profileID)
    }

    @Test func newSpacesFollowTheArchiveSetting() {
        let store = BrowserStore()
        store.setArchiveInterval(7 * 24 * 3600)
        let work = store.addSpace(name: "Work", accentHue: 0.6, newProfile: false)
        #expect(work.archiveAfter == 7 * 24 * 3600)
    }

    @Test func removingASpaceNeverLandsOnAPrivateOne() {
        let store = BrowserStore()
        let personal = store.spaces[0]
        let priv = store.addSpace(name: "Private", accentHue: 0.7, newProfile: true)
        store.ephemeralSpaces.insert(priv.id)
        let work = store.addSpace(name: "Work", accentHue: 0.6, newProfile: true)
        // Order: Personal, Private, Work. Deleting Work must not select Private.
        store.currentSpaceID = work.id
        store.removeSpace(work.id)
        #expect(store.currentSpaceID == personal.id)
        // The last normal space can't go, even though a private one remains.
        #expect(store.removeSpace(personal.id).isEmpty)
        #expect(store.spaces.contains { $0.id == personal.id })
        // Private spaces themselves can still be removed (window closed).
        store.currentSpaceID = priv.id
        store.removeSpace(priv.id)
        #expect(store.currentSpaceID == personal.id)
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

@Suite @MainActor struct SessionSafetyTests {
    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "aegis-session-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func unreadableSessionIsSetAsideNotOverwritten() throws {
        let dir = tempDir()
        let store = SessionStore(directory: dir)
        try Data("not json".utf8).write(to: store.url)
        #expect(store.load() == nil)
        // The corrupt file was moved aside, so a fresh save can't destroy it.
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "session.unreadable.json").path))
    }

    @Test func previousCopyRecoversAfterCorruption() throws {
        let dir = tempDir()
        let store = SessionStore(directory: dir)
        let s = BrowserStore()
        s.openTab(URL(string: "https://first.example"))
        try store.save(s.snapshot())
        s.openTab(URL(string: "https://second.example"))
        try store.save(s.snapshot())            // first save becomes session.prev.json
        try Data("garbage".utf8).write(to: store.url)
        let recovered = store.load()
        #expect(recovered?.tabs.count == 1)     // the previous good session
    }

    @Test func privateSpacesNeverPersistOrReopen() {
        let s = BrowserStore()
        let priv = s.addSpace(name: "Private", accentHue: 0.7, newProfile: true)
        s.ephemeralSpaces.insert(priv.id)
        let t = s.openTab(URL(string: "https://secret.example"), in: priv.id)
        #expect(!s.snapshot().spaces.contains { $0.id == priv.id })
        #expect(!s.snapshot().tabs.contains { $0.id == t })
        s.close(t)
        #expect(s.closed.isEmpty)
    }
}

@Suite @MainActor struct FolderTests {
    @Test func createMoveAndOrder() {
        let s = BrowserStore()
        let sid = s.currentSpaceID
        let a = s.openTab(URL(string: "https://a.com")); s.move(a, to: .pinned)
        let b = s.openTab(URL(string: "https://b.com"))          // today
        let f = s.newFolder(in: sid)
        #expect(s.currentSpace.pinnedEntries.first == .folder(s.currentSpace.folders[0]))  // new folders go on top
        s.moveTab(b, toFolder: f)
        #expect(s.tabs[b]?.tier == .pinned)
        #expect(s.currentSpace.folders[0].tabs == [b])
        #expect(!s.currentSpace.today.contains(b))
        // Loose pinned tab still listed after the folder; folder tab not listed loose.
        #expect(s.currentSpace.pinnedEntries.count == 2)
        s.removeFromFolder(b)
        #expect(s.currentSpace.folders[0].tabs.isEmpty)
        #expect(s.currentSpace.pinned.contains(b))
    }

    @Test func deleteKeepsOrClosesTabs() {
        let s = BrowserStore()
        let sid = s.currentSpaceID
        let f1 = s.newFolder(in: sid), f2 = s.newFolder(in: sid)
        let a = s.openTab(URL(string: "https://a.com")), b = s.openTab(URL(string: "https://b.com"))
        s.moveTab(a, toFolder: f1); s.moveTab(b, toFolder: f2)
        s.deleteFolder(f1, closeTabs: false)
        #expect(s.tabs[a] != nil && s.currentSpace.pinned.contains(a))
        #expect(s.deleteFolder(f2, closeTabs: true) == [b])
        #expect(s.tabs[b] == nil)
        #expect(s.currentSpace.folders.isEmpty)
    }

    @Test func unpinningLeavesFolderAndOldSessionsDecode() throws {
        let s = BrowserStore()
        let f = s.newFolder(in: s.currentSpaceID)
        let a = s.openTab(URL(string: "https://a.com"))
        s.moveTab(a, toFolder: f)
        s.move(a, to: .today)
        #expect(s.currentSpace.folders[0].tabs.isEmpty)
        // A session saved before folders existed has no "folderList" key.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s.snapshot())) as! [String: Any]
        var spaces = json["spaces"] as! [[String: Any]]
        spaces[0].removeValue(forKey: "folderList")
        json["spaces"] = spaces
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.spaces[0].folders.isEmpty)
    }

    @Test func tabsNeverMoveIntoAFolderAcrossProfiles() {
        let s = BrowserStore()
        let work = s.addSpace(name: "Work", accentHue: 0.6, newProfile: true)
        let f = s.newFolder(in: work.id)
        let personalTab = s.openTab(URL(string: "https://a.com"), in: s.spaces[0].id)   // own profile
        s.moveTab(personalTab, toFolder: f)
        #expect(s.space(containing: personalTab)?.id == s.spaces[0].id)
        #expect(s.spaces.first { $0.id == work.id }?.folders[0].tabs.isEmpty == true)
    }
}
