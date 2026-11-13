import Foundation
import Testing
@testable import BrowserCore

@Suite @MainActor struct DuplicateTabTests {
    @Test func duplicateLandsDirectlyBelowInToday() throws {
        let s = BrowserStore()
        let a = s.openTab(URL(string: "https://a.example"))
        let b = s.openTab(URL(string: "https://b.example"))   // today: [b, a]
        let c = try #require(s.duplicate(b))
        #expect(s.currentSpace.today == [b, c, a])
        #expect(s.tabs[c]?.url == URL(string: "https://b.example"))
        #expect(s.tabs[c]?.tier == .today)
        #expect(s.currentSpace.selected == c)
        _ = a
    }

    @Test func duplicateKeepsPinnedTier() throws {
        let s = BrowserStore()
        let a = s.openTab(URL(string: "https://a.example"), tier: .pinned)
        let b = s.openTab(URL(string: "https://b.example"), tier: .pinned)   // pinned: [a, b]
        let c = try #require(s.duplicate(a, select: false))
        #expect(s.currentSpace.pinned == [a, c, b])
        #expect(s.currentSpace.selected == b)
    }

    @Test func duplicateStaysInTheSameFolder() throws {
        let s = BrowserStore()
        let f = s.newFolder(in: s.currentSpaceID, name: "F")
        let a = s.openTab(URL(string: "https://a.example"))
        let b = s.openTab(URL(string: "https://b.example"))
        s.moveTab(a, toFolder: f)
        s.moveTab(b, toFolder: f)
        let c = try #require(s.duplicate(a))
        let folder = try #require(s.currentSpace.folders.first { $0.id == f })
        #expect(folder.tabs == [a, c, b])
        #expect(s.currentSpace.pinned.contains(c))
        #expect(s.space(containing: c)?.id == s.currentSpaceID)
    }

    @Test func duplicatingAMissingTabDoesNothing() {
        let s = BrowserStore()
        #expect(s.duplicate(TabID()) == nil)
    }
}
