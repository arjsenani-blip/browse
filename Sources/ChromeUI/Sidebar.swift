import AppKit
import BrowserCore

/// What the sidebar draws, computed by the window controller from the store.
public struct SidebarState: Equatable {
    public struct Row: Equatable {
        public var id: TabID
        public var title: String
        public var url: URL?
        public var sleeping: Bool
        public var loading: Bool
        public var playing: Bool
        public init(id: TabID, title: String, url: URL?, sleeping: Bool, loading: Bool, playing: Bool) {
            self.id = id; self.title = title; self.url = url; self.sleeping = sleeping; self.loading = loading; self.playing = playing
        }
    }
    public var spaceName: String = ""
    public var spaceIndex: Int = 0
    public var spaceCount: Int = 1
    public var accentHue: Double = 0.48
    public var host: String = ""
    public var isSecure = false
    public var blockerOn = true
    public var canGoBack = false
    public var canGoForward = false
    public var isLoading = false
    public var favorites: [Row] = []
    public var pinned: [Row] = []
    public var today: [Row] = []
    public var selected: TabID?
    /// Every space's name and hue, for the swipe's neighbour placeholders.
    public var spaceNames: [String] = []
    public var spaceHues: [Double] = []
    public var nowPlaying: NowPlaying?
    public var activeDownloads = 0
    public init() {}
}

/// Media playing in a tab you're not looking at.
public struct NowPlaying: Equatable {
    public var tab: TabID
    public var title: String
    public var url: URL?
    public var playing: Bool
    public var hasVideo: Bool
    public init(tab: TabID, title: String, url: URL?, playing: Bool, hasVideo: Bool) {
        self.tab = tab; self.title = title; self.url = url; self.playing = playing; self.hasVideo = hasVideo
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
}

/// The vertical sidebar: navigation, address pill, favorites grid, pinned and
/// today's tabs, and the space switcher. Plain AppKit; rows are reused.
@MainActor
public final class SidebarViewController: NSViewController {
    public weak var delegate: SidebarDelegate?
    private(set) var state = SidebarState()

    private let backButton = SidebarViewController.iconButton("chevron.left", "Back")
    private let forwardButton = SidebarViewController.iconButton("chevron.right", "Forward")
    private let reloadButton = SidebarViewController.iconButton("arrow.clockwise", "Reload")
    private let urlPill = URLPill()
    private let favoritesGrid = NSStackView()
    private let extensionRow = NSStackView()
    private var favoritesTop: NSLayoutConstraint?
    private let table = SidebarTableView()
    private let spaceDots = NSStackView()
    private let spaceLabel = NSTextField(labelWithString: "")
    private var rows: [Item] = []
    private let content = NSView()
    private let nowPlayingView = NowPlayingStrip()
    private let libraryButton = SidebarViewController.iconButton("tray.and.arrow.down", "Library: Downloads and Media")
    private let libraryBadge = NSTextField(labelWithString: "")
    // Swipe between spaces
    private let leftPane = NSImageView()
    private let rightPane = NSImageView()
    private let wash = NSView()
    private var snapshots: [Int: NSImage] = [:]
    private var swiping = false

    enum Item: Equatable {
        case tab(SidebarState.Row, TabTier)
        case divider
        case newTab
    }

    public override func loadView() {
        let host = SwipeHostView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        host.onSwipeBegan = { [weak self] event in self?.trackSwipe(event) ?? false }
        wash.wantsLayer = true
        for v in [wash, leftPane, rightPane, content] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(v)
        }
        content.wantsLayer = true
        for pane in [leftPane, rightPane] {
            pane.imageScaling = .scaleNone
            pane.imageAlignment = .alignTopLeft
            pane.wantsLayer = true
            pane.isHidden = true
        }
        NSLayoutConstraint.activate([
            wash.leadingAnchor.constraint(equalTo: host.leadingAnchor), wash.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            wash.topAnchor.constraint(equalTo: host.topAnchor), wash.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor), content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor), content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            leftPane.trailingAnchor.constraint(equalTo: content.leadingAnchor), leftPane.widthAnchor.constraint(equalTo: content.widthAnchor),
            leftPane.topAnchor.constraint(equalTo: host.topAnchor), leftPane.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            rightPane.leadingAnchor.constraint(equalTo: content.trailingAnchor), rightPane.widthAnchor.constraint(equalTo: content.widthAnchor),
            rightPane.topAnchor.constraint(equalTo: host.topAnchor), rightPane.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        let root = content

        let nav = NSStackView(views: [backButton, forwardButton, reloadButton])
        nav.spacing = 6
        backButton.target = self; backButton.action = #selector(back)
        forwardButton.target = self; forwardButton.action = #selector(forward)
        reloadButton.target = self; reloadButton.action = #selector(reload)

        urlPill.onClick = { [weak self] in self?.delegate?.sidebarOpenPalette() }

        favoritesGrid.orientation = .horizontal
        favoritesGrid.distribution = .fillEqually
        favoritesGrid.spacing = 8

        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = Tokens.Size.tabRow
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
            guard let self, row >= 0, row < self.rows.count, case .tab(let r, _) = self.rows[row] else { return nil }
            return self.delegate?.sidebarContextMenu(for: r.id)
        }
        let scroll = SwipeAwareScrollView()
        scroll.onSwipeBegan = { [weak self] event in self?.trackSwipe(event) ?? false }
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false

        let spaceMenuHost = MenuHostView()
        spaceMenuHost.menuProvider = { [weak self] in self?.delegate?.sidebarSpaceMenu() }
        spaceLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        spaceLabel.textColor = Tokens.secondaryInk
        spaceDots.spacing = 8
        let newTab = SidebarViewController.iconButton("plus", "New Tab (⌘T)")
        newTab.target = self; newTab.action = #selector(newTabClicked)
        libraryButton.target = self; libraryButton.action = #selector(libraryClicked)
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
        let spaceGroup = NSStackView(views: [spaceDots, spaceLabel])
        spaceGroup.spacing = 8
        spaceGroup.translatesAutoresizingMaskIntoConstraints = false
        spaceMenuHost.addSubview(spaceGroup)
        NSLayoutConstraint.activate([
            spaceGroup.leadingAnchor.constraint(equalTo: spaceMenuHost.leadingAnchor), spaceGroup.trailingAnchor.constraint(equalTo: spaceMenuHost.trailingAnchor),
            spaceGroup.topAnchor.constraint(equalTo: spaceMenuHost.topAnchor), spaceGroup.bottomAnchor.constraint(equalTo: spaceMenuHost.bottomAnchor),
        ])
        spaceMenuHost.toolTip = "Swipe with two fingers to switch spaces. Right-click to rename."
        let footer = NSStackView(views: [spaceMenuHost, NSView(), libraryButton, newTab])
        footer.spacing = 8
        nowPlayingView.onToggle = { [weak self] in if let id = self?.state.nowPlaying?.tab { self?.delegate?.sidebarToggleMedia(id) } }
        nowPlayingView.onPiP = { [weak self] in if let id = self?.state.nowPlaying?.tab { self?.delegate?.sidebarPictureInPicture(id) } }
        nowPlayingView.onOpen = { [weak self] in if let id = self?.state.nowPlaying?.tab { self?.delegate?.sidebarSelect(id) } }
        nowPlayingView.isHidden = true

        extensionRow.orientation = .horizontal
        extensionRow.spacing = 6
        extensionRow.isHidden = true
        for v in [nav, urlPill, extensionRow, favoritesGrid, scroll, nowPlayingView, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let pad = Tokens.Space.sidebarPadding
        NSLayoutConstraint.activate([
            nav.topAnchor.constraint(equalTo: root.topAnchor, constant: 11),
            nav.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad - 4),
            urlPill.topAnchor.constraint(equalTo: root.topAnchor, constant: 44),
            urlPill.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            urlPill.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            urlPill.heightAnchor.constraint(equalToConstant: Tokens.Size.urlPill),
            extensionRow.topAnchor.constraint(equalTo: urlPill.bottomAnchor, constant: 8),
            extensionRow.leadingAnchor.constraint(equalTo: urlPill.leadingAnchor, constant: 6),
            extensionRow.heightAnchor.constraint(equalToConstant: 22),
            favoritesGrid.topAnchor.constraint(equalTo: extensionRow.bottomAnchor, constant: Tokens.Space.sectionGap - 8),
            favoritesGrid.leadingAnchor.constraint(equalTo: urlPill.leadingAnchor),
            favoritesGrid.trailingAnchor.constraint(equalTo: urlPill.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: favoritesGrid.bottomAnchor, constant: Tokens.Space.sectionGap),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            scroll.bottomAnchor.constraint(equalTo: nowPlayingView.topAnchor, constant: -6),
            nowPlayingView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            nowPlayingView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            nowPlayingView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad + 10),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad - 4),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            footer.heightAnchor.constraint(equalToConstant: 24),
        ])
        view = host
    }

    public func apply(_ new: SidebarState) {
        let old = state
        state = new
        backButton.isEnabled = new.canGoBack
        forwardButton.isEnabled = new.canGoForward
        reloadButton.image = NSImage(systemSymbolName: new.isLoading ? "xmark" : "arrow.clockwise", accessibilityDescription: new.isLoading ? "Stop" : "Reload")
        urlPill.update(host: new.host, secure: new.isSecure, blocker: new.blockerOn, hue: new.accentHue)
        if old.nowPlaying != new.nowPlaying {
            if let np = new.nowPlaying { nowPlayingView.update(np, hue: new.accentHue) }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Tokens.Motion.duration(0.2)
                nowPlayingView.animator().isHidden = new.nowPlaying == nil
            }
        }
        libraryBadge.isHidden = new.activeDownloads == 0
        libraryBadge.stringValue = "\(new.activeDownloads)"
        libraryBadge.layer?.backgroundColor = Tokens.accent(hue: new.accentHue).cgColor
        libraryButton.contentTintColor = new.activeDownloads > 0 ? Tokens.accent(hue: new.accentHue) : Tokens.secondaryInk
        if !swiping { wash.layer?.backgroundColor = Tokens.accent(hue: new.accentHue).withAlphaComponent(0.05).cgColor }
        if old.spaceIndex != new.spaceIndex, !swiping, old.spaceCount == new.spaceCount, !old.spaceNames.isEmpty {
            slideIn(from: new.spaceIndex > old.spaceIndex ? 1 : -1)
        }

        if old.favorites != new.favorites || old.selected != new.selected || old.accentHue != new.accentHue || favoritesGrid.arrangedSubviews.isEmpty {
            rebuildFavorites()
        }
        if old.spaceIndex != new.spaceIndex || old.spaceCount != new.spaceCount || old.spaceName != new.spaceName || old.accentHue != new.accentHue || spaceDots.arrangedSubviews.isEmpty {
            rebuildSpaces()
        }

        var items: [Item] = new.pinned.map { .tab($0, .pinned) }
        items.append(.divider)
        items.append(.newTab)
        items += new.today.map { .tab($0, .today) }
        if items != rows || old.selected != new.selected || old.accentHue != new.accentHue {
            let sameShape = items.count == rows.count && zip(items, rows).allSatisfy { a, b in
                if case .tab(let x, _) = a, case .tab(let y, _) = b { return x.id == y.id }
                return a == b
            }
            rows = items
            if sameShape {
                table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count), columnIndexes: [0])
            } else {
                table.reloadData()
            }
        }
    }

    private func rebuildFavorites() {
        favoritesGrid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        favoritesGrid.isHidden = state.favorites.isEmpty
        for fav in state.favorites.prefix(8) {
            let tile = FavoriteTile(row: fav, selected: fav.id == state.selected, hue: state.accentHue)
            tile.onClick = { [weak self] in self?.delegate?.sidebarSelect(fav.id) }
            tile.menuProvider = { [weak self] in self?.delegate?.sidebarContextMenu(for: fav.id) }
            favoritesGrid.addArrangedSubview(tile)
        }
    }

    private func rebuildSpaces() {
        spaceDots.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for i in 0..<state.spaceCount {
            let dot = SpaceDot(on: i == state.spaceIndex, hue: state.accentHue)
            dot.onClick = { [weak self] in self?.delegate?.sidebarSwitchSpace(i) }
            spaceDots.addArrangedSubview(dot)
        }
        spaceLabel.stringValue = state.spaceName
    }

    @objc private func back() { delegate?.sidebarBack() }
    @objc private func forward() { delegate?.sidebarForward() }
    @objc private func reload() { delegate?.sidebarReload() }
    @objc private func newTabClicked() { delegate?.sidebarNewTab() }
    @objc private func libraryClicked() { delegate?.sidebarOpenLibrary(from: libraryButton) }

    /// Extension toolbar buttons, shown under the address pill.
    public func setExtensionButtons(_ buttons: [NSView]) {
        // Same buttons in the same order: leave them in place (moving an
        // anchor view closes any popover shown from it).
        if extensionRow.arrangedSubviews.count == buttons.count,
           zip(extensionRow.arrangedSubviews, buttons).allSatisfy({ $0 === $1 }) { return }
        extensionRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.forEach(extensionRow.addArrangedSubview)
        extensionRow.isHidden = buttons.isEmpty
    }

    // MARK: Swipe between spaces

    /// Remembers how the current space looks, so swiping back to it can show it.
    public func cacheCurrentSpaceSnapshot() {
        guard content.bounds.width > 0, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(rep)
        snapshots[state.spaceIndex] = image
    }

    private func neighbourImage(_ index: Int) -> NSImage? {
        guard index >= 0, index < state.spaceCount else { return nil }
        if let cached = snapshots[index], cached.size == content.bounds.size { return cached }
        // Never visited this session: a quiet placeholder with the space's name.
        let size = content.bounds.size
        let name = index < state.spaceNames.count ? state.spaceNames[index] : "Space \(index + 1)"
        let hue = index < state.spaceHues.count ? state.spaceHues[index] : state.accentHue
        return NSImage(size: size, flipped: true) { _ in
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: Tokens.accent(hue: hue)]
            (name as NSString).draw(at: NSPoint(x: 20, y: 52), withAttributes: attrs)
            NSColor.tertiaryLabelColor.withAlphaComponent(0.25).setFill()
            for row in 0..<6 {
                NSBezierPath(roundedRect: NSRect(x: 20, y: 96 + CGFloat(row) * 34, width: size.width * [0.6, 0.45, 0.7, 0.5, 0.65, 0.4][row], height: 8), xRadius: 4, yRadius: 4).fill()
            }
            return true
        }
    }

    /// Interactive two-finger swipe, tracked by the system (rubber-banding and
    /// the commit decision match Safari and Finder). Layers move; nothing lays out.
    private func trackSwipe(_ event: NSEvent) -> Bool {
        guard state.spaceCount > 1, !swiping else { return false }
        let index = state.spaceIndex, count = state.spaceCount
        let width = content.bounds.width
        cacheCurrentSpaceSnapshot()
        leftPane.image = neighbourImage(index - 1)
        rightPane.image = neighbourImage(index + 1)
        leftPane.isHidden = leftPane.image == nil
        rightPane.isHidden = rightPane.image == nil
        swiping = true
        let fromHue = state.accentHue
        var warmed = false
        // gestureAmount > 0 means a swipe to the right, which reveals the space on the left.
        event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount],
                              dampenAmountThresholdMin: -CGFloat(count - 1 - index), max: CGFloat(index)) { [weak self] amount, phase, complete, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = amount
                self.setSwipeOffset(p * width, fromHue: fromHue)
                if !warmed, abs(p) > 0.35 {
                    warmed = true
                    self.delegate?.sidebarWillSwipe(toSpace: p > 0 ? index - 1 : index + 1)
                }
                if complete {
                    let target = p > 0.5 ? index - 1 : (p < -0.5 ? index + 1 : index)
                    self.finishSwipe(to: target)
                }
                _ = phase
            }
        }
        return true
    }

    private func setSwipeOffset(_ x: CGFloat, fromHue: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let t = CATransform3DMakeTranslation(x, 0, 0)
        content.layer?.transform = t
        leftPane.layer?.transform = t
        rightPane.layer?.transform = t
        // Cross-fade the space tint with the distance travelled.
        let w = max(1, content.bounds.width)
        let neighbour = x > 0 ? state.spaceIndex - 1 : state.spaceIndex + 1
        if neighbour >= 0, neighbour < state.spaceHues.count {
            let f = min(1, abs(x) / w)
            let a = Tokens.accent(hue: fromHue).withAlphaComponent(0.05 * (1 - f))
            let b = Tokens.accent(hue: state.spaceHues[neighbour]).withAlphaComponent(0.05 * f)
            wash.layer?.backgroundColor = (a.blended(withFraction: f, of: b) ?? a).cgColor
        }
        CATransaction.commit()
    }

    private func finishSwipe(to target: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for v in [content, leftPane, rightPane] { v.layer?.transform = CATransform3DIdentity }
        leftPane.isHidden = true
        rightPane.isHidden = true
        CATransaction.commit()
        swiping = false
        if target != state.spaceIndex { delegate?.sidebarSwitchSpace(target) }
    }

    /// Keyboard or dot switch: the new space slides in with a spring (or fades
    /// with Reduce Motion), matching the swipe's direction.
    private func slideIn(from direction: CGFloat) {
        guard let layer = content.layer else { return }
        if Tokens.Motion.reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.18
            layer.add(fade, forKey: "spaceFade")
            return
        }
        let spring = CASpringAnimation(keyPath: "transform.translation.x")
        let response = 0.32, damping = 1.0
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / response, 2)
        spring.damping = 4 * .pi * damping / response
        spring.fromValue = direction * content.bounds.width * 0.35
        spring.toValue = 0
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "spaceSlide")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.4; fade.toValue = 1; fade.duration = 0.22
        layer.add(fade, forKey: "spaceFade")
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        switch rows[row] {
        case .tab(let r, _): delegate?.sidebarSelect(r.id)
        case .newTab: delegate?.sidebarNewTab()
        case .divider: break
        }
    }

    static func iconButton(_ symbol: String, _ label: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: nil)
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

// MARK: - Table

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .divider = rows[row] { return 26 }
        return Tokens.Size.tabRow
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .divider:
            let v = tableView.makeView(withIdentifier: DividerCell.id, owner: nil) as? DividerCell ?? DividerCell()
            return v
        case .newTab:
            let v = tableView.makeView(withIdentifier: TabCell.id, owner: nil) as? TabCell ?? TabCell()
            v.configureNewTab()
            return v
        case .tab(let r, _):
            let v = tableView.makeView(withIdentifier: TabCell.id, owner: nil) as? TabCell ?? TabCell()
            v.configure(r, selected: r.id == state.selected, hue: state.accentHue)
            v.onClose = { [weak self] in self?.delegate?.sidebarClose(r.id) }
            return v
        }
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard case .tab(let r, _) = rows[row] else { return nil }
        let item = NSPasteboardItem()
        item.setString(r.id.description, forType: .aegisTab)
        if let url = r.url { item.setString(url.absoluteString, forType: .string) }
        return item
    }

    public func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return info.draggingPasteboard.string(forType: .aegisTab) == nil ? [] : .move
    }

    public func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let raw = info.draggingPasteboard.string(forType: .aegisTab), let uuid = UUID(uuidString: raw) else { return false }
        let id = TabID(uuid)
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
    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = TabCell.id
        background.wantsLayer = true
        background.layer?.cornerRadius = Tokens.Radius.tabRow
        background.layer?.cornerCurve = .continuous
        label.font = .systemFont(ofSize: 13)
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
        for v in [background, icon, label, audio, closeButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
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
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ row: SidebarState.Row, selected: Bool, hue: Double) {
        label.stringValue = row.title
        label.textColor = selected ? Tokens.accent(hue: hue) : .labelColor
        label.font = .systemFont(ofSize: 13, weight: selected ? .medium : .regular)
        background.layer?.backgroundColor = selected ? Tokens.selectionFill(hue: hue).cgColor : NSColor.clear.cgColor
        alphaValue = row.sleeping && !selected ? 0.55 : 1
        audio.isHidden = !row.playing
        toolTip = row.sleeping ? "\(row.title) — sleeping" : row.title
        setAccessibilityLabel(row.title)
        currentURL = row.url
        icon.image = Favicons.shared.cached(for: row.url) ?? Favicons.placeholder()
        icon.contentTintColor = nil
        if Favicons.shared.cached(for: row.url) == nil {
            let url = row.url
            Favicons.shared.load(for: url) { [weak self] image in
                guard let self, self.currentURL == url, let image else { return }
                self.icon.image = image
            }
        }
        closeButton.isHidden = true
    }

    func configureNewTab() {
        label.stringValue = "New Tab"
        label.textColor = Tokens.secondaryInk
        label.font = .systemFont(ofSize: 13)
        background.layer?.backgroundColor = NSColor.clear.cgColor
        icon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        icon.contentTintColor = Tokens.secondaryInk
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

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = onClose == nil }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { onClose?() } }
    @objc private func closeClicked() { onClose?() }
}

final class DividerCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("DividerCell")
    init() {
        super.init(frame: .zero)
        identifier = DividerCell.id
        let label = NSTextField(labelWithString: "Today")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Tokens.secondaryInk
        let line = NSBox()
        line.boxType = .separator
        for v in [label, line] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The compact address: shield, host, blocked state. Clicking opens the palette.
final class URLPill: NSView {
    var onClick: (() -> Void)?
    private let shield = NSImageView()
    private let host = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.tile
        layer?.cornerCurve = .continuous
        shield.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        host.font = .systemFont(ofSize: 12.5)
        host.lineBreakMode = .byTruncatingMiddle
        host.textColor = .labelColor
        for v in [shield, host] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            shield.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            shield.centerYAnchor.constraint(equalTo: centerYAnchor),
            host.leadingAnchor.constraint(equalTo: shield.trailingAnchor, constant: 8),
            host.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            host.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel("Address. Click to search or enter a URL.")
        toolTip = "Search or enter address (⌘L)"
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(host text: String, secure: Bool, blocker: Bool, hue: Double) {
        host.stringValue = text.isEmpty ? "Search or enter address" : text
        host.textColor = text.isEmpty ? Tokens.secondaryInk : .labelColor
        let symbol = !secure && !text.isEmpty ? "exclamationmark.shield" : (blocker ? "checkmark.shield" : "shield")
        shield.image = NSImage(systemSymbolName: symbol, accessibilityDescription: secure ? "Secure" : "Not secure")
        shield.contentTintColor = !secure && !text.isEmpty ? .systemOrange : Tokens.accent(hue: hue)
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        layer?.borderWidth = 0.5
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
}

final class FavoriteTile: NSView {
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private let selected: Bool
    private let hue: Double

    init(row: SidebarState.Row, selected: Bool, hue: Double) {
        self.selected = selected
        self.hue = hue
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.tile
        layer?.cornerCurve = .continuous
        let icon = NSImageView()
        icon.image = Favicons.shared.cached(for: row.url) ?? Favicons.placeholder()
        Favicons.shared.load(for: row.url) { image in if let image { icon.image = image } }
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Tokens.Size.favoriteTile),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
        ])
        toolTip = row.title
        setAccessibilityRole(.button)
        setAccessibilityLabel(row.title)
        alphaValue = row.sleeping && !selected ? 0.7 : 1
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (selected ? Tokens.selectionFill(hue: hue) : NSColor.controlBackgroundColor.withAlphaComponent(0.55)).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        layer?.borderWidth = 0.5
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

final class SpaceDot: NSView {
    var onClick: (() -> Void)?
    private let on: Bool
    private let hue: Double
    init(on: Bool, hue: Double) {
        self.on = on
        self.hue = hue
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 8).isActive = true
        heightAnchor.constraint(equalToConstant: 8).isActive = true
        setAccessibilityRole(.button)
        setAccessibilityLabel(on ? "Current space" : "Switch space")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (on ? Tokens.accent(hue: hue) : NSColor.tertiaryLabelColor).cgColor
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
    private let play = SidebarViewController.iconButton("pause.fill", "Pause")
    private let pip = SidebarViewController.iconButton("pip.enter", "Picture in Picture")
    private var hue = 0.48

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.tile
        layer?.cornerCurve = .continuous
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
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
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            heightAnchor.constraint(equalToConstant: 44),
        ])
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Now playing")
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ np: NowPlaying, hue: Double) {
        self.hue = hue
        title.stringValue = np.title
        host.stringValue = np.url?.host() ?? ""
        icon.image = Favicons.shared.cached(for: np.url) ?? Favicons.placeholder()
        play.image = NSImage(systemSymbolName: np.playing ? "pause.fill" : "play.fill", accessibilityDescription: np.playing ? "Pause" : "Play")
        play.toolTip = np.playing ? "Pause" : "Play"
        pip.isHidden = !np.hasVideo
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Tokens.selectionFill(hue: hue).cgColor
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
