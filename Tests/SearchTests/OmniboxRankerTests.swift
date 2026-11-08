import Foundation
import Testing
import BrowserCore
import Persistence
import Search

private func u(_ s: String) -> URL { URL(string: s)! }
private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func hit(_ url: String, _ title: String?, frecency: Double = 50, visits: Int = 1, typed: Int = 0,
                 adaptive: Double = 0) -> HistoryHit {
    let url = u(url)
    return HistoryHit(id: Int64(abs(url.absoluteString.hashValue % 1_000_000)), url: url, title: title,
                      host: url.host() ?? "", frecency: frecency, visitCount: visits, typedCount: typed,
                      lastVisit: now, adaptiveUse: adaptive)
}

@Suite struct OmniboxRankerTests {
    let ranker = OmniboxRanker()

    func rank(_ text: String, hits: [HistoryHit] = [], inputs: [InputMatch] = [], tabs: [PaletteItem] = [],
              bookmarks: [PaletteItem] = [], commands: [PaletteCommand] = [], deletion: Bool = false,
              caretAtEnd: Bool = true) -> [PaletteResult] {
        let q = PaletteQuery(text: text, tabs: tabs, bookmarks: bookmarks, commands: commands,
                             lastEditWasDeletion: deletion, caretAtEnd: caretAtEnd)
        return ranker.rank(q, snapshot: HistorySnapshot(hits: hits, inputs: inputs))
    }

    @Test func ghRanksGithubAboveGraph() {
        let r = rank("gh", hits: [hit("https://graph.example/", "Graph"), hit("https://github.com/", "GitHub")])
        let history = r.filter { $0.section == .history }
        #expect(history.map { $0.url?.host() } == ["github.com", "graph.example"])
        #expect(history[0].titleMatches == [0..<1, 3..<4])
    }

    @Test func frecencyBreaksTies() {
        let r = rank("docs", hits: [hit("https://a.dev/docs", "Docs A", frecency: 5),
                                    hit("https://b.dev/docs", "Docs B", frecency: 500)])
        #expect(r.first?.title == "Docs B")
    }

    @Test func hostPrefixBeatsTitleMatch() {
        let r = rank("app", hits: [hit("https://example.com/guide", "App Guide", frecency: 80),
                                   hit("https://apple.com/", "Welcome", frecency: 80)])
        #expect(r.first?.url?.host() == "apple.com")
    }

    @Test func sourceBoostOrdersTabsBookmarksHistory() {
        // Same title-prefix match and no frecency anywhere: only the source boost differs.
        let t = PaletteItem(id: TabID(), title: "Swift Forums", url: u("https://forums.example/"))
        let b = PaletteItem(id: TabID(), title: "Swift Docs", url: u("https://docs.example/"))
        let r = rank("swift", hits: [hit("https://blog.example/", "Swift Blog", frecency: 0)], tabs: [t], bookmarks: [b])
        #expect(r.prefix(3).map(\.section) == [.switchToTab, .bookmarks, .history])
        #expect(r[0].action == .switchToTab(t.id))
    }

    @Test func openTabDeduplicatesHistoryAndBookmark() {
        let url = "https://github.com/"
        let t = PaletteItem(id: TabID(), title: "GitHub", url: u(url))
        let r = rank("github", hits: [hit(url, "GitHub", typed: 3)], tabs: [t], bookmarks: [PaletteItem(id: TabID(), title: "GH", url: u(url))])
        #expect(r.filter { $0.url?.absoluteString == url && $0.section != .search }.count == 1)
        #expect(r[0].section == .switchToTab)
    }

    @Test func adaptiveBoostLiftsChosenResult() async throws {
        let store = try HistoryStore.inMemory(now: { now })
        try await store.recordVisit(url: u("https://reports.example/q3"), title: "Report Q3", kind: .link, at: now)
        for _ in 0..<10 { try await store.recordVisit(url: u("https://reporter.news/"), title: "Reporter", kind: .typed, at: now) }
        let engine = PaletteEngine(history: store)
        try await engine.refreshHistoryCache()
        #expect(engine.quickResults(PaletteQuery(text: "rep")).first?.title == "Reporter")

        for _ in 0..<5 { try await store.recordInputChoice(input: "rep", url: u("https://reports.example/q3")) }
        try await engine.refreshHistoryCache()
        #expect(engine.quickResults(PaletteQuery(text: "rep")).first?.title == "Report Q3")
        #expect(await engine.fullResults(PaletteQuery(text: "rep")).first?.title == "Report Q3")
    }

    @Test func sectionsCappedAtThreeUnlessScoped() {
        let hits = (0..<6).map { hit("https://site\($0).com/notes", "Notes \($0)", frecency: Double(10 - $0)) }
        let all = rank("notes", hits: hits)
        #expect(all.filter { $0.section == .history }.count == 3)
        let scoped = rank("@history notes", hits: hits)
        #expect(scoped.filter { $0.section == .history }.count == 6)
        #expect(!scoped.contains { $0.section == .search })
    }

    @Test func commandScopeAndAliases() {
        let cmds = [PaletteCommand(id: "sidebar", title: "Toggle Sidebar", aliases: ["hide sidebar"], shortcut: "⌘S", icon: "sidebar.left"),
                    PaletteCommand(id: "reopen", title: "Reopen Closed Tab", aliases: ["undo close"], shortcut: "⌘⇧T", icon: "arrow.uturn.left")]
        let tabs = [PaletteItem(id: TabID(), title: "Hide and seek", url: u("https://hide.example/"))]
        let scoped = rank(">hide", tabs: tabs, commands: cmds)
        #expect(scoped.map(\.commandID) == ["sidebar"])
        #expect(scoped[0].shortcut == "⌘S" && scoped[0].icon == "sidebar.left")

        let all = rank("> ", commands: cmds)
        #expect(all.count == 2 && all.allSatisfy { $0.section == .actions })

        let mixed = rank("undo", tabs: tabs, commands: cmds)
        #expect(mixed.contains { $0.commandID == "reopen" })
    }

    @Test func tabsScope() {
        let tabs = [PaletteItem(id: TabID(), title: "Mail", url: u("https://mail.example/"))]
        let r = rank("@tabs ma", hits: [hit("https://maps.example/", "Maps")], tabs: tabs,
                     commands: [PaletteCommand(id: "m", title: "Mute tab")])
        #expect(r.map(\.section) == [.switchToTab])
        #expect(PaletteQuery(text: "@tabs ma").parsed.scope == .tabs)
        #expect(PaletteQuery(text: "@history x").parsed.query == "x")
        #expect(PaletteQuery(text: "@tabsx").parsed.scope == .all)
    }

    @Test func searchRowsAlwaysLast() {
        let r = rank("swift concurrency", hits: [hit("https://swift.org/", "Swift concurrency")])
        let last = r.last
        #expect(last?.section == .search)
        #expect(last?.title == "Search the web for \u{201C}swift concurrency\u{201D}")
        #expect(last?.url?.absoluteString == "https://duckduckgo.com/?q=swift%20concurrency")
        #expect(!r.contains { $0.id == "goto" })
    }

    @Test func urlLikeInputGetsGoToFirstWhenUnknown() {
        let r = rank("example.org/path")
        #expect(r.map(\.id) == ["goto", "search"])
        #expect(r[0].action == .goTo(u("https://example.org/path")))
        if case .search(let text, let url) = r[1].action {
            #expect(text == "example.org/path")
            #expect(url?.host() == "duckduckgo.com")
        } else { Issue.record("expected search action") }
    }

    @Test func urlLikeInputWithHostMatchKeepsHistoryFirst() {
        let r = rank("github.com", hits: [hit("https://github.com/", "GitHub", typed: 1)])
        #expect(r.first?.section == .history)
        #expect(r.suffix(2).map(\.id) == ["goto", "search"])
    }

    @Test func emptyQueryShowsTabsAndTopSitesOnly() {
        let tabs = [PaletteItem(id: TabID(), title: "One", url: u("https://one.com/")),
                    PaletteItem(id: TabID(), title: "Two", url: u("https://two.com/"))]
        let r = rank("", hits: [hit("https://top.com/", "Top")], tabs: tabs,
                     commands: [PaletteCommand(id: "x", title: "X")])
        #expect(!r.contains { $0.section == .search || $0.section == .actions })
        #expect(r.filter { $0.section == .switchToTab }.map(\.title) == ["One", "Two"])
        #expect(r.contains { $0.title == "Top" })
    }

    @Test func looksLikeURL() {
        for s in ["example.com", "https://x.y/z", "localhost:3000", "10.0.0.1/a", "about:blank", "sub.domain.co.uk/path?q=1"] {
            #expect(OmniboxRanker.looksLikeURL(s), "\(s)")
        }
        for s in ["swift concurrency", "hello", "1.5", "file.", "v1.2.3", "what is a.b c"] {
            #expect(!OmniboxRanker.looksLikeURL(s), "\(s)")
        }
    }
}

@Suite struct InlineCompletionTests {
    let ranker = OmniboxRanker()
    let gh = hit("https://www.github.com/", "GitHub", frecency: 300, visits: 10, typed: 2)

    func top(_ text: String, hits: [HistoryHit]? = nil, deletion: Bool = false, caretAtEnd: Bool = true) -> String? {
        let q = PaletteQuery(text: text, lastEditWasDeletion: deletion, caretAtEnd: caretAtEnd)
        return ranker.rank(q, snapshot: HistorySnapshot(hits: hits ?? [gh], inputs: [])).first?.inlineCompletion
    }

    @Test func completesHostPrefixIgnoringWWW() {
        #expect(top("git") == "github.com")
        #expect(top("GIT") == "GIThub.com")       // typed casing preserved
        #expect(top("www.git") == nil)             // display has www. stripped; not a prefix
    }

    @Test func neverAfterDeletionOrWithCaretInMiddle() {
        #expect(top("git", deletion: true) == nil)
        #expect(top("git", caretAtEnd: false) == nil)
    }

    @Test func requiresTypedCount() {
        let linkOnly = hit("https://github.com/", "GitHub", frecency: 300, visits: 10, typed: 0)
        #expect(top("git", hits: [linkOnly]) == nil)
    }

    @Test func noCompletionForTitleOnlyOrSpaces() {
        let docs = hit("https://developer.apple.com/", "Swift Documentation", frecency: 300, typed: 3)
        #expect(top("swift", hits: [docs]) == nil)
        #expect(top("git hub") == nil)
        #expect(top("github.com") == nil)          // nothing left to complete
    }

    @Test func completesPathsWithinKnownHost() {
        let repo = hit("https://github.com/apple/swift", "Swift repo", frecency: 300, typed: 1)
        #expect(top("github.com/ap", hits: [repo]) == "github.com/apple/swift")
    }

    @Test func onlyOnFirstResult() {
        let r = ranker.rank(PaletteQuery(text: "git"), snapshot: HistorySnapshot(hits: [gh], inputs: []))
        #expect(r.dropFirst().allSatisfy { $0.inlineCompletion == nil })
    }

    @Test func adaptiveKeyEnablesCompletion() async throws {
        let store = try HistoryStore.inMemory(now: { now })
        let url = u("https://docs.example.org/guide/start")
        try await store.recordVisit(url: url, title: "Getting Started", kind: .typed, at: now)
        try await store.recordInputChoice(input: "docs.example.org/g", url: url)
        let engine = PaletteEngine(history: store)
        try await engine.refreshHistoryCache()
        let r = engine.quickResults(PaletteQuery(text: "docs.example.org/g"))
        #expect(r.first?.inlineCompletion == "docs.example.org/guide/start")
    }
}

@Suite struct PaletteEngineTests {
    @Test func fullResultsAddFTSHitsMissingFromQuickIndex() async throws {
        let store = try HistoryStore.inMemory(now: { now })
        // One old link visit: excluded from the quick index by HQP gating.
        try await store.recordVisit(url: u("https://obscure.example/kubernetes-networking"), title: "Kubernetes networking deep dive",
                                    kind: .link, at: now.addingTimeInterval(-30 * 86_400))
        try await store.recordVisit(url: u("https://kube.dev/"), title: "Kube", kind: .typed, at: now)
        let engine = PaletteEngine(history: store)
        try await engine.refreshHistoryCache()

        let q = PaletteQuery(text: "networking")
        #expect(!engine.quickResults(q).contains { $0.section == .history })
        let full = await engine.fullResults(q)
        #expect(full.first?.title == "Kubernetes networking deep dive")
        #expect(full.last?.section == .search)
    }

    @Test func worksWithoutHistoryStore() async {
        let engine = PaletteEngine(history: nil)
        let tabs = [PaletteItem(id: TabID(), title: "Inbox", url: u("https://mail.example/"))]
        let r = await engine.fullResults(PaletteQuery(text: "inb", tabs: tabs))
        #expect(r.first?.title == "Inbox")
    }

    /// Synchronous pass over a 20k-entry snapshot + tabs + commands. Asserted in release only.
    @Test func quickPassPerformance() {
        let words = ["swift", "github", "docs", "apple", "news", "graph", "kernel", "rust", "maps", "mail", "video", "shop"]
        let hits = (0..<20_000).map { i in
            hit("https://\(words[i % 12]).\(words[(i / 12) % 12]).com/page/\(i)", "\(words[(i / 5) % 12].capitalized) page \(i)",
                frecency: Double(20_000 - i))
        }
        let snapshot = HistorySnapshot(hits: hits, inputs: [])
        let tabs = (0..<100).map { PaletteItem(id: TabID(), title: "Tab \($0) \(words[$0 % 12])", url: u("https://t\($0).com/")) }
        let cmds = (0..<60).map { PaletteCommand(id: "c\($0)", title: "Command \(words[$0 % 12]) \($0)") }
        let ranker = OmniboxRanker()
        let clock = ContinuousClock()
        var best = Duration.seconds(10)
        for _ in 0..<3 {
            let t = clock.measure {
                _ = ranker.rank(PaletteQuery(text: "gh", tabs: tabs, commands: cmds), snapshot: snapshot)
            }
            best = min(best, t)
        }
        print("quick pass 20k: \(best)")
        #if !DEBUG
        #expect(best < .milliseconds(16), "quick pass: \(best)")
        #endif
    }
}
