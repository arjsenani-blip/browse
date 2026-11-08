import AppKit
import WebKit
import Observation
import BrowserCore
import WebEngine
import ChromeUI

/// One browser window: sidebar + content card, bound to the shared store.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    let app: AppServices
    var store: BrowserStore { app.store }
    var runtime: TabRuntime { app.runtime }

    private let split = NSSplitViewController()
    private let sidebar = SidebarViewController()
    private let card = ContentCard()
    private let palette = PaletteController()
    private lazy var reader = ReaderView()
    private var readerFor: TabID?
    private var shownTab: TabID?
    private var refreshScheduled = false
    private var findBar: FindBar?

    enum PaletteMode { case newTab, navigate, command }

    init(app: AppServices) {
        self.app = app
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.setFrameAutosaveName("AegisMainWindow")
        window.minSize = NSSize(width: 640, height: 420)
        window.tabbingMode = .disallowed
        window.title = "Aegis"
        super.init(window: window)
        window.delegate = self

        sidebar.delegate = self
        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = Tokens.Size.sidebarMin
        sideItem.maximumThickness = Tokens.Size.sidebarMax
        sideItem.canCollapse = true
        sideItem.allowsFullHeightLayout = true

        let contentVC = NSViewController()
        let container = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(card)
        let inset = Tokens.Space.cardInset
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 0),
            card.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            card.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            card.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
        ])
        contentVC.view = container
        let contentItem = NSSplitViewItem(viewController: contentVC)
        contentItem.minimumThickness = 400

        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(contentItem)
        split.splitView.autosaveName = "AegisSplit"
        window.contentViewController = split
        // The split view sizes the window to its fitting size; restore ours.
        if !window.setFrameUsingName("AegisMainWindow") || window.frame.width < 900 {
            let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let size = NSSize(width: min(1320, screen.width * 0.86), height: min(860, screen.height * 0.88))
            window.setFrame(NSRect(origin: .zero, size: size), display: false)
            window.center()
        }
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames AegisSplit") == nil {
            split.splitView.setPosition(Tokens.Size.sidebarDefault, ofDividerAt: 0)
        }

        observeStore()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Store → UI

    private func observeStore() {
        withObservationTracking {
            _ = store.spaces
            _ = store.tabs
            _ = store.currentSpaceID
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleRefresh()
                self?.observeStore()
            }
        }
    }

    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    func refresh() {
        let space = store.currentSpace
        let live = store.selectedTab.flatMap { runtime.tab($0.id) }
        var s = SidebarState()
        s.spaceName = space.name
        s.spaceIndex = store.spaces.firstIndex { $0.id == space.id } ?? 0
        s.spaceCount = store.spaces.count
        s.accentHue = space.accentHue
        s.selected = space.selected
        s.blockerOn = app.privacy.blockContent
        func row(_ id: TabID) -> SidebarState.Row? {
            guard let t = store.tabs[id] else { return nil }
            let w = runtime.tab(id)
            let awake = w?.isAwake ?? false
            return SidebarState.Row(
                id: id,
                title: awake && !(w?.title.isEmpty ?? true) ? w!.title : t.displayTitle,
                url: awake ? (w?.url ?? t.url) : t.url,
                sleeping: t.isSleeping || !awake,
                loading: w?.isLoading ?? false,
                playing: t.activity.contains(.playingMedia))
        }
        s.favorites = space.favorites.compactMap(row)
        s.pinned = space.pinned.compactMap(row)
        s.today = space.today.compactMap(row)
        if let live {
            s.host = live.url?.host() ?? store.selectedTab?.url?.host() ?? ""
            s.isSecure = live.url?.scheme == "https" ? live.isSecure || live.url != nil : (live.url == nil)
            s.canGoBack = live.canGoBack
            s.canGoForward = live.canGoForward
            s.isLoading = live.isLoading
            card.setProgress(live.progress, loading: live.isLoading, hue: space.accentHue)
            if !live.isLoading && live.progress >= 1 { card.dismissSnapshot() }
        }
        sidebar.apply(s)
        showSelected()
        window?.title = store.selectedTab?.displayTitle ?? "Aegis"
    }

    private func showSelected() {
        guard let id = store.currentSpace.selected, store.tabs[id] != nil else {
            card.show(nil)
            shownTab = nil
            runtime.foreground = []
            return
        }
        if readerFor == id { return }
        let wasSleeping = store.tabs[id]?.isSleeping ?? false
        let snapshot = wasSleeping ? runtime.tab(id)?.snapshot : nil
        guard let view = runtime.show(id) else { return }
        if shownTab != id || card.current !== view {
            card.show(view, snapshot: snapshot)
            shownTab = id
            runtime.foreground = [id]
            if findBar != nil { closeFind() }
        }
    }

    // MARK: Actions (menu + keyboard)

    func openPalette(_ mode: PaletteMode) {
        guard let window else { return }
        let source = app.paletteSource(for: self, mode: mode)
        var initial = ""
        if mode == .navigate { initial = store.selectedTab.flatMap { runtime.tab($0.id)?.url?.absoluteString } ?? "" }
        if mode == .command { initial = ">" }
        palette.model.placeholder = mode == .newTab ? "Search or enter address" : "Search tabs, history, or type a command"
        palette.show(in: window, over: card, dataSource: source, initialText: initial, hue: store.currentSpace.accentHue)
    }

    func debugSetPaletteQuery(_ q: String) { palette.model.query = q }

    func navigate(to url: URL, newTab: Bool, background: Bool = false, typed: Bool = true) {
        if newTab || store.selectedTab == nil {
            let id = store.openTab(url, select: !background)
            if !background { runtime.tab(id)?.load(url, typed: typed) }
        } else if let id = store.selectedTab?.id {
            exitReader()
            runtime.show(id)
            runtime.tab(id)?.load(url, typed: typed)
        }
        refresh()
    }

    func select(_ id: TabID) {
        exitReader()
        store.select(id)
    }

    func closeCurrentTab() {
        if palette.isOpen { palette.dismiss(); return }
        guard let id = store.selectedTab?.id else { window?.performClose(nil); return }
        closeTab(id)
    }

    func closeTab(_ id: TabID) {
        if let w = runtime.tab(id), let state = w.interactionState { store.update(id) { $0.interactionState = state } }
        runtime.discard(id)
        if readerFor == id { readerFor = nil }
        store.close(id)
    }

    func reopenClosedTab() {
        if let id = store.reopenClosed() { store.select(id) }
    }

    func selectTab(at index: Int) {
        let all = store.currentSpace.allTabs
        guard !all.isEmpty else { return }
        // ⌘9 always means the last tab, as elsewhere on macOS.
        let i = index == 8 ? all.count - 1 : index
        if all.indices.contains(i) { select(all[i]) }
    }

    func cycleTab(_ delta: Int) {
        let all = store.currentSpace.allTabs
        guard let current = store.currentSpace.selected, let i = all.firstIndex(of: current) else { return }
        select(all[(i + delta + all.count) % all.count])
    }

    func togglePin() {
        guard let tab = store.selectedTab else { return }
        store.move(tab.id, to: tab.tier == .today ? .pinned : .today)
    }

    func toggleFavorite() {
        guard let tab = store.selectedTab else { return }
        store.move(tab.id, to: tab.tier == .favorite ? .pinned : .favorite)
    }

    func copyURL() {
        guard let url = store.selectedTab.flatMap({ runtime.tab($0.id)?.url ?? $0.url }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        Toast.show("Copied link", in: window)
    }

    func toggleSidebar() {
        split.toggleSidebar(nil)
    }

    func toggleReader() {
        guard let id = store.selectedTab?.id, let tab = runtime.tab(id) else { return }
        if readerFor == id { exitReader(); return }
        Task {
            guard let article = await tab.extractArticle() else {
                Toast.show("Reader isn't available for this page", in: window)
                return
            }
            reader.show(title: article.title, byline: article.byline, site: article.site, html: article.html)
            readerFor = id
            card.show(reader)
        }
    }

    func cycleReaderTheme() {
        let all = ReaderView.Theme.allCases
        reader.theme = all[((all.firstIndex(of: reader.theme) ?? 0) + 1) % all.count]
    }

    private func exitReader() {
        guard readerFor != nil else { return }
        readerFor = nil
        shownTab = nil
        showSelected()
    }

    func hibernateCurrentSpaceBackground() {
        Task {
            for id in store.currentSpace.allTabs where id != store.currentSpace.selected {
                await runtime.sleep(id)
            }
            Toast.show("Background tabs are asleep", in: window)
        }
    }

    func newSpace() {
        let hues = [0.48, 0.60, 0.08, 0.92, 0.33, 0.75]
        let space = store.addSpace(name: "Space \(store.spaces.count + 1)", accentHue: hues[store.spaces.count % hues.count], newProfile: true)
        store.currentSpaceID = space.id
    }

    func switchSpace(_ delta: Int) {
        exitReader()
        store.switchSpace(by: delta)
    }

    // MARK: Find

    func showFind() {
        guard let webView = store.selectedTab.flatMap({ runtime.tab($0.id)?.webView }) else { return }
        if let findBar { findBar.focus(); return }
        let bar = FindBar(webView: webView)
        bar.onClose = { [weak self] in self?.closeFind() }
        bar.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
        ])
        findBar = bar
        bar.focus()
    }

    func closeFind() {
        findBar?.removeFromSuperview()
        findBar = nil
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        app.windowClosed(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let id = store.currentSpace.selected { runtime.foreground = [id] }
    }
}

// MARK: - Sidebar

extension BrowserWindowController: SidebarDelegate {
    func sidebarSelect(_ id: TabID) { select(id) }
    func sidebarClose(_ id: TabID) { closeTab(id) }
    func sidebarNewTab() { openPalette(.newTab) }
    func sidebarOpenPalette() { openPalette(.navigate) }
    func sidebarBack() { store.selectedTab.flatMap { runtime.tab($0.id) }?.goBack() }
    func sidebarForward() { store.selectedTab.flatMap { runtime.tab($0.id) }?.goForward() }
    func sidebarReload() {
        guard let t = store.selectedTab.flatMap({ runtime.tab($0.id) }) else { return }
        t.isLoading ? t.stop() : t.reload()
    }
    func sidebarMove(_ id: TabID, to tier: TabTier, index: Int) { store.move(id, to: tier, at: index) }
    func sidebarSwitchSpace(_ index: Int) {
        guard store.spaces.indices.contains(index) else { return }
        exitReader()
        store.currentSpaceID = store.spaces[index].id
    }

    func sidebarContextMenu(for id: TabID) -> NSMenu? {
        guard let tab = store.tabs[id] else { return nil }
        let menu = NSMenu()
        func item(_ title: String, _ action: @escaping () -> Void) {
            let i = ClosureMenuItem(title: title, action: action)
            menu.addItem(i)
        }
        item(tab.tier == .pinned ? "Unpin Tab" : "Pin Tab") { [weak self] in self?.store.move(id, to: tab.tier == .pinned ? .today : .pinned) }
        item(tab.tier == .favorite ? "Remove from Favorites" : "Add to Favorites") { [weak self] in self?.store.move(id, to: tab.tier == .favorite ? .pinned : .favorite) }
        item("Copy Link") {
            guard let url = tab.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        item("Put Tab to Sleep") { [weak self] in Task { await self?.runtime.sleep(id) } }
        if store.spaces.count > 1 {
            let move = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for space in store.spaces where space.id != store.space(containing: id)?.id {
                sub.addItem(ClosureMenuItem(title: space.name) { [weak self] in self?.app.move(id, toSpace: space.id) })
            }
            move.submenu = sub
            menu.addItem(move)
        }
        menu.addItem(.separator())
        item("Close Tab") { [weak self] in self?.closeTab(id) }
        return menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
