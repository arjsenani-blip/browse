import Foundation
import Testing
@testable import BrowserCore

/// Model-level coverage for nested folders (see docs/subfolders.md). The sidebar
/// still renders one level; these pin down the behaviour the UI will rely on.
@Suite @MainActor struct NestedFolderTests {
    private func folder(_ s: BrowserStore, _ id: UUID) -> Folder? { s.currentSpace.folders.first { $0.id == id } }
    private func ids(_ entries: [PinnedEntry]) -> [String] {
        entries.map { if case .folder(let f) = $0 { "F:\(f.name)" } else if case .tab(let t) = $0 { "T:\(t)" } else { "" } }
    }

    @Test func subfoldersNestAndAreListedInsideTheirParent() throws {
        let s = BrowserStore()
        let top = s.newFolder(in: s.currentSpaceID, name: "Top")
        let a = try #require(s.newSubfolder(in: top, name: "A"))
        let b = try #require(s.newSubfolder(in: top, name: "B"))   // new subfolders go first
        #expect(s.currentSpace.depth(of: a) == 1)
        #expect(s.currentSpace.subfolders(of: top).map(\.name) == ["B", "A"])
        #expect(s.currentSpace.subfolders(of: nil).map(\.name) == ["Top"])
        #expect(s.currentSpace.ancestors(of: a) == [top])
        #expect(Set(s.currentSpace.descendants(of: top)) == [a, b])
        // Subfolders never show at the top level of Pinned.
        #expect(ids(s.currentSpace.pinnedEntries) == ["F:Top"])
    }

    @Test func depthIsCappedAtFourLevels() throws {
        let s = BrowserStore()
        var parent = s.newFolder(in: s.currentSpaceID)
        for _ in 1..<Space.maxFolderDepth { parent = try #require(s.newSubfolder(in: parent)) }
        #expect(s.currentSpace.depth(of: parent) == Space.maxFolderDepth - 1)
        #expect(s.newSubfolder(in: parent) == nil)
    }

    @Test func entriesInterleaveTabsAndSubfoldersByPosition() throws {
        let s = BrowserStore()
        let top = s.newFolder(in: s.currentSpaceID, name: "Top")
        let t1 = s.openTab(URL(string: "https://1.com")), t2 = s.openTab(URL(string: "https://2.com"))
        s.moveTab(t1, toFolder: top); s.moveTab(t2, toFolder: top)
        let sub = try #require(s.newSubfolder(in: top, name: "Sub"))
        #expect(ids(s.currentSpace.entries(in: top)) == ["F:Sub", "T:\(t1)", "T:\(t2)"])
        #expect(s.moveFolder(sub, toParent: top, at: 2))
        #expect(ids(s.currentSpace.entries(in: top)) == ["T:\(t1)", "T:\(t2)", "F:Sub"])
        #expect(s.currentSpace.allTabs(inFolder: top) == [t1, t2])
    }

    @Test func moveRefusesCyclesAndOverDeepTrees() throws {
        let s = BrowserStore()
        let a = s.newFolder(in: s.currentSpaceID, name: "A")
        let b = try #require(s.newSubfolder(in: a, name: "B"))
        let c = try #require(s.newSubfolder(in: b, name: "C"))
        #expect(!s.moveFolder(a, toParent: a))          // into itself
        #expect(!s.moveFolder(a, toParent: c))          // into its own subtree
        // A tree three levels tall can't go under a folder that is already nested.
        let d = s.newFolder(in: s.currentSpaceID, name: "D")
        let e = try #require(s.newSubfolder(in: d, name: "E"))
        #expect(!s.moveFolder(a, toParent: e))
        #expect(s.moveFolder(a, toParent: d))            // depth 1 + height 2 = 3 < 4
        #expect(s.currentSpace.depth(of: c) == 3)
        #expect(folder(s, d)?.isExpanded == true)
    }

    @Test func moveFolderToTopLevelClosesTheOldGap() throws {
        let s = BrowserStore()
        let top = s.newFolder(in: s.currentSpaceID, name: "Top")
        let x = try #require(s.newSubfolder(in: top, name: "X"))
        let y = try #require(s.newSubfolder(in: top, name: "Y"))   // order: Y(0), X(1)
        #expect(s.moveFolder(y, toParent: nil, at: 0))
        #expect(folder(s, x)?.position == 0)
        #expect(s.currentSpace.subfolders(of: nil).map(\.name) == ["Y", "Top"])
        #expect(folder(s, y)?.parentID == nil)
    }

    @Test func deleteKeepingTabsHoistsChildrenIntoTheParent() throws {
        let s = BrowserStore()
        let top = s.newFolder(in: s.currentSpaceID, name: "Top")
        let mid = try #require(s.newSubfolder(in: top, name: "Mid"))
        let leaf = try #require(s.newSubfolder(in: mid, name: "Leaf"))
        let t = s.openTab(URL(string: "https://t.com")), u = s.openTab(URL(string: "https://u.com"))
        s.moveTab(t, toFolder: mid); s.moveTab(u, toFolder: leaf)
        #expect(s.deleteFolder(mid, closeTabs: false).isEmpty)
        #expect(folder(s, leaf)?.parentID == top)
        #expect(folder(s, top)?.tabs == [t])
        #expect(folder(s, leaf)?.tabs == [u])
        #expect(s.tabs[t] != nil && s.tabs[u] != nil)
    }

    @Test func deleteWithoutChildrenKeepsSiblingOrder() throws {
        // Top level: [F:A, F:B, T:p1]. Deleting A must leave B on top.
        let s = BrowserStore()
        let p1 = s.openTab(URL(string: "https://p1.com")); s.move(p1, to: .pinned)
        let b = s.newFolder(in: s.currentSpaceID, name: "B")
        let a = s.newFolder(in: s.currentSpaceID, name: "A")
        #expect(ids(s.currentSpace.pinnedEntries) == ["F:A", "F:B", "T:\(p1)"])
        s.deleteFolder(a, closeTabs: false)
        #expect(folder(s, b)?.position == 0)
        #expect(ids(s.currentSpace.pinnedEntries) == ["F:B", "T:\(p1)"])
    }

    @Test func deleteHoistingSeveralChildrenShiftsLaterSiblings() throws {
        let s = BrowserStore()
        let top = s.newFolder(in: s.currentSpaceID, name: "Top")
        let after = try #require(s.newSubfolder(in: top, name: "After"))
        let doomed = try #require(s.newSubfolder(in: top, name: "Doomed"))   // Doomed(0), After(1)
        _ = try #require(s.newSubfolder(in: doomed, name: "K2"))
        _ = try #require(s.newSubfolder(in: doomed, name: "K1"))             // K1(0), K2(1)
        s.deleteFolder(doomed, closeTabs: false)
        #expect(s.currentSpace.subfolders(of: top).map(\.name) == ["K1", "K2", "After"])
        #expect(folder(s, after)?.position == 2)
    }

    @Test func deleteClosingTabsRemovesTheWholeSubtree() throws {
        let s = BrowserStore()
        let top = s.newFolder(in: s.currentSpaceID, name: "Top")
        let sub = try #require(s.newSubfolder(in: top, name: "Sub"))
        let t = s.openTab(URL(string: "https://t.com")), u = s.openTab(URL(string: "https://u.com"))
        s.moveTab(t, toFolder: top); s.moveTab(u, toFolder: sub)
        #expect(Set(s.deleteFolder(top, closeTabs: true)) == [t, u])
        #expect(s.currentSpace.folders.isEmpty)
        #expect(s.tabs[t] == nil && s.tabs[u] == nil)
    }

    @Test func nestingSurvivesASessionRoundTripAndOldFoldersDecodeAsTopLevel() throws {
        let s = BrowserStore()
        let top = s.newFolder(in: s.currentSpaceID, name: "Top")
        let sub = try #require(s.newSubfolder(in: top, name: "Sub"))
        let data = try JSONEncoder().encode(s.snapshot())
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        #expect(decoded.spaces[0].folders.first { $0.id == sub }?.parentID == top)
        // Folders saved before nesting have no "parentID" key.
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var spaces = json["spaces"] as! [[String: Any]]
        spaces[0]["folderList"] = (spaces[0]["folderList"] as! [[String: Any]]).map { var f = $0; f.removeValue(forKey: "parentID"); return f }
        json["spaces"] = spaces
        let old = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.spaces[0].folders.allSatisfy { $0.parentID == nil })
    }

    @Test func brokenParentChainsDoNotHang() {
        var space = BrowserStore().currentSpace
        let a = UUID(), b = UUID()
        space.folders = [Folder(id: a, name: "A", parentID: b), Folder(id: b, name: "B", parentID: a)]
        #expect(space.ancestors(of: a).count <= 2)
        #expect(space.descendants(of: a).count <= 2)
    }
}
