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
    public init() {}
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
    private let table = SidebarTableView()
    private let spaceDots = NSStackView()
    private let spaceLabel = NSTextField(labelWithString: "")
    private var rows: [Item] = []

    enum Item: Equatable {
        case tab(SidebarState.Row, TabTier)
        case divider
        case newTab
    }

    public override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

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
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false

        spaceLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        spaceLabel.textColor = Tokens.secondaryInk
        spaceDots.spacing = 8
        let newTab = SidebarViewController.iconButton("plus", "New Tab (⌘T)")
        newTab.target = self; newTab.action = #selector(newTabClicked)
        let footer = NSStackView(views: [spaceDots, spaceLabel, NSView(), newTab])
        footer.spacing = 8

        for v in [nav, urlPill, favoritesGrid, scroll, footer] as [NSView] {
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
            favoritesGrid.topAnchor.constraint(equalTo: urlPill.bottomAnchor, constant: Tokens.Space.sectionGap),
            favoritesGrid.leadingAnchor.constraint(equalTo: urlPill.leadingAnchor),
            favoritesGrid.trailingAnchor.constraint(equalTo: urlPill.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: favoritesGrid.bottomAnchor, constant: Tokens.Space.sectionGap),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad + 10),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad - 4),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            footer.heightAnchor.constraint(equalToConstant: 24),
        ])
        view = root
    }

    public func apply(_ new: SidebarState) {
        let old = state
        state = new
        backButton.isEnabled = new.canGoBack
        forwardButton.isEnabled = new.canGoForward
        reloadButton.image = NSImage(systemSymbolName: new.isLoading ? "xmark" : "arrow.clockwise", accessibilityDescription: new.isLoading ? "Stop" : "Reload")
        urlPill.update(host: new.host, secure: new.isSecure, blocker: new.blockerOn, hue: new.accentHue)

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
