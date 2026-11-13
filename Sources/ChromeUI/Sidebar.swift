import AppKit
import BrowserCore

/// What the sidebar draws, computed by the window controller from the store.
/// Every space is a page, so the swipe can show real neighbours side by side.
public struct SidebarState: Equatable {
    public struct Row: Equatable {
        public var id: TabID
        public var title: String
        public var url: URL?
        public var sleeping: Bool
        public var loading: Bool
        public var playing: Bool
        /// Set on the row that stands for a split view: every pane's tab, in pane order
        /// (the row's own `id` is the first). The other members get no row of their own.
        public var split: [Row]?
        public init(id: TabID, title: String, url: URL?, sleeping: Bool, loading: Bool, playing: Bool, split: [Row]? = nil) {
            self.id = id; self.title = title; self.url = url; self.sleeping = sleeping; self.loading = loading; self.playing = playing
            self.split = split
        }
        /// Every tab this row shows.
        public var members: [TabID] { split?.map(\.id) ?? [id] }
    }

    public struct Page: Equatable {
        public var id: UUID
        public var name: String
        public var theme: SpaceTheme
        public var icon: String = "house"
        /// Pinned section in display order: loose tabs and folders.
        public var pinnedEntries: [PinnedItem] = []
        public var favorites: [Row] = []
        public var pinned: [Row] = []
        public var today: [Row] = []
        public var selected: TabID?
        public init(id: UUID, name: String, theme: SpaceTheme) { self.id = id; self.name = name; self.theme = theme }
    }

    public var pages: [Page] = []
    public var currentIndex = 0
    public var host: String = ""
    public var isSecure = false
    public var blockerOn = true
    public var canGoBack = false
    public var canGoForward = false
    public var isLoading = false
    public var nowPlaying: NowPlaying?
    public var activeDownloads = 0
    /// The toolbar downloads button is on screen (a download is running or just finished, or its list is open).
    public var downloadsShown = false
    /// nil = nothing in flight; 0 = in flight, size unknown; else the overall fraction.
    public var downloadsProgress: Double?
    public var style = SidebarStyle()
    public init() {}

    // Current-page conveniences (the top tab bar and older callers use these).
    var current: Page? { pages.indices.contains(currentIndex) ? pages[currentIndex] : nil }
    public var favorites: [Row] { current?.favorites ?? [] }
    public var pinned: [Row] { current?.pinned ?? [] }
    public var today: [Row] { current?.today ?? [] }
    public var selected: TabID? { current?.selected }
    public var spaceName: String { current?.name ?? "" }
    public var accentHue: Double { current.map { $0.theme.top.mixed(with: $0.theme.bottom, 0.5).hue } ?? 0.48 }
}

public struct FolderRow: Equatable {
    public var id: UUID
    public var name: String
    public var icon: String?
    public var expanded: Bool
    public var children: [SidebarState.Row]
    public init(id: UUID, name: String, icon: String?, expanded: Bool, children: [SidebarState.Row]) {
        self.id = id; self.name = name; self.icon = icon; self.expanded = expanded; self.children = children
    }
}

public enum PinnedItem: Equatable {
    case tab(SidebarState.Row)
    case folder(FolderRow)
}

/// How the sidebar should read over the current background.
public struct SidebarStyle: Equatable {
    /// Text and fills tuned for a dark background.
    public var onDark = false
    /// Drawn over the space gradient (white-based fills) rather than the plain system sidebar.
    public var tinted = true
    public var fontSize: CGFloat = 13
    public var rowHeight: CGFloat = 30
    public var hue: Double = 0.48
    public init() {}

    var selectionFill: NSColor {
        tinted ? NSColor.white.withAlphaComponent(onDark ? 0.16 : 0.62) : Tokens.selectionFill(hue: hue)
    }
    var quietFill: NSColor {
        tinted ? NSColor.white.withAlphaComponent(onDark ? 0.08 : 0.36) : NSColor.controlBackgroundColor.withAlphaComponent(0.55)
    }
    var pillFill: NSColor {
        tinted ? NSColor.white.withAlphaComponent(onDark ? 0.10 : 0.55) : NSColor.controlBackgroundColor.withAlphaComponent(0.6)
    }
    var hairline: NSColor {
        tinted ? NSColor.white.withAlphaComponent(onDark ? 0.10 : 0.45) : NSColor.separatorColor.withAlphaComponent(0.4)
    }
}

/// Media playing in a tab you're not looking at.
public struct NowPlaying: Equatable {
    public var tab: TabID
    public var title: String
    public var url: URL?
    public var playing: Bool
    public var hasVideo: Bool
    public var artist: String = ""
    public var artwork: URL?
    public init(tab: TabID, title: String, url: URL?, playing: Bool, hasVideo: Bool, artist: String = "", artwork: URL? = nil) {
        self.tab = tab; self.title = title; self.url = url; self.playing = playing; self.hasVideo = hasVideo
        self.artist = artist; self.artwork = artwork
    }
}

@MainActor
public protocol SidebarDelegate: AnyObject {
    func sidebarSelect(_ id: TabID)
    func sidebarClose(_ id: TabID)
    func sidebarNewTab()
    func sidebarOpenPalette()
    func sidebarBack()
    func sidebarForward()
    func sidebarReload()
    func sidebarMove(_ id: TabID, to tier: TabTier, index: Int)
    func sidebarSwitchSpace(_ index: Int)
    func sidebarContextMenu(for id: TabID) -> NSMenu?
    func sidebarToggleMedia(_ id: TabID)
    func sidebarPictureInPicture(_ id: TabID)
    func sidebarOpenLibrary(from view: NSView)
    /// The swipe is about to show this space; warm its content.
    func sidebarWillSwipe(toSpace index: Int)
    func sidebarSpaceMenu() -> NSMenu?
    func sidebarClearToday()
    /// Items for the footer "+" menu (New Tab, New Folder, New Space…).
    func sidebarNewMenu() -> NSMenu?
    func sidebarToggleFolder(_ id: UUID)
    func sidebarFolderMenu(_ id: UUID) -> NSMenu?
    func sidebarMoveTab(_ tab: TabID, toFolder folder: UUID, index: Int?)
    func sidebarRenameFolder(_ id: UUID, to name: String)
    /// Live position between two spaces (0 = `from`, 1 = `to`) for the background cross-fade;
    /// a negative fraction means "animate from `from` to `to`" (keyboard or dot switch).
    func sidebarSwipeProgress(from: Int, to: Int, fraction: Double)
    /// ⌥-click: open this tab in a split with the one on screen.
    func sidebarOpenInSplit(_ id: TabID)
    /// A tab drag from the sidebar started / ended (`screenPoint`, and whether anything took it).
    func sidebarTabDragBegan(_ id: TabID)
    func sidebarTabDragEnded(_ id: TabID, at screenPoint: NSPoint, accepted: Bool)
    /// The unsplit button on a split row's hover (or ⌥-click on the row).
    func sidebarSeparateSplit(_ id: TabID)
    /// The button beside the traffic lights.
    func sidebarToggleSidebar()
    /// The toolbar downloads button (left of Back).
    func sidebarOpenDownloads(from view: NSView)
}

/// The vertical sidebar: fixed navigation and address pill on top, a strip of
/// live space pages in the middle (what the swipe moves), the space switcher
/// and library at the bottom. Plain AppKit, frame-based paging, rows reused.
@MainActor
public final class SidebarViewController: NSViewController {
    public weak var delegate: SidebarDelegate?
    private(set) var state = SidebarState()

    private let backButton = SidebarViewController.iconButton("chevron.left", "Back")
    private let forwardButton = SidebarViewController.iconButton("chevron.right", "Forward")
    private let reloadButton = SidebarViewController.iconButton("arrow.clockwise", "Reload")
    private let sidebarButton = SidebarViewController.iconButton("sidebar.left", "Hide Sidebar (⌘S)")
    /// Left of Back; only present while there is a download to show.
    public let downloadsButton = DownloadsButton()
    /// The floating copy shown while peeking at a hidden sidebar: its button docks it again.
    public var isPeek = false {
        didSet { sidebarButton.toolTip = isPeek ? "Keep Sidebar Open (⌘S)" : "Hide Sidebar (⌘S)" }
    }
    private let urlPill = URLPill()
    private let pager = PagerClipView()
    private let strip = NSView()
    private var pages: [SpacePageView] = []
    private let nowPlayingView = NowPlayingStrip()
    private let spaceDots = NSStackView()
    private let libraryButton = SidebarViewController.iconButton("tray.and.arrow.down", "Library: Downloads and Media")
    private let libraryBadge = NSTextField(labelWithString: "")

    // Paging
    private var displayedIndex = 0
    private var swiping = false
    private var pendingState: SidebarState?
    private var committedBySwipe = false

    public override func loadView() {
        let host = SwipeHostView()
        host.onSwipeBegan = { [weak self] event in self?.trackSwipe(event) ?? false }

        let nav = NSStackView(views: [downloadsButton, backButton, forwardButton, reloadButton])
        nav.spacing = 6
        nav.detachesHiddenViews = true
        downloadsButton.isHidden = true
        downloadsButton.onClick = { [weak self] in
            guard let self else { return }
            self.delegate?.sidebarOpenDownloads(from: self.downloadsButton)
        }
        backButton.target = self; backButton.action = #selector(back)
        forwardButton.target = self; forwardButton.action = #selector(forward)
        reloadButton.target = self; reloadButton.action = #selector(reload)
        sidebarButton.target = self; sidebarButton.action = #selector(toggleSidebarClicked)
        sidebarButton.setAccessibilityLabel("Hide or show the sidebar")
        urlPill.onClick = { [weak self] in self?.delegate?.sidebarOpenPalette() }

        pager.wantsLayer = true
        pager.layer?.masksToBounds = true
        pager.onLayout = { [weak self] in self?.layoutPages() }
        strip.wantsLayer = true
        pager.addSubview(strip)

        let spaceMenuHost = MenuHostView()
        spaceMenuHost.menuProvider = { [weak self] in self?.delegate?.sidebarSpaceMenu() }
        spaceDots.spacing = 8
        // Just the chips: the space's name is in each chip's tooltip and in Settings.
        let spaceGroup = NSStackView(views: [spaceDots])
        spaceGroup.spacing = 8
        spaceGroup.translatesAutoresizingMaskIntoConstraints = false
        spaceMenuHost.addSubview(spaceGroup)
        NSLayoutConstraint.activate([
            spaceGroup.leadingAnchor.constraint(equalTo: spaceMenuHost.leadingAnchor), spaceGroup.trailingAnchor.constraint(equalTo: spaceMenuHost.trailingAnchor),
            spaceGroup.topAnchor.constraint(equalTo: spaceMenuHost.topAnchor), spaceGroup.bottomAnchor.constraint(equalTo: spaceMenuHost.bottomAnchor),
        ])
        spaceMenuHost.toolTip = "Swipe with two fingers to switch spaces. Right-click to rename or recolour."

        let newTab = SidebarViewController.iconButton("plus", "New…")
        newTab.target = self; newTab.action = #selector(newMenuClicked(_:))
        newTab.setAccessibilityLabel("New tab, folder or space")
        libraryButton.target = self; libraryButton.action = #selector(libraryClicked)
        // Downloads now live in the toolbar button left of Back; the Library stays on ⌥⌘J.
        libraryButton.isHidden = true
        libraryBadge.font = .monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        libraryBadge.textColor = .white
        libraryBadge.alignment = .center
        libraryBadge.wantsLayer = true
        libraryBadge.layer?.cornerRadius = 6
        libraryBadge.isHidden = true
        libraryBadge.translatesAutoresizingMaskIntoConstraints = false
        libraryButton.addSubview(libraryBadge)
        NSLayoutConstraint.activate([
            libraryBadge.topAnchor.constraint(equalTo: libraryButton.topAnchor, constant: -3),
            libraryBadge.trailingAnchor.constraint(equalTo: libraryButton.trailingAnchor, constant: 3),
            libraryBadge.heightAnchor.constraint(equalToConstant: 12),
            libraryBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 12),
        ])
        // Arc's layout: library on the left, spaces centred, "+" on the right.
        let footer = NSView()
        for v in [libraryButton, spaceMenuHost, newTab] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(v)
        }
        NSLayoutConstraint.activate([
            libraryButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            libraryButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            newTab.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            newTab.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            spaceMenuHost.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            spaceMenuHost.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            spaceMenuHost.leadingAnchor.constraint(greaterThanOrEqualTo: libraryButton.trailingAnchor, constant: 10),
            spaceMenuHost.trailingAnchor.constraint(lessThanOrEqualTo: newTab.leadingAnchor, constant: -10),
        ])
        nowPlayingView.onToggle = { [weak self] in if let id = self?.state.nowPlaying?.tab { self?.delegate?.sidebarToggleMedia(id) } }
        nowPlayingView.onPiP = { [weak self] in if let id = self?.state.nowPlaying?.tab { self?.delegate?.sidebarPictureInPicture(id) } }
        nowPlayingView.onOpen = { [weak self] in if let id = self?.state.nowPlaying?.tab { self?.delegate?.sidebarSelect(id) } }
        nowPlayingView.isHidden = true

        for v in [nav, sidebarButton, urlPill, pager, nowPlayingView, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(v)
        }
        let pad = Tokens.Space.sidebarPadding
        // The footer follows the safe area so it stays clear of the screen's
        // rounded corners in full screen.
        let safe = host.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            nav.topAnchor.constraint(equalTo: host.topAnchor, constant: 11),
            nav.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -pad - 4),
            // Right after the traffic lights (they end near x = 74), on their centre line.
            sidebarButton.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 82),
            sidebarButton.centerYAnchor.constraint(equalTo: nav.centerYAnchor),
            urlPill.topAnchor.constraint(equalTo: host.topAnchor, constant: 44),
            urlPill.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: pad),
            urlPill.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -pad),
            urlPill.heightAnchor.constraint(equalToConstant: Tokens.Size.urlPill),
            pager.topAnchor.constraint(equalTo: urlPill.bottomAnchor, constant: Tokens.Space.sectionGap),
            pager.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            pager.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            pager.bottomAnchor.constraint(equalTo: nowPlayingView.topAnchor, constant: -6),
            nowPlayingView.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: pad),
            nowPlayingView.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -pad),
            nowPlayingView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: pad + 6),
            footer.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -pad - 6),
            footer.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -14),
            footer.heightAnchor.constraint(equalToConstant: 30),
        ])
        view = host
    }

    // MARK: State

    public func apply(_ new: SidebarState) {
        // Never rebuild mid-gesture: hold the latest state until the swipe ends.
        if swiping { pendingState = new; return }
        let old = state
        state = new
        let style = new.style
        // Setting the appearance or an SF Symbol re-resolves the whole subtree / glyph, even
        // when nothing changed; refresh runs many times a second while pages load.
        let appearanceName: NSAppearance.Name? = style.tinted ? (style.onDark ? .darkAqua : .aqua) : nil
        if view.appearance?.name != appearanceName {
            view.appearance = appearanceName.map { NSAppearance(named: $0) } ?? nil
        }

        if backButton.isEnabled != new.canGoBack { backButton.isEnabled = new.canGoBack }
        if forwardButton.isEnabled != new.canGoForward { forwardButton.isEnabled = new.canGoForward }
        if old.isLoading != new.isLoading || reloadButton.image == nil {
            reloadButton.image = NSImage(systemSymbolName: new.isLoading ? "xmark" : "arrow.clockwise", accessibilityDescription: new.isLoading ? "Stop" : "Reload")
        }
        urlPill.update(host: new.host, secure: new.isSecure, blocker: new.blockerOn, hue: new.accentHue, style: style)

        if old.nowPlaying != new.nowPlaying || old.style != new.style {
            if let np = new.nowPlaying { nowPlayingView.update(np, style: style) }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Tokens.Motion.duration(0.2)
                nowPlayingView.animator().isHidden = new.nowPlaying == nil
            }
        }
        downloadsButton.update(progress: new.downloadsProgress, neon: Tokens.neon(from: new.current?.theme.bottom ?? ThemeColor(r: 1, g: 0, b: 0)))
        if downloadsButton.isHidden == new.downloadsShown {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Tokens.Motion.duration(0.2)
                ctx.allowsImplicitAnimation = true
                downloadsButton.isHidden = !new.downloadsShown
                downloadsButton.superview?.layoutSubtreeIfNeeded()
            }
        }
        libraryBadge.isHidden = true
        libraryBadge.stringValue = "\(new.activeDownloads)"
        libraryBadge.layer?.backgroundColor = Tokens.accent(hue: new.accentHue).cgColor

        // Pages: one live view per space, reused by position.
        let pagesChanged = old.pages.map(\.id) != new.pages.map(\.id)
        while pages.count < new.pages.count {
            let page = SpacePageView()
            page.owner = self
            page.onSwipeBegan = { [weak self] event in self?.trackSwipe(event) ?? false }
            strip.addSubview(page)
            pages.append(page)
        }
        while pages.count > new.pages.count { pages.removeLast().removeFromSuperview() }
        for (i, page) in pages.enumerated() {
            page.apply(new.pages[i], style: style)
        }
        if pagesChanged { layoutPages() }
        predrawNeighbours()

        rebuildSpaceIndicator()

        // Move to the current space. After a swipe the strip is already there.
        let target = min(max(0, new.currentIndex), max(0, new.pages.count - 1))
        if target != displayedIndex {
            let from = displayedIndex
            displayedIndex = target
            if committedBySwipe || pagesChanged || old.pages.isEmpty {
                placeStrip(at: target)
            } else {
                animateStrip(from: from, to: target)
            }
        }
        committedBySwipe = false
    }

    /// Starts inline renaming of a folder on the current page (new folders).
    public func beginRenamingFolder(_ id: UUID) {
        guard pages.indices.contains(displayedIndex) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pages[self.displayedIndex].beginRenaming(id)
        }
    }

    /// Extension toolbar buttons, shown inside the address pill.
    public func setExtensionButtons(_ buttons: [NSView]) {
        urlPill.setAccessories(buttons)
    }

    /// Kept for callers; pages are live now, so there's nothing to cache.
    public func cacheCurrentSpaceSnapshot() {}

    private var indicatorSignature: [String] = []

    private func rebuildSpaceIndicator() {
        // Chips show only each space's name, icon and theme; don't redo them on every tab change.
        let signature = state.pages.map { "\($0.id)|\($0.name)|\($0.icon)|\($0.theme)" } + ["\(state.currentIndex)", "\(state.style)"]
        guard signature != indicatorSignature else { return }
        indicatorSignature = signature
        let count = state.pages.count
        if spaceDots.arrangedSubviews.count != count {
            spaceDots.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for i in 0..<count {
                let chip = SpaceChip()
                chip.onClick = { [weak self] in self?.delegate?.sidebarSwitchSpace(i) }
                spaceDots.addArrangedSubview(chip)
            }
        }
        for (i, v) in spaceDots.arrangedSubviews.enumerated() where state.pages.indices.contains(i) {
            (v as? SpaceChip)?.set(page: state.pages[i], on: i == state.currentIndex, style: state.style)
        }
        // One chip is just noise; show the name alone until there's a second space.
        spaceDots.isHidden = count < 2
    }

    // MARK: Paging geometry

    private var pageWidth: CGFloat { max(1, pager.bounds.width) }

    private func layoutPages() {
        let w = pageWidth, h = pager.bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, page) in pages.enumerated() {
            page.frame = NSRect(x: CGFloat(i) * w, y: 0, width: w, height: h)
        }
        strip.frame = NSRect(x: -CGFloat(displayedIndex) * w, y: 0, width: w * CGFloat(max(1, pages.count)), height: h)
        CATransaction.commit()
    }

    /// Draws the pages either side of the current one ahead of time (they're
    /// clipped, so AppKit wouldn't draw them until they slide into view, which
    /// cost ~15 ms in the first frame of a swipe). Idle-time work.
    private func predrawNeighbours() {
        let i = displayedIndex
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.swiping else { return }
            for n in [i - 1, i + 1] where self.pages.indices.contains(n) {
                let page = self.pages[n]
                page.layoutSubtreeIfNeeded()
                page.display()
            }
        }
    }

    private func setStripX(_ x: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.layer?.removeAnimation(forKey: "page")
        pager.layer?.removeAnimation(forKey: "settle")
        pager.layer?.sublayerTransform = CATransform3DIdentity
        if strip.frame.origin.x != x { strip.setFrameOrigin(NSPoint(x: x, y: 0)) }
        CATransaction.commit()
    }

    /// Mid-gesture movement: a render-server-only translation of the pager's
    /// sublayers. Moving the strip's AppKit frame cost 20+ ms on the first frame
    /// of a drag (AppKit re-derives geometry for every view inside); the frame
    /// is set once at release instead, hidden under the settle spring.
    private func setDragOffset(_ dx: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pager.layer?.sublayerTransform = CATransform3DMakeTranslation(dx, 0, 0)
        CATransaction.commit()
    }

    private func placeStrip(at index: Int) {
        setStripX(-CGFloat(index) * pageWidth)
        delegate?.sidebarSwipeProgress(from: index, to: index, fraction: 0)
    }

    /// Keyboard, dot or palette switch: the same page strip slides with a
    /// critically damped spring (Reduce Motion: a quick cross-fade instead).
    private func animateStrip(from: Int, to: Int) {
        let w = pageWidth
        let startX = strip.layer?.presentation()?.position.x ?? strip.frame.origin.x
        let endX = -CGFloat(to) * w
        setStripX(endX)
        delegate?.sidebarSwipeProgress(from: from, to: to, fraction: -1)   // negative: animate the change
        guard let layer = strip.layer else { return }
        if Tokens.Motion.reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.3; fade.toValue = 1; fade.duration = 0.18
            layer.add(fade, forKey: "page")
            return
        }
        let spring = CASpringAnimation(keyPath: "position.x")
        let response = Tokens.Motion.pageResponse, damping = 1.0
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / response, 2)
        spring.damping = 4 * .pi * damping / response
        spring.fromValue = startX
        spring.toValue = endX
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "page")
    }

    // MARK: Swipe between spaces

    /// Interactive two-finger swipe, tracked by the system (rubber-banding and
    /// the commit decision match Safari). Only the strip's position changes per
    /// event: no layout, no snapshots, no table reloads.
    private func trackSwipe(_ event: NSEvent) -> Bool {
        guard state.pages.count > 1, !swiping else { return false }
        let index = displayedIndex, count = state.pages.count
        let w = pageWidth
        strip.layer?.removeAnimation(forKey: "page")
        swiping = true
        var warmed = false
        var samples: [(t: CFTimeInterval, amount: CGFloat)] = []
        // gestureAmount > 0 is a swipe to the right, which reveals the space on the left.
        event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount],
                              dampenAmountThresholdMin: -CGFloat(count - 1 - index), max: CGFloat(index)) { [weak self] amount, phase, complete, stop in
            MainActor.assumeIsolated {
                guard let self, self.swiping else { return }
                self.setDragOffset(amount * w)
                let neighbour = amount > 0 ? index - 1 : index + 1
                if neighbour >= 0, neighbour < count {
                    self.delegate?.sidebarSwipeProgress(from: index, to: neighbour, fraction: min(1, Double(abs(amount))))
                }
                if !warmed, abs(amount) > 0.3, neighbour >= 0, neighbour < count {
                    warmed = true
                    self.delegate?.sidebarWillSwipe(toSpace: neighbour)
                }
                let now = CACurrentMediaTime()
                samples.append((now, amount))
                samples.removeAll { now - $0.t > 0.08 }
                if phase == .ended || phase == .cancelled {
                    // Fingers lifted: take over from the system's (slower) settle
                    // with our own snappy spring, carrying the flick's velocity.
                    stop.pointee = true
                    let velocity = samples.count > 1
                        ? (samples.last!.amount - samples.first!.amount) / CGFloat(max(0.008, samples.last!.t - samples.first!.t))
                        : 0                                   // pages per second
                    let projected = amount + velocity * 0.12  // where a flick would carry it
                    var target = index
                    if projected > 0.35 || velocity > 1.2 { target = index - 1 }
                    if projected < -0.35 || velocity < -1.2 { target = index + 1 }
                    target = min(max(0, target), count - 1)
                    if phase == .cancelled { target = index }
                    self.settleSwipe(from: amount, index: index, to: target, velocity: velocity)
                } else if complete {
                    let target = amount > 0.5 ? index - 1 : (amount < -0.5 ? index + 1 : index)
                    self.finishSwipe(to: target)
                }
            }
        }
        return true
    }

    /// The release: a fast, critically damped spring from where the finger
    /// left the strip, starting at the finger's speed, then commit.
    private func settleSwipe(from amount: CGFloat, index: Int, to target: Int, velocity: CGFloat) {
        let w = pageWidth
        let startDX = amount * w                       // current visual offset from rest
        let endDX = CGFloat(index - target) * w        // offset that shows the target page
        if target != index { delegate?.sidebarSwipeProgress(from: index, to: target, fraction: 1) }
        else { delegate?.sidebarSwipeProgress(from: index, to: index, fraction: 0) }
        swiping = false
        displayedIndex = target
        // The motion is a render-server-only spring on the pager's sublayer
        // translation; the strip's AppKit frame (the costly part) is moved only
        // once the motion has finished, when a brief main-thread pause can't show.
        let landed = { [weak self] in
            guard let self else { return }
            self.setStripX(-CGFloat(target) * w)       // resets the translation too
            self.predrawNeighbours()
        }
        guard !Tokens.Motion.reduceMotion, let layer = pager.layer, abs(endDX - startDX) > 0.5 else {
            landed(); commitSwipe(to: target); return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { landed() } }
        let response = Tokens.Motion.pageResponse
        let spring = CASpringAnimation(keyPath: "sublayerTransform.translation.x")
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / response, 2)
        spring.damping = 4 * .pi * 0.92 / response
        let distance = endDX - startDX
        spring.initialVelocity = distance != 0 ? (velocity * w) / distance : 0   // in "distances per second"
        spring.fromValue = startDX
        spring.toValue = endDX
        spring.duration = spring.settlingDuration
        layer.sublayerTransform = CATransform3DMakeTranslation(endDX, 0, 0)
        layer.add(spring, forKey: "settle")
        CATransaction.commit()
        commitSwipe(to: target)
    }

    /// Tells the store about the new space and applies anything held back during the gesture.
    private func commitSwipe(to target: Int) {
        if target != state.currentIndex {
            committedBySwipe = true
            delegate?.sidebarSwitchSpace(target)
        }
        if let pending = pendingState {
            pendingState = nil
            apply(pending)
        }
    }

    private func finishSwipe(to target: Int, placing: Bool = true) {
        swiping = false
        displayedIndex = target
        if placing { placeStrip(at: target) }
        predrawNeighbours()
        if target != state.currentIndex {
            committedBySwipe = true
            delegate?.sidebarSwitchSpace(target)
        }
        if let pending = pendingState {
            pendingState = nil
            apply(pending)
        }
    }

    // MARK: Debug driving (benchmarks only)

    /// Drives the same code path as a real swipe, without an NSEvent: begin,
    /// per-frame amounts, then finish. Used by the swipe benchmark.
    public func debugSwipeBegin() -> Bool {
        guard state.pages.count > 1, !swiping else { return false }
        strip.layer?.removeAnimation(forKey: "page")
        swiping = true
        return true
    }

    public func debugSwipe(amount: CGFloat) {
        let index = displayedIndex, count = state.pages.count, w = pageWidth
        _ = w
        setDragOffset(amount * pageWidth)
        let neighbour = amount > 0 ? index - 1 : index + 1
        if neighbour >= 0, neighbour < count {
            delegate?.sidebarSwipeProgress(from: index, to: neighbour, fraction: min(1, Double(abs(amount))))
        }
    }

    /// Releases like real fingers: the snappy settle spring with this velocity (pages/s).
    public func debugSwipeEnd(amount: CGFloat, velocity: CGFloat = 0) {
        let index = displayedIndex, count = state.pages.count
        let projected = amount + velocity * 0.12
        var target = index
        if projected > 0.35 || velocity > 1.2 { target = index - 1 }
        if projected < -0.35 || velocity < -1.2 { target = index + 1 }
        settleSwipe(from: amount, index: index, to: min(max(0, target), count - 1), velocity: velocity)
    }

    public var debugCurrentIndex: Int { displayedIndex }

    // MARK: Actions

    @objc private func back() { delegate?.sidebarBack() }
    @objc private func forward() { delegate?.sidebarForward() }
    @objc private func reload() { delegate?.sidebarReload() }
    @objc private func toggleSidebarClicked() { delegate?.sidebarToggleSidebar() }
    @objc private func newTabClicked() { delegate?.sidebarNewTab() }

    /// The footer "+" opens a small "New…" menu (Arc-style) above the button.
    @objc private func newMenuClicked(_ sender: NSButton) {
        guard let menu = delegate?.sidebarNewMenu() else { delegate?.sidebarNewTab(); return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
    @objc private func libraryClicked() { delegate?.sidebarOpenLibrary(from: libraryButton) }

    static func iconButton(_ symbol: String, _ label: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: nil, action: nil)
        b.isBordered = false
        b.bezelStyle = .accessoryBarAction
        b.imageScaling = .scaleProportionallyDown
        b.contentTintColor = Tokens.secondaryInk
        b.toolTip = label
        b.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        b.widthAnchor.constraint(equalToConstant: 24).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return b
    }
}

/// Clips the page strip and reports size changes (pages are laid out by frame).
final class PagerClipView: NSView {
    var onLayout: (() -> Void)?
    private var lastSize: NSSize = .zero
    override func layout() {
        super.layout()
        if bounds.size != lastSize { lastSize = bounds.size; onLayout?() }
    }
}

// MARK: - One space's page

/// A space's favorites grid and tab list. Each space has its own live page,
/// so swiping shows the real neighbouring space, not a picture of it.
@MainActor
final class SpacePageView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    weak var owner: SidebarViewController?
    var onSwipeBegan: ((NSEvent) -> Bool)? {
        didSet { scroll.onSwipeBegan = onSwipeBegan }
    }
    private var delegate: SidebarDelegate? { owner?.delegate }
    private let favoritesGrid = NSStackView()   // vertical stack of rows of 4
    private let table = SidebarTableView()
    private let scroll = SwipeAwareScrollView()
    private var page = SidebarState.Page(id: UUID(), name: "", theme: .from(hue: 0.48))
    private var style = SidebarStyle()
    private var rows: [Item] = []
    private var gridHeight: NSLayoutConstraint!

    enum Item: Equatable {
        case tab(SidebarState.Row, TabTier)
        case folder(FolderRow)
        /// A tab inside a folder (indented).
        case child(SidebarState.Row, folder: UUID)
        case divider
        case newTab

        /// Identity for animated diffs (content changes don't count).
        var key: String {
            switch self {
            case .tab(let r, _): "t" + r.id.description
            case .folder(let f): "f" + f.id.uuidString
            case .child(let r, _): "c" + r.id.description
            case .divider: "divider"
            case .newTab: "new"
            }
        }
    }

    init() {
        super.init(frame: .zero)
        favoritesGrid.orientation = .vertical
        favoritesGrid.spacing = 8
        favoritesGrid.alignment = .leading
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: Tokens.Space.tabGap)
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.addTableColumn(NSTableColumn(identifier: .init("tab")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.registerForDraggedTypes([.aegisTab])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.menuProvider = { [weak self] row in
            guard let self, row >= 0, row < self.rows.count else { return nil }
            switch self.rows[row] {
            case .tab(let r, _), .child(let r, _): return self.delegate?.sidebarContextMenu(for: self.tabID(in: r, row: row))
            case .folder(let f): return self.delegate?.sidebarFolderMenu(f.id)
            default: return nil
            }
        }
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        for v in [favoritesGrid, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let pad = Tokens.Space.sidebarPadding
        gridHeight = favoritesGrid.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            favoritesGrid.topAnchor.constraint(equalTo: topAnchor),
            favoritesGrid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            favoritesGrid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            gridHeight,
            scroll.topAnchor.constraint(equalTo: favoritesGrid.bottomAnchor, constant: 0),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ new: SidebarState.Page, style newStyle: SidebarStyle) {
        let old = page, oldStyle = style
        page = new
        style = newStyle
        let favoriteSelectionChanged = old.selected != new.selected
            && new.favorites.contains { $0.id == old.selected || $0.id == new.selected }
        if old.favorites != new.favorites || favoriteSelectionChanged || oldStyle != newStyle || favoritesGrid.arrangedSubviews.isEmpty != new.favorites.isEmpty {
            favoritesGrid.arrangedSubviews.forEach { $0.removeFromSuperview() }
            let favs = Array(new.favorites.prefix(12))
            // Four to a row, like Arc; a short last row keeps tile size (spacers fill).
            for start in stride(from: 0, to: favs.count, by: 4) {
                let row = NSStackView()
                row.orientation = .horizontal
                row.distribution = .fillEqually
                row.spacing = 8
                for fav in favs[start..<min(start + 4, favs.count)] {
                    let tile = FavoriteTile(row: fav, selected: fav.id == new.selected, style: newStyle)
                    tile.onClick = { [weak self] in self?.delegate?.sidebarSelect(fav.id) }
                    tile.menuProvider = { [weak self] in self?.delegate?.sidebarContextMenu(for: fav.id) }
                    row.addArrangedSubview(tile)
                }
                while row.arrangedSubviews.count < 4 { row.addArrangedSubview(NSView()) }
                row.translatesAutoresizingMaskIntoConstraints = false
                favoritesGrid.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: favoritesGrid.widthAnchor).isActive = true
            }
            let rows = CGFloat((favs.count + 3) / 4)
            gridHeight.constant = favs.isEmpty ? 0 : rows * Tokens.Size.favoriteTile + (rows - 1) * 8 + Tokens.Space.sectionGap
        }
        var items: [Item] = []
        let pinnedEntries = new.pinnedEntries.isEmpty && !new.pinned.isEmpty ? new.pinned.map { PinnedItem.tab($0) } : new.pinnedEntries
        for entry in pinnedEntries {
            switch entry {
            case .tab(let r): items.append(.tab(r, .pinned))
            case .folder(let f):
                items.append(.folder(f))
                // Collapsed folders still show their selected tab (Arc).
                let visible = f.expanded ? f.children : f.children.filter { $0.id == new.selected }
                items += visible.map { .child($0, folder: f.id) }
            }
        }
        items.append(.divider)
        items.append(.newTab)
        items += new.today.map { .tab($0, .today) }
        guard items != rows || old.selected != new.selected || oldStyle != newStyle else { return }
        let oldRows = rows
        rows = items
        table.rowHeight = newStyle.rowHeight
        let oldKeys = oldRows.map(\.key), newKeys = items.map(\.key)
        if oldKeys == newKeys, oldStyle == newStyle {
            // Same rows: touch only the ones whose content or highlight changed, and update their
            // existing cells in place. Reloading every row on each title or progress tick rebuilt
            // all the cell views and their key-view loop: up to 300 ms of main thread per redraw.
            func touchesSelection(_ item: Item) -> Bool {
                switch item {
                case .tab(let r, _), .child(let r, _):
                    return old.selected != new.selected && r.members.contains { $0 == old.selected || $0 == new.selected }
                case .divider: return old.selected != new.selected || old.today.count != new.today.count
                default: return false
                }
            }
            for i in rows.indices where oldRows[i] != rows[i] || touchesSelection(rows[i]) {
                if let v = table.view(atColumn: 0, row: i, makeIfNecessary: false) { configure(v, row: i) }
            }
            return
        }
        // One contiguous insertion or removal (folder expand/collapse, a tab
        // opened or closed): animate just those rows instead of reloading.
        var prefix = 0
        while prefix < min(oldKeys.count, newKeys.count), oldKeys[prefix] == newKeys[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(oldKeys.count, newKeys.count) - prefix,
              oldKeys[oldKeys.count - 1 - suffix] == newKeys[newKeys.count - 1 - suffix] { suffix += 1 }
        let removed = prefix..<(oldKeys.count - suffix), inserted = prefix..<(newKeys.count - suffix)
        if oldStyle == newStyle, window != nil, (removed.isEmpty || inserted.isEmpty), removed.count + inserted.count <= 40 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Tokens.Motion.duration(0.22)
                table.beginUpdates()
                if !removed.isEmpty { table.removeRows(at: IndexSet(integersIn: removed), withAnimation: [.slideUp, .effectFade]) }
                if !inserted.isEmpty { table.insertRows(at: IndexSet(integersIn: inserted), withAnimation: [.slideDown, .effectFade]) }
                table.endUpdates()
            }
            let unchanged = IndexSet(integersIn: 0..<rows.count).subtracting(IndexSet(integersIn: inserted))
            table.reloadData(forRowIndexes: unchanged, columnIndexes: [0])
        } else {
            table.reloadData()
        }
    }

    func beginRenaming(_ folder: UUID) {
        guard let row = rows.firstIndex(where: { if case .folder(let f) = $0 { return f.id == folder }; return false }) else { return }
        table.scrollRowToVisible(row)
        (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? FolderCell)?.beginEditing()
    }

    // Swipes that start over the empty part of a page.
    override func scrollWheel(with event: NSEvent) {
        if SwipeHostView.isSwipeStart(event), onSwipeBegan?(event) == true { return }
        super.scrollWheel(with: event)
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        switch rows[row] {
        case .tab(let r, _), .child(let r, _):
            let id = tabID(in: r, row: row)
            if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                if r.split != nil { delegate?.sidebarSeparateSplit(id) } else { delegate?.sidebarOpenInSplit(id) }
            }
            else { delegate?.sidebarSelect(id) }
        case .folder(let f): delegate?.sidebarToggleFolder(f.id)
        case .newTab: delegate?.sidebarNewTab()
        case .divider: break
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .divider = rows[row] { return rows.first == .divider ? 26 : 36 }
        return style.rowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let v: NSView
        switch rows[row] {
        case .divider: v = tableView.makeView(withIdentifier: DividerCell.id, owner: nil) as? DividerCell ?? DividerCell()
        case .newTab, .tab, .child: v = tableView.makeView(withIdentifier: TabCell.id, owner: nil) as? TabCell ?? TabCell()
        case .folder: v = tableView.makeView(withIdentifier: FolderCell.id, owner: nil) as? FolderCell ?? FolderCell()
        }
        configure(v, row: row)
        return v
    }

    /// Fills a cell for `rows[row]`; used for new cells and to update visible ones in place.
    private func configure(_ view: NSView, row: Int) {
        switch rows[row] {
        case .divider:
            guard let v = view as? DividerCell else { return }
            let selectedIsToday = page.today.contains { $0.id == page.selected }
            v.onClear = page.today.count > (selectedIsToday ? 1 : 0)
                ? { [weak self] in self?.delegate?.sidebarClearToday() } : nil
        case .newTab:
            (view as? TabCell)?.configureNewTab(style: style)
        case .tab(let r, _), .child(let r, _):
            guard let v = view as? TabCell else { return }
            let indent: CGFloat = if case .child = rows[row] { 14 } else { 0 }
            v.configure(r, selected: r.members.contains { $0 == page.selected }, style: style, indent: indent, focused: page.selected)
            v.onClose = { [weak self] in self?.delegate?.sidebarClose(r.id) }
            v.onSeparate = r.split == nil ? nil : { [weak self] in self?.delegate?.sidebarSeparateSplit(r.id) }
        case .folder(let f):
            guard let v = view as? FolderCell else { return }
            v.configure(f, style: style)
            v.onRename = { [weak self] name in self?.delegate?.sidebarRenameFolder(f.id, to: name) }
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    /// For a split row, the segment under the pointer; otherwise the row's tab.
    private func tabID(in r: SidebarState.Row, row: Int) -> TabID {
        guard r.split != nil, let event = NSApp.currentEvent,
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabCell else { return r.id }
        return cell.segment(at: cell.convert(event.locationInWindow, from: nil)) ?? r.id
    }

    private var draggedTab: TabID?

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let r: SidebarState.Row
        switch rows[row] {
        case .tab(let x, _), .child(let x, _): r = x
        default: return nil
        }
        let id = tabID(in: r, row: row)
        let url = r.split?.first { $0.id == id }?.url ?? r.url
        let item = NSPasteboardItem()
        item.setString(id.description, forType: .aegisTab)
        if let url { item.setString(url.absoluteString, forType: .string) }
        draggedTab = id
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        // A drop outside the window tears the tab off: don't fly the image back first.
        session.animatesToStartingPositionsOnCancelOrFail = false
        if let id = draggedTab { delegate?.sidebarTabDragBegan(id) }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let id = draggedTab else { return }
        draggedTab = nil
        delegate?.sidebarTabDragEnded(id, at: screenPoint, accepted: !operation.isEmpty)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingPasteboard.string(forType: .aegisTab) != nil else { return [] }
        // Onto a folder row: into the folder (the whole row highlights).
        if op == .on, rows.indices.contains(row), case .folder = rows[row] { return .move }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let raw = info.draggingPasteboard.string(forType: .aegisTab), let uuid = UUID(uuidString: raw) else { return false }
        let id = TabID(uuid)
        if dropOperation == .on, rows.indices.contains(row), case .folder(let f) = rows[row] {
            delegate?.sidebarMoveTab(id, toFolder: f.id, index: nil)
            return true
        }
        // Between a folder's children: into that folder at that spot.
        if rows.indices.contains(row), case .child(_, let folder) = rows[row] {
            let firstChild = rows.firstIndex { if case .child(_, let f) = $0 { return f == folder }; return false } ?? row
            delegate?.sidebarMoveTab(id, toFolder: folder, index: row - firstChild)
            return true
        }
        // Rows above the divider are pinned; below "New Tab" are today's.
        let dividerRow = rows.firstIndex(of: .divider) ?? 0
        if row <= dividerRow {
            delegate?.sidebarMove(id, to: .pinned, index: row)
        } else {
            delegate?.sidebarMove(id, to: .today, index: max(0, row - dividerRow - 2))
        }
        return true
    }
}

extension NSPasteboard.PasteboardType {
    static let aegisTab = NSPasteboard.PasteboardType("app.aegis.tab")
}

/// Table that asks for a context menu per row.
final class SidebarTableView: NSTableView {
    var menuProvider: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return menuProvider?(row)
    }
}

// MARK: - Cells

final class TabCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("TabCell")
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let audio = NSImageView()
    private let background = NSView()
    private var tracking: NSTrackingArea?
    private var currentURL: URL?
    private var selected = false
    private var style = SidebarStyle()
    var onClose: (() -> Void)?
    /// Split view: one segment per pane instead of the icon and title.
    private let segments = NSStackView()
    private var segmentViews: [SplitSegmentView] = []
    private var isSplitRow = false

    init() {
        super.init(frame: .zero)
        identifier = TabCell.id
        segments.orientation = .horizontal
        segments.distribution = .fillEqually
        segments.spacing = 2
        segments.isHidden = true
        background.wantsLayer = true
        background.layer?.cornerRadius = Tokens.Radius.tabRow
        background.layer?.cornerCurve = .continuous
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        audio.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Playing audio")
        audio.contentTintColor = Tokens.secondaryInk
        audio.symbolConfiguration = .init(pointSize: 10, weight: .medium)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        closeButton.isBordered = false
        closeButton.contentTintColor = Tokens.secondaryInk
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.isHidden = true
        for v in [background, icon, label, audio, closeButton, segments] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            segments.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            segments.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            segments.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            segments.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Tokens.Size.favicon),
            icon.heightAnchor.constraint(equalToConstant: Tokens.Size.favicon),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            audio.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            audio.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(greaterThanOrEqualTo: audio.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        iconLeading?.isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private var iconLeading: NSLayoutConstraint?
    /// The pointer is over the row; a reconfigure (title or loading change) keeps the hover look.
    private var hovering = false

    func configure(_ row: SidebarState.Row, selected: Bool, style: SidebarStyle, indent: CGFloat = 0, focused: TabID? = nil) {
        iconLeading?.constant = 10 + indent
        configureSplit(row, selected: selected, style: style, focused: focused)
        self.selected = selected
        self.style = style
        label.stringValue = row.title
        label.textColor = .labelColor
        label.font = .systemFont(ofSize: style.fontSize, weight: selected ? .medium : .regular)
        background.layer?.backgroundColor = selected ? style.selectionFill.cgColor
            : hovering ? style.quietFill.withAlphaComponent(style.onDark ? 0.06 : 0.22).cgColor : NSColor.clear.cgColor
        background.layer?.shadowOpacity = selected && style.tinted && !style.onDark ? 0.08 : 0
        background.layer?.shadowRadius = 2
        background.layer?.shadowOffset = CGSize(width: 0, height: -1)
        alphaValue = row.sleeping && !selected ? 0.6 : 1
        audio.isHidden = !row.playing
        toolTip = row.sleeping ? "\(row.title) — sleeping" : row.title
        setAccessibilityLabel(row.title)
        currentURL = row.url
        setIcon(Favicons.shared.cached(for: row.url) ?? Favicons.placeholder())
        if Favicons.shared.cached(for: row.url) == nil {
            let url = row.url
            Favicons.shared.load(for: url) { [weak self] image in
                guard let self, self.currentURL == url, let image else { return }
                self.setIcon(image)
            }
        }
        closeButton.isHidden = !hovering
        closeButton.image = NSImage(systemSymbolName: isSplitRow ? "rectangle.split.2x1" : "xmark",
                                    accessibilityDescription: isSplitRow ? "Separate Split View" : "Close Tab")
        closeButton.toolTip = isSplitRow ? "Separate Split View" : nil
        if isSplitRow {
            let titles = row.split?.map(\.title).joined(separator: " | ") ?? row.title
            toolTip = "Split View: \(titles)"
            setAccessibilityLabel("Split View: \(titles)")
            alphaValue = 1
        }
    }

    private func configureSplit(_ row: SidebarState.Row, selected: Bool, style: SidebarStyle, focused: TabID?) {
        let peers = row.split ?? []
        isSplitRow = !peers.isEmpty
        segments.isHidden = !isSplitRow
        icon.isHidden = isSplitRow
        label.isHidden = isSplitRow
        guard isSplitRow else { return }
        while segmentViews.count < peers.count {
            let v = SplitSegmentView()
            segmentViews.append(v)
            segments.addArrangedSubview(v)
        }
        while segmentViews.count > peers.count { segmentViews.removeLast().removeFromSuperview() }
        let focusedIndex = selected ? peers.firstIndex { $0.id == focused } : nil
        for (i, (v, peer)) in zip(segmentViews, peers).enumerated() {
            v.configure(peer, focused: i == focusedIndex, style: style)
        }
    }

    /// The pane's tab under `point` (in this cell), for split rows.
    func segment(at point: NSPoint) -> TabID? {
        guard isSplitRow else { return nil }
        return segmentViews.first { $0.frame.insetBy(dx: -1, dy: -3).contains(segments.convert(point, from: self)) }?.tabID
    }

    private var iconPlate = false
    /// Dark favicons (GitHub, X…) vanish on dark themes: give them a light plate.
    private func setIcon(_ image: NSImage) {
        // Same image and plate: skip (setting an image view's image dirties layout every time).
        let plate = style.onDark && Favicons.isDark(image)
        if icon.image === image, iconPlate == plate { return }
        iconPlate = plate
        icon.image = image
        icon.contentTintColor = nil
        icon.wantsLayer = true
        icon.layer?.backgroundColor = plate ? NSColor.white.withAlphaComponent(0.88).cgColor : nil
        icon.layer?.cornerRadius = 3.5
    }

    func configureNewTab(style: SidebarStyle) {
        iconLeading?.constant = 10
        isSplitRow = false; segments.isHidden = true; icon.isHidden = false; label.isHidden = false
        selected = false
        self.style = style
        label.stringValue = "New Tab"
        label.textColor = Tokens.secondaryInk
        label.font = .systemFont(ofSize: style.fontSize)
        background.layer?.backgroundColor = NSColor.clear.cgColor
        background.layer?.shadowOpacity = 0
        icon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        icon.contentTintColor = Tokens.secondaryInk
        icon.layer?.backgroundColor = nil
        audio.isHidden = true
        alphaValue = 1
        currentURL = nil
        onClose = nil
        toolTip = "New Tab (⌘T)"
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        closeButton.isHidden = (isSplitRow ? onSeparate : onClose) == nil
        if !selected { background.layer?.backgroundColor = style.quietFill.withAlphaComponent(style.onDark ? 0.06 : 0.22).cgColor }
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        closeButton.isHidden = true
        if !selected { background.layer?.backgroundColor = NSColor.clear.cgColor }
    }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { onClose?() } }
    var onSeparate: (() -> Void)?
    @objc private func closeClicked() { if isSplitRow { onSeparate?() } else { onClose?() } }
}

/// A folder row: folder glyph (filled when open) and its name, editable in place.
final class FolderCell: NSTableCellView, NSTextFieldDelegate {
    static let id = NSUserInterfaceItemIdentifier("FolderCell")
    private let glyph = NSImageView()
    private let name = NSTextField(string: "")
    private let count = NSTextField(labelWithString: "")
    var onRename: ((String) -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = FolderCell.id
        glyph.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        glyph.contentTintColor = Tokens.secondaryInk
        name.isBordered = false
        name.drawsBackground = false
        name.isEditable = false
        name.isSelectable = false
        name.focusRingType = .none
        name.lineBreakMode = .byTruncatingTail
        name.delegate = self
        name.cell?.usesSingleLineMode = true
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = Tokens.tertiaryInk
        for v in [glyph, name, count] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: Tokens.Size.favicon),
            name.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 10),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ f: FolderRow, style: SidebarStyle) {
        name.stringValue = f.name
        name.font = .systemFont(ofSize: style.fontSize, weight: .medium)
        name.textColor = .labelColor
        glyph.image = NSImage(systemSymbolName: f.icon ?? (f.expanded ? "folder.fill" : "folder"), accessibilityDescription: nil)
        // When collapsed, how many tabs it holds; when open the children speak for themselves.
        count.stringValue = f.expanded || f.children.isEmpty ? "" : "\(f.children.count)"
        toolTip = f.expanded ? "Click to collapse" : "Click to expand"
        setAccessibilityLabel("\(f.name) folder, \(f.children.count) tabs, \(f.expanded ? "expanded" : "collapsed")")
    }

    func beginEditing() {
        name.isEditable = true
        name.isSelectable = true
        window?.makeFirstResponder(name)
        name.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        name.isEditable = false
        name.isSelectable = false
        let text = name.stringValue.trimmingCharacters(in: .whitespaces)
        onRename?(text.isEmpty ? "Untitled" : text)
    }
}

final class DividerCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("DividerCell")
    private let clear = NSButton(title: "Clear", target: nil, action: nil)
    var onClear: (() -> Void)? { didSet { clear.isHidden = onClear == nil } }
    init() {
        super.init(frame: .zero)
        identifier = DividerCell.id
        let label = NSTextField(labelWithString: "Today")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Tokens.secondaryInk
        let line = NSBox()
        line.boxType = .separator
        clear.isBordered = false
        clear.font = .systemFont(ofSize: 11)
        clear.contentTintColor = Tokens.secondaryInk
        clear.target = self
        clear.action = #selector(clearTapped)
        clear.toolTip = "Archive today's tabs (they stay searchable in ⌘K)"
        clear.isHidden = true
        for v in [label, line, clear] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            line.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            line.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            clear.leadingAnchor.constraint(equalTo: line.trailingAnchor, constant: 6),
            clear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            clear.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
        line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8).withPriority(.defaultLow).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func clearTapped() { onClear?() }
}

/// The compact address: shield, host, then pinned extension buttons at the
/// trailing edge. Clicking the address opens the palette.
final class URLPill: NSView {
    var onClick: (() -> Void)?
    private let shield = NSImageView()
    private let host = NSTextField(labelWithString: "")
    private let accessories = NSStackView()
    private var style = SidebarStyle()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.tile
        layer?.cornerCurve = .continuous
        shield.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        host.font = .systemFont(ofSize: 12.5)
        host.lineBreakMode = .byTruncatingMiddle
        host.textColor = .labelColor
        accessories.orientation = .horizontal
        accessories.spacing = 2
        for v in [shield, host, accessories] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            shield.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            shield.centerYAnchor.constraint(equalTo: centerYAnchor),
            host.leadingAnchor.constraint(equalTo: shield.trailingAnchor, constant: 8),
            host.trailingAnchor.constraint(lessThanOrEqualTo: accessories.leadingAnchor, constant: -6),
            host.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessories.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            accessories.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel("Address. Click to search or enter a URL.")
        toolTip = "Search or enter address (⌘L)"
    }

    required init?(coder: NSCoder) { fatalError() }

    private var lastUpdate: (String, Bool, Bool, Double, SidebarStyle)?

    func update(host text: String, secure: Bool, blocker: Bool, hue: Double, style: SidebarStyle) {
        if let l = lastUpdate, l.0 == text, l.1 == secure, l.2 == blocker, l.3 == hue, l.4 == style { return }
        lastUpdate = (text, secure, blocker, hue, style)
        self.style = style
        host.stringValue = text.isEmpty ? "Search or enter address" : text
        host.textColor = text.isEmpty ? Tokens.secondaryInk : .labelColor
        let symbol = !secure && !text.isEmpty ? "exclamationmark.shield" : (blocker ? "checkmark.shield" : "shield")
        shield.image = NSImage(systemSymbolName: symbol, accessibilityDescription: secure ? "Secure" : "Not secure")
        shield.contentTintColor = !secure && !text.isEmpty ? .systemOrange : (style.tinted ? .labelColor : Tokens.accent(hue: hue))
        needsDisplay = true
    }

    /// Same buttons in the same order stay put (moving an anchor view closes
    /// any popover shown from it).
    func setAccessories(_ views: [NSView]) {
        if accessories.arrangedSubviews.count == views.count,
           zip(accessories.arrangedSubviews, views).allSatisfy({ $0 === $1 }) { return }
        accessories.arrangedSubviews.forEach { $0.removeFromSuperview() }
        views.forEach(accessories.addArrangedSubview)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = style.pillFill.cgColor
        layer?.borderColor = style.hairline.cgColor
        layer?.borderWidth = 0.5
    }

    override func mouseDown(with event: NSEvent) {
        // Clicks on an extension button go to the button, not the palette.
        let p = convert(event.locationInWindow, from: nil)
        if accessories.frame.contains(p), !accessories.arrangedSubviews.isEmpty { return }
        onClick?()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
}

final class FavoriteTile: NSView {
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private let selected: Bool
    private let style: SidebarStyle

    init(row: SidebarState.Row, selected: Bool, style: SidebarStyle) {
        self.selected = selected
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.tile
        layer?.cornerCurve = .continuous
        let icon = NSImageView()
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 4
        let setIcon: (NSImage) -> Void = { image in
            icon.image = image
            icon.layer?.backgroundColor = style.onDark && Favicons.isDark(image) ? NSColor.white.withAlphaComponent(0.88).cgColor : nil
        }
        setIcon(Favicons.shared.cached(for: row.url) ?? Favicons.placeholder())
        Favicons.shared.load(for: row.url) { image in if let image { setIcon(image) } }
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        // A dot under a favorite that's loaded and live (playing media: accent).
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2
        dot.layer?.backgroundColor = (row.playing ? NSColor.labelColor : NSColor.secondaryLabelColor).cgColor
        dot.isHidden = row.sleeping && !row.playing
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Tokens.Size.favoriteTile),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            dot.widthAnchor.constraint(equalToConstant: 4),
            dot.heightAnchor.constraint(equalToConstant: 4),
        ])
        toolTip = row.title
        setAccessibilityRole(.button)
        setAccessibilityLabel(row.title)
        alphaValue = row.sleeping && !selected ? 0.75 : 1
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (selected ? style.selectionFill : style.quietFill).cgColor
        layer?.borderColor = style.hairline.cgColor
        layer?.borderWidth = 0.5
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

/// A space in the footer switcher: a small squircle of the space's gradient
/// with its icon; the current one gets a ring.
final class SpaceChip: NSView {
    var onClick: (() -> Void)?
    private let gradient = CAGradientLayer()
    private let ring = CALayer()
    private let icon = NSImageView()
    private var isOn = false

    /// CGColors don't follow appearance, so resolve against this view's.
    private func updateRing() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.borderColor = isOn ? NSColor.labelColor.withAlphaComponent(0.85).cgColor : NSColor.clear.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateRing() }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        gradient.cornerRadius = 7
        gradient.cornerCurve = .continuous
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        ring.cornerRadius = 9
        ring.cornerCurve = .continuous
        ring.borderWidth = 1.5
        layer?.addSublayer(ring)
        layer?.addSublayer(gradient)
        icon.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor)])
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds.insetBy(dx: 2, dy: 2)
        ring.frame = bounds
        CATransaction.commit()
    }

    func set(page: SidebarState.Page, on: Bool, style: SidebarStyle) {
        let t = page.theme
        gradient.colors = [t.top, t.bottom].map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1).cgColor }
        let light = t.top.mixed(with: t.bottom, 0.5).luminance > 0.4
        icon.image = NSImage(systemSymbolName: page.icon, accessibilityDescription: nil)
        icon.contentTintColor = light ? NSColor.black.withAlphaComponent(0.7) : NSColor.white.withAlphaComponent(0.9)
        isOn = on
        updateRing()
        alphaValue = on ? 1 : 0.85
        toolTip = page.name
        setAccessibilityLabel(on ? "\(page.name), current space" : "Switch to \(page.name)")
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

// MARK: - Swipe plumbing

/// Claims horizontal two-finger swipes that begin over the sidebar.
final class SwipeHostView: NSView {
    var onSwipeBegan: ((NSEvent) -> Bool)?
    override func scrollWheel(with event: NSEvent) {
        if SwipeHostView.isSwipeStart(event), onSwipeBegan?(event) == true { return }
        super.scrollWheel(with: event)
    }

    static func isSwipeStart(_ e: NSEvent) -> Bool {
        e.phase == .began && e.hasPreciseScrollingDeltas
            && abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) * 1.5
            && NSEvent.isSwipeTrackingFromScrollEventsEnabled
    }
}

/// The tab list scrolls vertically but hands horizontal swipes to the space switcher.
final class SwipeAwareScrollView: NSScrollView {
    var onSwipeBegan: ((NSEvent) -> Bool)?
    override func scrollWheel(with event: NSEvent) {
        if SwipeHostView.isSwipeStart(event), onSwipeBegan?(event) == true { return }
        super.scrollWheel(with: event)
    }
}

/// The mini player for media in a background tab: title, play/pause, PiP.
final class NowPlayingStrip: NSView {
    var onToggle: (() -> Void)?
    var onPiP: (() -> Void)?
    var onOpen: (() -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let host = NSTextField(labelWithString: "")
    private var lastArtwork: URL?
    private let play = SidebarViewController.iconButton("pause.fill", "Pause")
    private let pip = SidebarViewController.iconButton("pip.enter", "Picture in Picture")
    private var style = SidebarStyle()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.tile
        layer?.cornerCurve = .continuous
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 7
        icon.layer?.cornerCurve = .continuous
        icon.layer?.masksToBounds = true
        host.lineBreakMode = .byTruncatingTail
        host.font = .systemFont(ofSize: 10.5)
        host.textColor = Tokens.secondaryInk
        let text = NSStackView(views: [title, host])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        play.target = self; play.action = #selector(toggle)
        pip.target = self; pip.action = #selector(pipTapped)
        let row = NSStackView(views: [icon, text, NSView(), pip, play])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30), icon.heightAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(equalToConstant: 50),
        ])
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Now playing")
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ np: NowPlaying, style: SidebarStyle) {
        self.style = style
        title.stringValue = np.title
        host.stringValue = np.artist.isEmpty ? (np.url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "") : np.artist
        icon.image = Favicons.shared.cached(for: np.url) ?? Favicons.placeholder()
        icon.imageScaling = .scaleProportionallyUpOrDown
        if let art = np.artwork {
            let wanted = art
            Artwork.load(art) { [weak self] image in
                guard let self, let image, self.lastArtwork == wanted else { return }
                self.icon.image = image
                self.icon.imageScaling = .scaleAxesIndependently
            }
        }
        lastArtwork = np.artwork
        play.image = NSImage(systemSymbolName: np.playing ? "pause.fill" : "play.fill", accessibilityDescription: np.playing ? "Pause" : "Play")
        play.toolTip = np.playing ? "Pause" : "Play"
        pip.isHidden = !np.hasVideo
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = style.selectionFill.cgColor
    }

    override func mouseDown(with event: NSEvent) { onOpen?() }
    @objc private func toggle() { onToggle?() }
    @objc private func pipTapped() { onPiP?() }
}

/// Shows a menu on right-click or Control-click; clicks pass through to children.
final class MenuHostView: NSView {
    var menuProvider: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

/// Album art for the now-playing strip: fetched without cookies, cached in memory.
@MainActor
enum Artwork {
    private static var cache: [URL: NSImage] = [:]
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    static func load(_ url: URL, completion: @escaping @MainActor (NSImage?) -> Void) {
        if let image = cache[url] { return completion(image) }
        let session = self.session
        Task { @MainActor in
            let data = try? await session.data(from: url).0
            let image = data.flatMap { NSImage(data: $0) }
            if let image { cache[url] = image; if cache.count > 32 { cache.removeAll() } }
            completion(image)
        }
    }
}


/// One pane of a split row: favicon and title; the focused pane's segment is lifted.
final class SplitSegmentView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private(set) var tabID: TabID?
    private var url: URL?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.tabRow - 3
        layer?.cornerCurve = .continuous
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.imageScaling = .scaleProportionallyUpOrDown
        for v in [icon, label] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Tokens.Size.favicon),
            icon.heightAnchor.constraint(equalToConstant: Tokens.Size.favicon),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ row: SidebarState.Row, focused: Bool, style: SidebarStyle) {
        tabID = row.id
        label.stringValue = row.title
        label.font = .systemFont(ofSize: style.fontSize - 0.5, weight: focused ? .medium : .regular)
        label.textColor = .labelColor
        layer?.backgroundColor = focused ? NSColor.white.withAlphaComponent(style.onDark ? 0.16 : 0.85).cgColor : NSColor.clear.cgColor
        layer?.shadowOpacity = focused && !style.onDark ? 0.10 : 0
        layer?.shadowRadius = 1.5
        layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        alphaValue = row.sleeping && !focused ? 0.7 : 1
        url = row.url
        icon.image = Favicons.shared.cached(for: row.url) ?? Favicons.placeholder()
        if Favicons.shared.cached(for: row.url) == nil {
            let u = row.url
            Favicons.shared.load(for: u) { [weak self] image in
                guard let self, self.url == u, let image else { return }
                self.icon.image = image
            }
        }
    }
}
