import Foundation
import Testing
import BrowserCore
@testable import Search

@Suite struct PaletteIntegrationTests {
    @Test func tabMatchBeatsUnrelatedCommands() {
        let engine = PaletteEngine(history: nil)
        let tab = PaletteItem(id: TabID(), title: "What is Ownership? - The Rust Programming Language", url: URL(string: "https://doc.rust-lang.org/book/ch04-01-what-is-ownership.html"))
        let cmds = [PaletteCommand(id: "newTab", title: "New Tab", shortcut: "⌘T", icon: "plus"),
                    PaletteCommand(id: "closeTab", title: "Close Tab", shortcut: "⌘W", icon: "xmark")]
        let results = engine.quickResults(PaletteQuery(text: "own", tabs: [tab], commands: cmds))
        print(results.map { "\($0.section) \($0.title)" })
        #expect(results.first?.tabID == tab.id)
        #expect(!results.contains { $0.commandID == "newTab" })
    }
}
