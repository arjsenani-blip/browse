import Foundation
import Testing
@testable import BrowserCore

// MARK: - Fixtures

enum ImportFixtures {
    /// Modeled on real StorableSidebar.json files (as parsed by arc-export, Zen,
    /// Raycast): containers alternate marker/object, items and spaces alternate
    /// id/object, a Little Arc container that must be skipped, folders, a split
    /// view, an easel, an arc:// tab, a cross-tier duplicate, two profiles.
    static let arcSidebar = #"""
    {
      "sidebarSyncState": { "items": [] },
      "sidebar": {
        "containers": [
          { "littleBrowser": {} },
          { "items": [], "spaces": ["LB-SPACE", { "id": "LB-SPACE", "title": "Little", "containerIDs": ["unpinned", "LB-U"] }] },
          { "global": {} },
          {
            "topAppsContainerIDs": [
              { "default": true }, "TOP-DEFAULT",
              { "custom": { "_0": { "directoryBasename": "Profile 1" } } }, "TOP-P1"
            ],
            "spaces": [
              "thebrowser.company.defaultPersonalSpaceID",
              {
                "id": "thebrowser.company.defaultPersonalSpaceID",
                "title": "Personal",
                "profile": { "default": true },
                "containerIDs": ["unpinned", "PERS-UNPINNED", "pinned", "PERS-PINNED"],
                "customInfo": {
                  "iconType": { "emoji_v2": "🏠" },
                  "windowTheme": {
                    "background": { "single": { "_0": { "style": { "color": { "_0": {
                      "blendedSingleColor": { "_0": {
                        "color": { "red": 0.12, "green": 0.35, "blue": 0.95, "alpha": 1, "colorSpace": "extendedSRGB" },
                        "modifiers": { "intensityFactor": 0.6, "overlay": "grain", "noiseFactor": 0.4 }
                      } }
                    } } } } } },
                    "primaryColorPalette": { "midTone": { "red": 0.2, "green": 0.3, "blue": 0.9, "alpha": 1 } }
                  }
                }
              },
              "WORK-SPACE",
              {
                "id": "WORK-SPACE",
                "title": "  Work  ",
                "profile": { "custom": { "_0": { "directoryBasename": "Profile 1" } } },
                "newContainerIDs": [{ "pinned": {} }, "WORK-PINNED", { "unpinned": { "_0": { "shared": {} } } }, "WORK-UNPINNED"],
                "customInfo": {
                  "windowTheme": { "background": { "single": { "_0": { "style": { "color": { "_0": {
                    "blendedGradient": { "_0": {
                      "baseColors": [
                        { "red": 0.5, "green": 0.5, "blue": 0.5, "alpha": 1 },
                        { "red": 0.95, "green": 0.25, "blue": 0.2, "alpha": 1 }
                      ],
                      "overlayColors": []
                    } }
                  } } } } } } }
                }
              },
              "EMPTY-SPACE",
              { "id": "EMPTY-SPACE", "title": null, "containerIDs": ["unpinned", "EMPTY-UNPINNED"] }
            ],
            "items": [
              "TOP-DEFAULT", { "id": "TOP-DEFAULT", "parentID": null, "childrenIds": ["FAV-MAIL", "FAV-CAL"], "title": null,
                "data": { "itemContainer": { "containerType": { "topApps": { "_0": { "default": true } } } } } },
              "FAV-MAIL", { "id": "FAV-MAIL", "parentID": "TOP-DEFAULT", "childrenIds": [], "title": null,
                "data": { "tab": { "savedURL": "https://mail.google.com/mail/u/0/#inbox", "savedTitle": "Inbox (3)", "timeLastActiveAt": 752000000.5 } } },
              "FAV-CAL", { "id": "FAV-CAL", "parentID": "TOP-DEFAULT", "childrenIds": [], "title": null,
                "data": { "tab": { "savedURL": "https://calendar.google.com/", "savedTitle": "Google Calendar" } } },

              "TOP-P1", { "id": "TOP-P1", "childrenIds": ["FAV-SLACK"], "data": { "itemContainer": { "containerType": { "topApps": { "_0": { "custom": {} } } } } } },
              "FAV-SLACK", { "id": "FAV-SLACK", "parentID": "TOP-P1", "childrenIds": [], "data": { "tab": { "savedURL": "https://app.slack.com/client", "savedTitle": "Slack" } } },

              "PERS-PINNED", { "id": "PERS-PINNED", "childrenIds": ["P-GH", "P-FOLDER", "P-ARC", "P-EASEL", "P-SPLIT", "P-DUPE", "MISSING-ID"],
                "data": { "itemContainer": { "containerType": { "spaceItems": { "_0": "thebrowser.company.defaultPersonalSpaceID" } } } } },
              "P-GH", { "id": "P-GH", "parentID": "PERS-PINNED", "childrenIds": [], "title": "My GitHub",
                "data": { "tab": { "savedURL": "https://github.com/", "savedTitle": "GitHub" } } },
              "P-FOLDER", { "id": "P-FOLDER", "parentID": "PERS-PINNED", "childrenIds": ["P-HN", "P-SUB"], "title": "Reading",
                "data": { "list": {} } },
              "P-HN", { "id": "P-HN", "parentID": "P-FOLDER", "childrenIds": [], "title": null,
                "data": { "tab": { "savedURL": "https://news.ycombinator.com/" } } },
              "P-SUB", { "id": "P-SUB", "parentID": "P-FOLDER", "childrenIds": ["P-LOBSTERS"], "title": "Tech", "data": { "list": {} } },
              "P-LOBSTERS", { "id": "P-LOBSTERS", "parentID": "P-SUB", "childrenIds": [], "data": { "tab": { "savedURL": "https://lobste.rs", "savedTitle": "Lobsters" } } },
              "P-ARC", { "id": "P-ARC", "parentID": "PERS-PINNED", "childrenIds": [], "data": { "tab": { "savedURL": "arc://settings", "savedTitle": "Settings" } } },
              "P-EASEL", { "id": "P-EASEL", "parentID": "PERS-PINNED", "childrenIds": [], "title": "Sketch", "data": { "easel": { "easelID": "E1" } } },
              "P-SPLIT", { "id": "P-SPLIT", "parentID": "PERS-PINNED", "childrenIds": ["S-A", "S-B"], "data": { "splitView": { "layoutOrientation": "horizontal" } } },
              "S-A", { "id": "S-A", "parentID": "P-SPLIT", "data": { "tab": { "savedURL": "https://developer.apple.com/documentation/swift", "savedTitle": "Swift" } } },
              "S-B", { "id": "S-B", "parentID": "P-SPLIT", "data": { "tab": { "savedURL": "https://swift.org", "savedTitle": "Swift.org" } } },
              "P-DUPE", { "id": "P-DUPE", "parentID": "PERS-PINNED", "data": { "tab": { "savedURL": "https://calendar.google.com", "savedTitle": "Cal again" } } },

              "PERS-UNPINNED", { "id": "PERS-UNPINNED", "childrenIds": ["U-1", "U-2"], "data": { "itemContainer": {} } },
              "U-1", { "id": "U-1", "parentID": "PERS-UNPINNED", "data": { "tab": { "savedURL": "https://en.wikipedia.org/wiki/Arc", "savedTitle": "Arc - Wikipedia" } } },
              "U-2", { "id": "U-2", "parentID": "PERS-UNPINNED", "data": { "tab": { "savedURL": "https://example.org/b", "savedTitle": "B" } } },

              "WORK-PINNED", { "id": "WORK-PINNED", "childrenIds": [], "data": { "itemContainer": {} } },
              "W-LINEAR", { "id": "W-LINEAR", "parentID": "WORK-PINNED", "title": null, "data": { "tab": { "savedURL": "https://linear.app/acme/inbox", "savedTitle": "Linear" } } },
              "W-NOTION", { "id": "W-NOTION", "parentID": "WORK-PINNED", "title": null, "data": { "tab": { "savedURL": "https://www.notion.so/acme", "savedTitle": null } } },
              "WORK-UNPINNED", { "id": "WORK-UNPINNED", "childrenIds": [], "data": { "itemContainer": {} } },
              "junk-key", 42,
              "no-id", { "title": "orphan" }
            ]
          }
        ]
      },
      "version": 1
    }
    """#

    static let chromeBookmarks = #"""
    {
       "checksum": "0f1e2d3c4b5a69788796a5b4c3d2e1f0",
       "roots": {
          "bookmark_bar": {
             "children": [
                { "date_added": "13350000000000000", "guid": "a1", "id": "5", "name": "GitHub", "type": "url", "url": "https://github.com/" },
                { "date_added": "13350000000000001", "guid": "a2", "id": "6", "name": "Dev", "type": "folder", "date_modified": "0",
                  "children": [
                    { "guid": "a3", "id": "7", "name": "MDN", "type": "url", "url": "https://developer.mozilla.org/" },
                    { "guid": "a4", "id": "8", "name": "Deep", "type": "folder", "children": [
                      { "guid": "a5", "id": "9", "name": "", "type": "url", "url": "https://swift.org/documentation/" }
                    ] }
                  ] },
                { "guid": "a6", "id": "10", "name": "Bookmarklet", "type": "url", "url": "javascript:alert(1)" },
                { "guid": "a7", "id": "11", "name": "HN", "type": "url", "url": "https://news.ycombinator.com/" }
             ],
             "date_added": "13350000000000000", "guid": "0bc5d13f-2cba-5d74-951f-3f233fe6c908", "id": "1",
             "name": "Bookmarks bar", "type": "folder"
          },
          "other": {
             "children": [ { "guid": "b1", "id": "12", "name": "Recipes", "type": "url", "url": "https://cooking.nytimes.com/" }, "garbage" ],
             "guid": "82b081ec-3dd3-529c-8475-ab6c344590dd", "id": "2", "name": "Other bookmarks", "type": "folder"
          },
          "synced": {
             "children": [ { "guid": "c1", "id": "13", "name": "Phone link", "type": "url", "url": "https://m.example.com/" } ],
             "guid": "4cf2e351-0e85-532b-bb37-df045d8f8d0f", "id": "3", "name": "Mobile bookmarks", "type": "folder"
          }
       },
       "version": 1
    }
    """#

    /// Safari's tree as PropertyListSerialization would produce it (written as
    /// binary in tests, like the real file).
    static func safariPlist(extraChildren: [Any] = []) -> Data {
        let leaf: (String, String) -> [String: Any] = { title, url in
            ["WebBookmarkType": "WebBookmarkTypeLeaf", "WebBookmarkUUID": UUID().uuidString,
             "URLString": url, "URIDictionary": ["title": title]]
        }
        let tree: [String: Any] = [
            "WebBookmarkFileVersion": 1,
            "WebBookmarkType": "WebBookmarkTypeList",
            "Title": "",
            "Children": [
                ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History", "WebBookmarkIdentifier": "History"],
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
                    leaf("Apple", "https://www.apple.com/"),
                    ["WebBookmarkType": "WebBookmarkTypeList", "Title": "News", "Children": [
                        leaf("BBC", "https://www.bbc.co.uk/news"),
                    ]],
                ]],
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksMenu", "Children": [
                    leaf("Wikipedia", "https://www.wikipedia.org/"),
                    leaf("Local file", "file:///Users/me/notes.html"),
                ]],
                ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [
                    leaf("Later", "https://example.com/article"),
                ]],
            ] + extraChildren,
        ]
        return try! PropertyListSerialization.data(fromPropertyList: tree, format: .binary, options: 0)
    }

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "vane-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Arc

@Suite struct ArcImporterTests {
    let plan = try! ArcImporter().parse(Data(ImportFixtures.arcSidebar.utf8))

    @Test func readsSpacesFromGlobalContainerOnly() {
        #expect(plan.spaces.map(\.name) == ["Personal", "Work", "Space 3"])
        #expect(plan.spaces.map(\.sourceProfile) == ["Default", "Profile 1", "Default"])
        #expect(plan.spaces[0].icon == "🏠")
    }

    @Test func pinnedTabsFlattenFoldersAndSplitViewsInOrder() {
        let pinned = plan.spaces[0].pinned
        #expect(pinned.map(\.url.absoluteString) == [
            "https://github.com/", "https://news.ycombinator.com/", "https://lobste.rs",
            "https://developer.apple.com/documentation/swift", "https://swift.org", "https://calendar.google.com",
        ])
        #expect(pinned[0].title == "My GitHub")                   // user rename wins
        #expect(pinned[1].title == "news.ycombinator.com")        // no titles → host
        #expect(pinned[1].folderPath == ["Reading"])
        #expect(pinned[2].folderPath == ["Reading", "Tech"])
        #expect(pinned[3].folderPath == [])                       // split view isn't a folder
    }

    @Test func parentIDFallbackWhenChildrenIdsEmpty() {
        #expect(plan.spaces[1].pinned.map(\.title) == ["Linear", "www.notion.so"])
    }

    @Test func favoritesComeFromTopAppsPerProfile() {
        #expect(plan.spaces[0].favorites.map(\.title) == ["Inbox (3)", "Google Calendar"])
        #expect(plan.spaces[1].favorites.map(\.title) == ["Slack"])
        #expect(plan.spaces[2].favorites.count == 2)
    }

    @Test func huesFromThemeOrFallback() {
        // (0.12, 0.35, 0.95) is blue ≈ 0.62; gradient skips grey and finds red ≈ 0.01.
        #expect(abs(plan.spaces[0].hue - 0.62) < 0.02)
        #expect(plan.spaces[1].hue < 0.03 || plan.spaces[1].hue > 0.97)
        #expect(plan.spaces[2].hue == ImportHue.fallback(2))
        #expect(plan.spaces.allSatisfy { (0...1).contains($0.hue) })
    }

    @Test func warnsAboutSkippedItems() {
        #expect(plan.warnings.contains { $0.contains("without a web URL") })
        #expect(plan.warnings.contains { $0.contains("note/easel") })
        #expect(plan.warnings.contains { $0.contains("Space 3") && $0.contains("no pinned container") })
        #expect(plan.spaces.allSatisfy { $0.today.isEmpty })
    }

    @Test func optionallyIncludesUnpinnedAndFiltersProfile() throws {
        let p = try ArcImporter(options: .init(includeUnpinned: true, profile: "Default")).parse(Data(ImportFixtures.arcSidebar.utf8))
        #expect(p.spaces.map(\.name) == ["Personal", "Space 3"])
        #expect(p.spaces[0].today.map(\.title) == ["Arc - Wikipedia", "B"])
    }

    @Test(arguments: [
        "", "not json", "[1,2,3]", "{}", #"{"sidebar": {"containers": "nope"}}"#,
        #"{"sidebar": {"containers": [{"global": {}}]}}"#,
    ])
    func malformedThrows(input: String) {
        #expect(throws: ImportError.self) { try ArcImporter().parse(Data(input.utf8)) }
    }

    @Test func wrongTypesAndCyclesDegradeGracefully() throws {
        let json = #"""
        {"sidebar": {"containers": [{"global": {}}, {
          "topAppsContainerIDs": ["TOP-MISSING", {"default": true}],
          "spaces": ["S", {"id": "S", "title": 7, "containerIDs": ["pinned", "A", "unpinned"], "customInfo": {"windowTheme": "x"}}, "T", "U"],
          "items": [
            "A", {"id": "A", "childrenIds": ["B", 3, null]},
            "B", {"id": "B", "parentID": "A", "childrenIds": ["C"], "title": "loop", "data": {"list": {}}},
            "C", {"id": "C", "parentID": "B", "childrenIds": ["B"], "title": "loop2", "data": {"list": {}}},
            "D", {"id": "D", "parentID": "A", "data": {"tab": {"savedURL": 12}}},
            "E", {"id": "E", "parentID": "C", "data": {"tab": {"savedURL": "https://ok.example/"}}}
          ]}]}}
        """#
        let p = try ArcImporter().parse(Data(json.utf8))
        #expect(p.spaces.count == 1)
        #expect(p.spaces[0].name == "Space 1")
        #expect(p.spaces[0].favorites.isEmpty)
        #expect(p.spaces[0].pinned.isEmpty) // B's explicit children win; E is only reachable by parentID under C, which lists B
        #expect(!p.warnings.isEmpty)
    }

    @Test func emptyItemsStillYieldSpaces() throws {
        let json = #"{"sidebar":{"containers":[{"global":{}},{"spaces":["S",{"id":"S","title":"Solo","containerIDs":["pinned","P"]}]}]}}"#
        let p = try ArcImporter().parse(Data(json.utf8))
        #expect(p.spaces.map(\.name) == ["Solo"])
        #expect(p.warnings.contains { $0.contains("no items") })
    }
}

// MARK: - Chrome

@Suite struct ChromeBookmarksTests {
    @Test func flattensWithFolderPaths() throws {
        let plan = try ChromeBookmarksImporter().parse(Data(ImportFixtures.chromeBookmarks.utf8))
        let b = plan.bookmarks
        #expect(b.map(\.title) == ["GitHub", "MDN", "swift.org", "HN", "Recipes", "Phone link"])
        #expect(b[1].folderPath == ["Bookmarks bar", "Dev"])
        #expect(b[2].folderPath == ["Bookmarks bar", "Dev", "Deep"])
        #expect(b.map(\.root) == [.bar, .bar, .bar, .bar, .other, .mobile])
        #expect(b.filter(\.isTopLevelOfBar).map(\.title) == ["GitHub", "HN"])
        #expect(plan.warnings.count == 2) // javascript: + "garbage"
    }

    @Test(arguments: ["", "{}", #"{"roots": []}"#, "[]"])
    func malformedThrows(input: String) {
        #expect(throws: ImportError.self) { try ChromeBookmarksImporter().parse(Data(input.utf8)) }
    }

    @Test func knownPathsCoverMajorBrowsers() {
        let home = URL(filePath: "/Users/test")
        let paths = ChromeBookmarksImporter.knownChromiumBookmarkPaths(home: home)
        let byName = Dictionary(paths.map { ($0.browser, $0.url.path) }, uniquingKeysWith: { a, _ in a })
        #expect(byName["Google Chrome"] == "/Users/test/Library/Application Support/Google/Chrome/Default/Bookmarks")
        #expect(byName["Brave"] == "/Users/test/Library/Application Support/BraveSoftware/Brave-Browser/Default/Bookmarks")
        #expect(byName["Microsoft Edge"] == "/Users/test/Library/Application Support/Microsoft Edge/Default/Bookmarks")
        #expect(byName["Vivaldi"] == "/Users/test/Library/Application Support/Vivaldi/Default/Bookmarks")
        #expect(byName["Arc"] == "/Users/test/Library/Application Support/Arc/User Data/Default/Bookmarks")
    }
}

// MARK: - Safari

@Suite struct SafariBookmarksTests {
    @Test func parsesBinaryPlist() throws {
        let plan = try SafariBookmarksImporter().parse(ImportFixtures.safariPlist())
        #expect(plan.bookmarks.map(\.title) == ["Apple", "BBC", "Wikipedia"])
        #expect(plan.bookmarks[0].folderPath == ["Favorites"])
        #expect(plan.bookmarks[0].isTopLevelOfBar)
        #expect(plan.bookmarks[1].folderPath == ["Favorites", "News"])
        #expect(plan.bookmarks[2].root == .other)
        #expect(plan.warnings.contains { $0.contains("without a web URL") }) // file:// skipped
    }

    @Test func readingListOptIn() throws {
        let plan = try SafariBookmarksImporter(includeReadingList: true).parse(ImportFixtures.safariPlist())
        #expect(plan.bookmarks.last?.root == .readingList)
        #expect(plan.bookmarks.last?.folderPath == ["Reading List"])
    }

    @Test func malformedNodesWarn() throws {
        let plan = try SafariBookmarksImporter().parse(ImportFixtures.safariPlist(extraChildren: ["junk", ["WebBookmarkType": "Weird"]]))
        #expect(plan.bookmarks.count == 3)
        #expect(plan.warnings.contains { $0.contains("malformed") })
    }

    @Test func notAPlistThrows() {
        #expect(throws: ImportError.self) { try SafariBookmarksImporter().parse(Data("hello".utf8)) }
        let array = try! PropertyListSerialization.data(fromPropertyList: [1, 2], format: .binary, options: 0)
        #expect(throws: ImportError.self) { try SafariBookmarksImporter().parse(array) }
    }

    @Test func unreadableFileIsFullDiskAccessError() throws {
        let dir = ImportFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "Bookmarks.plist")
        try ImportFixtures.safariPlist().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        #expect(throws: ImportError.needsFullDiskAccess(file)) { try SafariBookmarksImporter().load(from: file) }
        #expect(ImportSources.probe(file) == .blocked)
    }

    @Test func missingFileIsNotFound() {
        let file = URL(filePath: "/nonexistent-\(UUID().uuidString)/Bookmarks.plist")
        #expect(throws: ImportError.notFound(file)) { try SafariBookmarksImporter().load(from: file) }
    }
}

// MARK: - Detection

@Suite struct ImportSourcesTests {
    @Test func detectsFilesUnderHome() throws {
        let home = ImportFixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appending(path: "Library/Application Support")
        func put(_ rel: String, _ data: Data) throws {
            let url = support.appending(path: rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let chrome = Data(ImportFixtures.chromeBookmarks.utf8)
        try put("Arc/StorableSidebar.json", Data(ImportFixtures.arcSidebar.utf8))
        try put("Google/Chrome/Profile 10/Bookmarks", chrome)
        try put("Google/Chrome/Profile 2/Bookmarks", chrome)
        try put("Google/Chrome/Default/Bookmarks", chrome)
        try put("Google/Chrome/System Profile/Bookmarks", chrome)
        try put("BraveSoftware/Brave-Browser/Default/Preferences", Data()) // no Bookmarks
        try put("com.operasoftware.Opera/Bookmarks", chrome)

        let found = ImportSources.detect(home: home)
        #expect(found.map(\.kind) == [
            .arcSidebar,
            .chromiumBookmarks(browser: "Google Chrome", profile: "Default"),
            .chromiumBookmarks(browser: "Google Chrome", profile: "Profile 2"),
            .chromiumBookmarks(browser: "Google Chrome", profile: "Profile 10"),
            .chromiumBookmarks(browser: "Opera", profile: "Default"),
        ])
        #expect(found.allSatisfy { $0.status == .readable })
        #expect(try found[0].load().spaces.count == 3)
        #expect(try found[1].load().bookmarks.count == 6)
    }

    @Test func detectOnThisMacDoesNotCrash() {
        _ = ImportSources.detect()
    }
}

// MARK: - Apply

@Suite @MainActor struct ImportApplyTests {
    let arcPlan = try! ArcImporter(options: .init(includeUnpinned: true)).parse(Data(ImportFixtures.arcSidebar.utf8))

    @Test func arcPlanCreatesSpacesReusingEmptyDefault() {
        let store = BrowserStore()
        let defaultID = store.currentSpaceID
        let summary = store.apply(arcPlan, newProfilesPerSpace: false)

        #expect(store.spaces.count == 3)
        #expect(summary.reusedSpaceID == defaultID)
        #expect(summary.createdSpaceIDs.count == 2)
        #expect(store.spaces[0].name == "Personal")  // renamed from the plan (Arc's first space is also "Personal")
        #expect(store.spaces.map(\.name).suffix(2) == ["Work", "Space 3"])
        #expect(store.profiles.count == 1)
        #expect(store.currentSpaceID == defaultID)

        let personal = store.spaces[0]
        #expect(personal.favorites.compactMap { store.tabs[$0]?.title } == ["Inbox (3)", "Google Calendar"])
        // calendar.google.com/ (favorite) and calendar.google.com (pinned) dedupe.
        #expect(personal.pinned.count == 5)
        let pinnedHosts: [String] = personal.pinned.compactMap { store.tabs[$0]?.url?.host() }
        #expect(!pinnedHosts.contains("calendar.google.com"))
        #expect(personal.today.compactMap { store.tabs[$0]?.title } == ["Arc - Wikipedia", "B"])
        #expect(personal.selected == nil)
        #expect(summary.duplicatesSkipped == 1)

        #expect(store.tabs.values.allSatisfy { $0.isSleeping })
        #expect(store.tabs.values.allSatisfy { $0.interactionState == nil })
        for space in store.spaces {
            for id in space.favorites { #expect(store.tabs[id]?.tier == .favorite) }
            for id in space.pinned { #expect(store.tabs[id]?.tier == .pinned) }
        }
        #expect(summary.tabsAdded == store.tabs.count)
    }

    @Test func newProfilesPerSpace() {
        let store = BrowserStore()
        store.apply(arcPlan, newProfilesPerSpace: true)
        #expect(store.profiles.count == 3)
        #expect(Set(store.spaces.map(\.profileID)).count == 3)
    }

    @Test func doesNotReuseNonEmptyOrMultipleSpaces() {
        let store = BrowserStore()
        store.openTab(URL(string: "https://github.com"))
        let summary = store.apply(arcPlan, newProfilesPerSpace: false)
        #expect(summary.reusedSpaceID == nil)
        #expect(store.spaces.count == 4)
        #expect(summary.pendingRenames.isEmpty)
    }

    @Test func dedupesAgainstExistingTabsWhenReusing() {
        let store = BrowserStore()
        let summary = store.apply(ImportPlan(spaces: [PlannedSpace(name: "A", hue: 0.1, pinned: [
            PlannedTab(title: "1", url: URL(string: "https://Example.com/x#frag")!),
            PlannedTab(title: "2", url: URL(string: "https://example.com/x/")!),
        ])]), newProfilesPerSpace: false)
        #expect(summary.pinnedAdded == 1)
        let again = store.apply(ImportPlan(spaces: [PlannedSpace(name: "B", hue: 0.2, pinned: [
            PlannedTab(title: "3", url: URL(string: "https://example.com/x")!),
        ])]), newProfilesPerSpace: false)
        #expect(again.reusedSpaceID == nil) // first space is no longer empty
        #expect(again.pinnedAdded == 1)     // separate space: no cross-space dedup
    }

    @Test func bookmarksBecomeImportedBookmarksSpaceWithCaps() throws {
        var bookmarks: [ImportedBookmark] = (0..<12).map {
            ImportedBookmark(title: "Bar \($0)", url: URL(string: "https://bar\($0).example/")!, folderPath: ["Bookmarks bar"], root: .bar)
        }
        bookmarks += (0..<250).map {
            ImportedBookmark(title: "Other \($0)", url: URL(string: "https://other.example/\($0)")!, folderPath: ["Other bookmarks", "F"], root: .other)
        }
        bookmarks.append(bookmarks[0]) // duplicate
        let store = BrowserStore()
        store.openTab(URL(string: "https://keep.example"))
        let summary = store.apply(ImportPlan(bookmarks: bookmarks), newProfilesPerSpace: false)

        let space = try #require(store.spaces.last)
        #expect(space.name == ImportPolicy.bookmarksSpaceName)
        #expect(space.favorites.count == ImportPolicy.favoritesLimit)
        #expect(space.pinned.count == ImportPolicy.pinnedLimit)
        #expect(store.tabs[space.pinned[0]]?.title == "Bar 8")
        #expect(summary.duplicatesSkipped == 1)
        #expect(summary.overCapSkipped == 12 + 250 - 8 - 200)
        #expect(summary.warnings.contains { $0.contains("200") })
        #expect(space.allTabs.allSatisfy { store.tabs[$0]?.isSleeping == true })
    }

    @Test func combinedPlanFromRealFixtures() throws {
        let chrome = try ChromeBookmarksImporter().parse(Data(ImportFixtures.chromeBookmarks.utf8))
        let safari = try SafariBookmarksImporter().parse(ImportFixtures.safariPlist())
        let plan = arcPlan.merged(with: chrome).merged(with: safari)
        let store = BrowserStore()
        let summary = store.apply(plan, newProfilesPerSpace: false)
        #expect(store.spaces.map(\.name).last == "Imported Bookmarks")
        let bookmarksSpace = try #require(store.spaces.last)
        // Top-level bar items from both browsers: GitHub, HN (Chrome), Apple (Safari).
        #expect(bookmarksSpace.favorites.compactMap { store.tabs[$0]?.title } == ["GitHub", "HN", "Apple"])
        #expect(bookmarksSpace.pinned.count == 4 + 2)
        #expect(summary.warnings.count >= plan.warnings.count)
    }

    @Test func emptyPlanIsNoOp() {
        let store = BrowserStore()
        let summary = store.apply(ImportPlan(), newProfilesPerSpace: true)
        #expect(summary == ImportSummary())
        #expect(store.spaces.count == 1 && store.profiles.count == 1)
    }
}
