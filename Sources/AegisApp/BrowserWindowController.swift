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
    private let library = LibraryController()
    private lazy var reader = ReaderView()
    private var readerFor: TabID?
    private var shownTab: TabID?
    private var refreshScheduled = false
    private var findBar: FindBar?
    private let topBar = TopTabBar()
    private let background = ThemeBackgroundView()
    private var cardTrailing: NSLayoutConstraint!
    private var lastSpaceID: UUID?
    private var warmWork: DispatchWorkItem?
    private var cardBottom: NSLayoutConstraint!
    private var extensionButtons: [String: NSButton] = [:]
    lazy var extensionWindow: ExtensionWindowAdapter = app.extensions.windowAdapter(for: self) { [unowned self] in
        ExtensionWindowAdapter(window: window!,
            tabs: { [unowned self] in store.currentSpace.allTabs.compactMap { runtime.tab($0) }.map { app.extensionTab($0) } },
            activeTab: { [unowned self] in store.currentSpace.selected.flatMap { runtime.tab($0) }.map { app.extensionTab($0) } },
            isPrivate: app.privateProfiles.contains(store.currentSpace.profileID))
    }
    private var sideItem: NSSplitViewItem!
    private var cardTopToContainer: NSLayoutConstraint!
    private var cardTopToBar: NSLayoutConstraint!
    /// Vertical sidebar (default) or tabs on top.
    var tabsOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: "tabsOnTop") }
        set { UserDefaults.standard.set(newValue, forKey: "tabsOnTop"); applyTabLayout(animated: true) }
    }

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
        let sideItem = NSSplitViewItem(viewController: sidebar)
        self.sideItem = sideItem
        sideItem.minimumThickness = Tokens.Size.sidebarMin
        sideItem.maximumThickness = Tokens.Size.sidebarMax
        sideItem.canCollapse = true
        sideItem.holdingPriority = .init(260)

        let contentVC = NSViewController()
        let container = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(card)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.delegate = self
        container.addSubview(topBar)
        let inset = Tokens.Space.cardInset
        cardTrailing = card.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset)
        cardBottom = card.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 0),
            cardTrailing, cardBottom,
            topBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: container.topAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 40),
        ])
        cardTopToContainer = card.topAnchor.constraint(equalTo: container.topAnchor, constant: inset)
        cardTopToBar = card.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 0)
        contentVC.view = container
        let contentItem = NSSplitViewItem(viewController: contentVC)
        contentItem.minimumThickness = 400

        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(contentItem)
        split.splitView.autosaveName = "AegisSplit"
        // A plain root view holds the split view, so overlays (palette,
        // banners, toasts) added to contentView sit above it instead of
        // becoming split panes.
        let root = NSViewController()
        root.view = NSView()
        background.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            background.topAnchor.constraint(equalTo: root.view.topAnchor),
            background.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
        ])
        root.addChild(split)
        split.view.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(split.view)
        NSLayoutConstraint.activate([
            split.view.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            split.view.topAnchor.constraint(equalTo: root.view.topAnchor),
            split.view.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
        ])
        window.contentViewController = root
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

        split.splitView.dividerStyle = .thin
        applyTheme(animated: false)
        observeStore()
        app.extensions.didOpen(window: extensionWindow)
        applyTabLayout(animated: false)
        refreshExtensionButtons()
        refresh()
    }

    private func applyTabLayout(animated: Bool) {
        let top = tabsOnTop
        cardTopToContainer.isActive = !top
        cardTopToBar.isActive = top
        topBar.isHidden = !top
        if animated { sideItem.animator().isCollapsed = top } else { sideItem.isCollapsed = top }
        // Inset the card on the left too when there's no sidebar beside it.
        card.superview.flatMap { container in
            container.constraints.first { $0.firstItem === card && $0.firstAttribute == .leading }
        }?.constant = top ? CGFloat(app.appearance.cardInset) : 0
        refresh()
    }

    /// Appearance settings → card radius and inset, background on/off, then a refresh.
    func applyTheme(animated: Bool) {
        let a = app.appearance
        let inset = CGFloat(a.cardInset)
        cardTrailing?.constant = -inset
        cardBottom?.constant = -inset
        cardTopToContainer?.constant = inset
        card.setCornerRadius(CGFloat(a.cornerRadius))
        background.enabled = a.tintWindow
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
        s.blockerOn = app.privacy.blockContent
        func row(_ id: TabID) -> SidebarState.Row? {
            guard let t = store.tabs[id] else { return nil }
            let w = runtime.existingTab(id)
            let awake = w?.isAwake ?? false
            let liveTitle = awake ? (w?.title ?? "") : ""
            return SidebarState.Row(
                id: id,
                title: liveTitle.isEmpty ? t.displayTitle : liveTitle,
                url: awake ? (w?.url ?? t.url) : t.url,
                sleeping: t.isSleeping || !awake,
                loading: w?.isLoading ?? false,
                playing: t.activity.contains(.playingMedia))
        }
        s.pages = store.spaces.map { sp in
            var page = SidebarState.Page(id: sp.id, name: sp.name, theme: sp.resolvedTheme)
            page.favorites = sp.favorites.compactMap(row)
            page.pinned = sp.pinned.compactMap(row)
            page.today = sp.today.compactMap(row)
            page.selected = sp.selected
            return page
        }
        s.currentIndex = store.spaces.firstIndex { $0.id == space.id } ?? 0
        s.activeDownloads = DownloadCenter.shared.active.count
        s.nowPlaying = nowPlaying()

        // Text reads dark or light depending on the gradient behind it.
        let a = app.appearance
        var style = SidebarStyle()
        style.tinted = a.tintWindow
        style.onDark = a.tintWindow
            ? background.middle(of: space.resolvedTheme).luminance < 0.36
            : window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        style.fontSize = CGFloat(a.fontSize)
        style.rowHeight = CGFloat(a.rowHeight)
        style.hue = space.accentHue
        s.style = style

        if let live {
            s.host = live.url?.host() ?? store.selectedTab?.url?.host() ?? ""
            s.isSecure = live.url?.scheme == "https" ? live.isSecure || live.url != nil : (live.url == nil)
            s.canGoBack = live.canGoBack
            s.canGoForward = live.canGoForward
            s.isLoading = live.isLoading
            card.setProgress(live.progress, loading: live.isLoading, hue: space.accentHue)
            if !live.isLoading && live.progress >= 1 { card.dismissSnapshot() }
        }
        background.set(themes: store.spaces.map(\.resolvedTheme), current: s.currentIndex, keepingAnimation: true)
        topBar.appearance = sidebar.view.appearance
        sidebar.apply(s)
        if tabsOnTop { topBar.apply(s) }
        showSelected()
        if space.id != lastSpaceID {
            lastSpaceID = space.id
            warmNeighbourSpaces()
        }
        window?.title = store.selectedTab?.displayTitle ?? "Aegis"
    }

    /// After a space switch settles, quietly wake the neighbouring spaces'
    /// selected tabs off screen. Building a web view costs 30–60 ms; doing it
    /// here means the next swipe or ⌥⌘[ / ] never builds one mid-animation.
    private func warmNeighbourSpaces() {
        warmWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let i = self.store.spaces.firstIndex(where: { $0.id == self.store.currentSpaceID }) else { return }
            for n in [i + 1, i - 1] where self.store.spaces.indices.contains(n) {
                guard let id = self.store.spaces[n].selected, let tab = self.store.tabs[id],
                      self.runtime.existingTab(id)?.isAwake != true else { continue }
                _ = tab
                self.runtime.show(id)
            }
        }
        warmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// The most relevant background media: playing first, else paused.
    private func nowPlaying() -> NowPlaying? {
        let selected = store.currentSpace.selected
        var best: (TabID, WebTab)?
        for space in store.spaces {
            for id in space.allTabs where id != selected {
                guard let t = runtime.tab(id), t.isAwake, t.mediaState != .none else { continue }
                if t.mediaState == .playing { best = (id, t); break }
                if best == nil { best = (id, t) }
            }
            if best?.1.mediaState == .playing { break }
        }
        guard let (id, t) = best else { return nil }
        var title = t.title.isEmpty ? (store.tabs[id]?.displayTitle ?? "") : t.title
        if title == t.url?.host(), let file = t.url?.lastPathComponent, !file.isEmpty, file != "/" { title = file.removingPercentEncoding ?? file }
        return NowPlaying(tab: id, title: title, url: t.url, playing: t.mediaState == .playing, hasVideo: t.hasVideo)
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
            let spaceChanged = shownTab.map { store.space(containing: $0)?.id != store.currentSpaceID } ?? false
            card.show(view, snapshot: snapshot, crossfade: spaceChanged)
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
    var debugSidebar: SidebarViewController { sidebar }

    func navigate(to url: URL, newTab: Bool, background: Bool = false, typed: Bool = true) {
        if palette.isOpen { palette.dismiss() }
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
        let previous = store.currentSpace.selected.flatMap { runtime.tab($0) }
        store.select(id)
        if let tab = runtime.tab(id) {
            app.extensions.didActivate(tab: app.extensionTab(tab), previous: previous.map(app.extensionTab))
        }
        refreshExtensionButtons()
    }

    func closeCurrentTab() {
        if palette.isOpen { palette.dismiss(); return }
        guard let id = store.selectedTab?.id else { window?.performClose(nil); return }
        closeTab(id)
    }

    func closeTab(_ id: TabID) {
        if let w = runtime.tab(id), let state = w.interactionState { store.update(id) { $0.interactionState = state } }
        if let w = runtime.tab(id) { app.extensions.webTabDidClose(w) }
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
        if tabsOnTop { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Tokens.Motion.duration(Tokens.Motion.sidebarToggle)
            ctx.allowsImplicitAnimation = true
            sideItem.animator().isCollapsed.toggle()
        }
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
        let hues = [0.48, 0.60, 0.08, 0.92, 0.33, 0.68]
        sidebar.cacheCurrentSpaceSnapshot()
        let space = store.addSpace(name: "Space \(store.spaces.count + 1)", accentHue: hues[store.spaces.count % hues.count], newProfile: true)
        store.currentSpaceID = space.id
        // Ask for a name right away, like Arc; Esc keeps the default.
        DispatchQueue.main.async { [weak self] in
            if !CommandLine.arguments.contains("--snapshot") { self?.renameSpace() }
        }
    }

    func switchSpace(_ delta: Int) {
        exitReader()
        sidebar.cacheCurrentSpaceSnapshot()
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
        app.extensions.didClose(window: extensionWindow, owner: self)
        app.windowClosed(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        app.extensions.didFocus(window: extensionWindow)
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
        sidebar.cacheCurrentSpaceSnapshot()
        store.currentSpaceID = store.spaces[index].id
    }

    /// Background media if any, else the current tab.
    func toggleMediaAnywhere() {
        if let id = nowPlaying()?.tab ?? store.selectedTab?.id { runtime.tab(id)?.togglePlayback() }
    }
    func pictureInPictureAnywhere() {
        if let id = nowPlaying()?.tab ?? store.selectedTab?.id { runtime.tab(id)?.togglePictureInPicture() }
    }

    func sidebarSpaceMenu() -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Rename Space…") { [weak self] in self?.renameSpace() })
        let colors = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (name, hue) in BrowserWindowController.spaceColors {
            let item = ClosureMenuItem(title: name) { [weak self] in
                guard let self else { return }
                self.store.renameSpace(self.store.currentSpaceID, name: self.store.currentSpace.name, accentHue: hue)
            }
            item.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
                Tokens.accent(hue: hue).setFill(); NSBezierPath(ovalIn: r).fill(); return true
            }
            item.state = abs(store.currentSpace.accentHue - hue) < 0.01 ? .on : .off
            sub.addItem(item)
        }
        colors.submenu = sub
        menu.addItem(colors)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "New Space") { [weak self] in self?.newSpace() })
        if store.spaces.count > 1 {
            menu.addItem(ClosureMenuItem(title: "Delete “\(store.currentSpace.name)”…") { [weak self] in self?.deleteSpace() })
        }
        return menu
    }

    static let spaceColors: [(String, Double)] = [("Teal", 0.48), ("Blue", 0.60), ("Indigo", 0.68), ("Pink", 0.92), ("Red", 0.0), ("Orange", 0.08), ("Yellow", 0.13), ("Green", 0.33), ("Graphite", 0.55)]

    func renameSpace() {
        let alert = NSAlert()
        alert.messageText = "Rename Space"
        let field = NSTextField(string: store.currentSpace.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard let window, alert.runModal() == .alertFirstButtonReturn else { return }
        _ = window
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { store.renameSpace(store.currentSpaceID, name: name) }
    }

    func deleteSpace() {
        let space = store.currentSpace
        let alert = NSAlert()
        alert.messageText = "Delete “\(space.name)”?"
        alert.informativeText = "Closes its \(space.allTabs.count) tabs and deletes the space's cookies and website data."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let profile = store.profile(for: space)
        let sharedProfile = store.spaces.filter { $0.profileID == profile.id }.count > 1
        for id in space.allTabs { runtime.discard(id) }
        store.removeSpace(space.id)
        if !sharedProfile {
            let context = runtime.context(for: profile)
            Task { await context.clearData() }
        }
    }

    func sidebarToggleMedia(_ id: TabID) { runtime.tab(id)?.togglePlayback() }
    func sidebarPictureInPicture(_ id: TabID) { runtime.tab(id)?.togglePictureInPicture() }
    func sidebarOpenLibrary(from view: NSView) { openLibrary(from: view) }

    func sidebarSwipeProgress(from: Int, to: Int, fraction: Double) {
        if fraction < 0 { background.animate(to: to) } else { background.blend(from: from, to: to, fraction: fraction) }
    }

    func sidebarWillSwipe(toSpace index: Int) {
        // Wake the target space's tab now (off screen), so its page is already
        // painted when the swipe lands instead of loading after.
        guard store.spaces.indices.contains(index), let id = store.spaces[index].selected else { return }
        runtime.show(id)
    }

    func openLibrary(from view: NSView? = nil, tab: LibraryModel.Tab? = nil) {
        library.model.accentHue = store.currentSpace.accentHue
        library.model.items = DownloadCenter.shared.items.map(ChromeUI.LibraryItem.init)
        guard let anchor = view ?? sidebar.view.window.flatMap({ _ in sidebar.view }) else { return }
        library.toggle(relativeTo: anchor, actions: self, tab: tab)
    }

    func refreshLibrary() {
        library.model.items = DownloadCenter.shared.items.map(ChromeUI.LibraryItem.init)
        scheduleRefresh()
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

// MARK: - Library

extension ChromeUI.LibraryItem {
    init(_ d: DownloadCenter.Item) {
        self.init(id: d.id, name: d.filename, file: d.destination, source: d.sourceURL, date: d.started,
                  bytes: d.totalBytes, progress: d.finished || d.failed ? nil : d.fractionCompleted,
                  failed: d.failed, isMedia: d.isMedia, exists: d.fileExists)
    }
}

extension BrowserWindowController: LibraryActions {
    func libraryOpen(_ item: ChromeUI.LibraryItem) {
        if let file = item.file { NSWorkspace.shared.open(file) }
    }
    func libraryOpenInTab(_ item: ChromeUI.LibraryItem) {
        guard let file = item.file else { return }
        let id = store.openTab(file)
        runtime.show(id)
        runtime.tab(id)?.webView?.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
    }
    func libraryReveal(_ item: ChromeUI.LibraryItem) {
        if let file = item.file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }
    func libraryRemove(_ item: ChromeUI.LibraryItem) {
        DownloadCenter.shared.remove(item.id)
        refreshLibrary()
    }
    func libraryClearFinished() {
        DownloadCenter.shared.clearFinished()
        refreshLibrary()
    }
}

// MARK: - Extension toolbar buttons

extension BrowserWindowController {
    func extensionButton(for id: String) -> NSButton? { extensionButtons[id] }

    func refreshExtensionButtons() {
        let current = store.currentSpace.selected.flatMap { runtime.tab($0) }.map(app.extensionTab)
        var buttons: [NSButton] = []
        var map: [String: NSButton] = [:]
        for record in app.extensions.extensions where record.enabled && app.extensions.context(for: record.id)?.isLoaded == true {
            let action = app.extensions.action(for: record.id, tab: current)
            let button = extensionButtons[record.id] ?? ActionButton(title: "") { [weak self] in
                guard let self else { return }
                let tab = self.store.currentSpace.selected.flatMap { self.runtime.tab($0) }.map(self.app.extensionTab)
                self.app.extensions.performAction(for: record.id, tab: tab)
            }
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.image = action?.icon(for: CGSize(width: 16, height: 16)) ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
            let badge = action?.badgeText ?? ""
            button.toolTip = (action?.label ?? record.name) + (badge.isEmpty ? "" : " (\(badge))")
            button.setAccessibilityLabel(record.name)
            if !button.constraints.contains(where: { $0.firstAttribute == .width }) {
                button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            }
            map[record.id] = button
            buttons.append(button)
        }
        extensionButtons = map
        sidebar.setExtensionButtons(buttons)
    }
}
