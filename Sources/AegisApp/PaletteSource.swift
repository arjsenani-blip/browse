import AppKit
import BrowserCore
import ChromeUI
import Search

/// Adapts the Search engine to the palette UI, and performs the chosen row.
@MainActor
final class PaletteSource: PaletteDataSource {
    private unowned let services: AppServices
    private weak var controller: BrowserWindowController?
    private let mode: BrowserWindowController.PaletteMode
    private var lastResults: [String: PaletteResult] = [:]

    init(services: AppServices, controller: BrowserWindowController, mode: BrowserWindowController.PaletteMode) {
        self.services = services
        self.controller = controller
        self.mode = mode
    }

    static let commands: [PaletteCommand] = [
        PaletteCommand(id: "newTab", title: "New Tab", aliases: ["open"], shortcut: "⌘T", icon: "plus"),
        PaletteCommand(id: "closeTab", title: "Close Tab", aliases: ["quit tab"], shortcut: "⌘W", icon: "xmark"),
        PaletteCommand(id: "reopen", title: "Reopen Closed Tab", aliases: ["undo close", "restore"], shortcut: "⇧⌘T", icon: "arrow.uturn.backward"),
        PaletteCommand(id: "reader", title: "Open in Reader", aliases: ["reading", "article"], shortcut: "⇧⌘R", icon: "book"),
        PaletteCommand(id: "pin", title: "Pin or Unpin Tab", aliases: ["keep"], shortcut: "⇧⌘P", icon: "pin"),
        PaletteCommand(id: "favorite", title: "Add to Favorites", aliases: ["bookmark", "star"], shortcut: "⌘D", icon: "star"),
        PaletteCommand(id: "copyURL", title: "Copy Link", aliases: ["url", "share"], shortcut: "⇧⌘C", icon: "link"),
        PaletteCommand(id: "find", title: "Find on Page", aliases: ["search page"], shortcut: "⌘F", icon: "text.magnifyingglass"),
        PaletteCommand(id: "library", title: "Downloads and Media", aliases: ["downloads", "files", "library", "images"], shortcut: "⌥⌘J", icon: "tray.and.arrow.down"),
        PaletteCommand(id: "playPause", title: "Play or Pause Media", aliases: ["music", "video", "pause", "resume"], icon: "playpause"),
        PaletteCommand(id: "pip", title: "Picture in Picture", aliases: ["pip", "float video"], icon: "pip.enter"),
        PaletteCommand(id: "tabsOnTop", title: "Switch Tab Layout (Sidebar / Top)", aliases: ["horizontal tabs", "vertical tabs", "tab bar"], icon: "rectangle.topthird.inset.filled"),
        PaletteCommand(id: "sidebar", title: "Toggle Sidebar", aliases: ["hide sidebar", "focus"], shortcut: "⌘S", icon: "sidebar.left"),
        PaletteCommand(id: "sleep", title: "Put Background Tabs to Sleep", aliases: ["hibernate", "memory", "free"], shortcut: "⌥⌘H", icon: "moon.zzz"),
        PaletteCommand(id: "newSpace", title: "New Space", aliases: ["profile", "container"], shortcut: "⌥⌘N", icon: "square.stack.3d.up"),
        PaletteCommand(id: "renameSpace", title: "Rename Space", aliases: ["name space"], icon: "pencil"),
        PaletteCommand(id: "deleteSpace", title: "Delete Space", aliases: ["remove space"], icon: "trash"),
        PaletteCommand(id: "nextSpace", title: "Next Space", aliases: ["switch space"], shortcut: "⌥⌘]", icon: "arrow.right.square"),
        PaletteCommand(id: "private", title: "New Private Window", aliases: ["incognito"], shortcut: "⇧⌘N", icon: "eye.slash"),
        PaletteCommand(id: "blocking", title: "Toggle Content Blocking", aliases: ["ads", "adblock", "trackers", "shield"], icon: "shield"),
        PaletteCommand(id: "clearData", title: "Clear This Space's Website Data", aliases: ["cookies", "sign out"], icon: "trash"),
        PaletteCommand(id: "clearHistory", title: "Clear History", aliases: ["forget"], icon: "clock.arrow.circlepath"),
        PaletteCommand(id: "importPasswords", title: "Import Passwords", aliases: ["csv", "keychain", "passwords app"], icon: "key"),
        PaletteCommand(id: "updateFilters", title: "Update Filter Lists", aliases: ["easylist"], icon: "arrow.down.circle"),
        PaletteCommand(id: "addExtension", title: "Add Extension from Chrome Web Store…", aliases: ["extension", "chrome web store", "addon", "plugin"], icon: "puzzlepiece.extension"),
        PaletteCommand(id: "settings", title: "Settings", aliases: ["preferences"], shortcut: "⌘,", icon: "gear"),
        PaletteCommand(id: "defaultBrowser", title: "Make Default Browser", icon: "checkmark.seal"),
    ]

    private func query(_ text: String, deletion: Bool) -> PaletteQuery {
        let store = services.store
        let space = store.currentSpace
        func item(_ id: TabID) -> Search.PaletteItem? {
            guard let t = store.tabs[id] else { return nil }
            return Search.PaletteItem(id: id, title: t.displayTitle, url: t.url)
        }
        let tabs = store.spaces.flatMap { $0.pinned + $0.today }.compactMap(item)
        let favorites = space.favorites.compactMap(item)
        return PaletteQuery(text: text, tabs: mode == .newTab ? [] : tabs, bookmarks: favorites,
                            commands: Self.commands, lastEditWasDeletion: deletion)
    }

    /// "Coming from Arc?" (or Chrome/Safari on a brand-new install) until the user imports or dismisses it.
    /// Import sources found on this Mac, looked up once per launch.
    private static var detectedSources: [ImportSource]?

    func banner() -> PaletteBanner? {
        guard !UserDefaults.standard.bool(forKey: "importBannerDone") else { return nil }
        if Self.detectedSources == nil { Self.detectedSources = ImportSources.detect().filter { $0.status == .readable } }
        let sources = Self.detectedSources ?? []
        let action: @MainActor () -> Void = {
            (NSApp.delegate as? AppDelegate)?.importBrowserData()
        }
        if let arc = sources.first(where: { if case .arcSidebar = $0.kind { return true }; return false }),
           let plan = try? arc.load(arcOptions: .init()) {
            let favs = Set(plan.spaces.flatMap(\.favorites).map(\.url)).count
            let pinned = plan.spaces.reduce(0) { $0 + $1.pinned.count }
            return PaletteBanner(symbol: "arrow.down.to.line", title: "Coming from Arc?",
                                 subtitle: "Bring \(plan.spaces.count) space\(plan.spaces.count == 1 ? "" : "s"), \(favs) favorites and \(pinned) pinned tabs. Nothing loads until you open it.",
                                 actionTitle: "Import", action: action)
        }
        let isFresh = services.store.tabs.isEmpty
        if isFresh, let other = sources.first {
            return PaletteBanner(symbol: "arrow.down.to.line", title: "Bring your bookmarks",
                                 subtitle: "Import from \(other.displayName) into a space of its own.", actionTitle: "Import", action: action)
        }
        return nil
    }

    func quickResults(for query: String, lastEditWasDeletion: Bool) -> (items: [ChromeUI.PaletteItem], inline: String?) {
        convert(services.engine.quickResults(self.query(query, deletion: lastEditWasDeletion)))
    }

    func fullResults(for query: String, lastEditWasDeletion: Bool) async -> (items: [ChromeUI.PaletteItem], inline: String?) {
        let q = self.query(query, deletion: lastEditWasDeletion)
        return convert(await services.engine.fullResults(q))
    }

    private func convert(_ results: [PaletteResult]) -> (items: [ChromeUI.PaletteItem], inline: String?) {
        lastResults = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let items = results.map { r -> ChromeUI.PaletteItem in
            ChromeUI.PaletteItem(
                id: r.id,
                section: section(r.section),
                title: r.title,
                subtitle: r.subtitle ?? "",
                symbol: r.icon ?? symbol(for: r.section),
                shortcut: r.shortcut,
                highlights: utf16Ranges(r.titleMatches, in: r.title),
                url: r.url)
        }
        return (items, results.first?.inlineCompletion)
    }

    private func section(_ s: PaletteSection) -> ChromeUI.PaletteItem.Section {
        switch s {
        case .switchToTab: .switchToTab
        case .bookmarks: .bookmarks
        case .history: .history
        case .actions: .actions
        case .search: .search
        }
    }

    private func symbol(for s: PaletteSection) -> String {
        switch s {
        case .switchToTab: "square.on.square"
        case .bookmarks: "star"
        case .history: "clock"
        case .actions: "command"
        case .search: "magnifyingglass"
        }
    }

    /// Search reports UTF-8 byte ranges; the UI wants UTF-16 offsets.
    private func utf16Ranges(_ utf8: [Range<Int>], in text: String) -> [Range<Int>] {
        let bytes = text.utf8
        return utf8.compactMap { r in
            guard r.lowerBound >= 0, r.upperBound <= bytes.count else { return nil }
            let lo = bytes.index(bytes.startIndex, offsetBy: r.lowerBound)
            let hi = bytes.index(bytes.startIndex, offsetBy: r.upperBound)
            let a = text.utf16.distance(from: text.utf16.startIndex, to: lo)
            let b = text.utf16.distance(from: text.utf16.startIndex, to: hi)
            return a..<b
        }
    }

    func perform(_ item: ChromeUI.PaletteItem, query: String, modifiers: NSEvent.ModifierFlags) {
        guard let result = lastResults[item.id], let controller else { return }
        let newTab = mode == .newTab || modifiers.contains(.command)
        switch result.action {
        case .switchToTab(let id):
            controller.select(id)
        case .open(let url), .goTo(let url):
            if !query.isEmpty, let history = services.history {
                let input = query
                Task.detached { try? await history.recordInputChoice(input: input, url: url) }
            }
            controller.navigate(to: url, newTab: newTab, typed: true)
        case .search(let text, let url):
            if let url = url ?? URLInput.resolve(text) { controller.navigate(to: url, newTab: newTab, typed: true) }
        case .command(let id):
            run(id, controller)
        }
    }

    func submit(_ text: String, modifiers: NSEvent.ModifierFlags) {
        guard let url = URLInput.resolve(text) else { return }
        controller?.navigate(to: url, newTab: mode == .newTab || modifiers.contains(.command), typed: true)
    }

    private func run(_ id: String, _ c: BrowserWindowController) {
        let d = NSApp.delegate as? AppDelegate
        // Let the palette close before the command opens anything of its own.
        DispatchQueue.main.async {
            switch id {
            case "newTab": c.openPalette(.newTab)
            case "closeTab": c.closeCurrentTab()
            case "reopen": c.reopenClosedTab()
            case "reader": c.toggleReader()
            case "pin": c.togglePin()
            case "favorite": c.toggleFavorite()
            case "copyURL": c.copyURL()
            case "find": c.showFind()
            case "sidebar": c.toggleSidebar()
            case "tabsOnTop": d?.toggleTabsOnTop()
            case "library": c.openLibrary()
            case "playPause": c.toggleMediaAnywhere()
            case "pip": c.pictureInPictureAnywhere()
            case "sleep": c.hibernateCurrentSpaceBackground()
            case "newSpace": c.newSpace()
            case "nextSpace": c.switchSpace(1)
            case "renameSpace": c.renameSpace()
            case "deleteSpace": c.deleteSpace()
            case "private": d?.newPrivateWindow()
            case "blocking": d?.toggleBlocking()
            case "clearData": d?.clearSpaceData()
            case "clearHistory": d?.clearHistory()
            case "importPasswords": d?.importPasswords()
            case "updateFilters": d?.updateFilters()
            case "settings": d?.showSettings()
            case "addExtension": d?.addExtension()
            case "defaultBrowser": d?.makeDefaultBrowser()
            default: break
            }
        }
    }
}
