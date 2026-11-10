import AppKit
import BrowserCore

/// The horizontal layout: navigation, a compact address pill and a strip of
/// tab chips above the page. Driven by the same SidebarState as the sidebar.
@MainActor
public final class TopTabBar: NSView {
    public weak var delegate: SidebarDelegate?
    private let back = SidebarViewController.iconButton("chevron.left", "Back")
    private let forward = SidebarViewController.iconButton("chevron.right", "Forward")
    private let reload = SidebarViewController.iconButton("arrow.clockwise", "Reload")
    private let pill = URLPill()
    private let strip = NSStackView()
    private let scroll = NSScrollView()
    private let newTab = SidebarViewController.iconButton("plus", "New Tab (⌘T)")
    private var state = SidebarState()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        back.target = self; back.action = #selector(goBack)
        forward.target = self; forward.action = #selector(goForward)
        reload.target = self; reload.action = #selector(doReload)
        newTab.target = self; newTab.action = #selector(addTab)
        pill.onClick = { [weak self] in self?.delegate?.sidebarOpenPalette() }
        strip.orientation = .horizontal
        strip.spacing = 4
        strip.alignment = .centerY
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        strip.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(strip)
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        let nav = NSStackView(views: [back, forward, reload])
        nav.spacing = 4
        for v in [nav, pill, scroll, newTab] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            // Room for the traffic lights.
            nav.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 78),
            nav.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.leadingAnchor.constraint(equalTo: nav.trailingAnchor, constant: 10),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.widthAnchor.constraint(equalToConstant: 240),
            pill.heightAnchor.constraint(equalToConstant: 28),
            scroll.leadingAnchor.constraint(equalTo: pill.trailingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: newTab.leadingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            newTab.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            newTab.centerYAnchor.constraint(equalTo: centerYAnchor),
            strip.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            strip.topAnchor.constraint(equalTo: doc.topAnchor),
            strip.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.trailingAnchor.constraint(equalTo: strip.trailingAnchor),
            doc.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            doc.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
        ])
        setAccessibilityRole(.toolbar)
    }

    required init?(coder: NSCoder) { fatalError() }

    public func apply(_ new: SidebarState) {
        let old = state
        state = new
        back.isEnabled = new.canGoBack
        forward.isEnabled = new.canGoForward
        reload.image = NSImage(systemSymbolName: new.isLoading ? "xmark" : "arrow.clockwise", accessibilityDescription: nil)
        pill.update(host: new.host, secure: new.isSecure, blocker: new.blockerOn, hue: new.accentHue, style: new.style)
        guard old.favorites != new.favorites || old.pinned != new.pinned || old.today != new.today
                || old.selected != new.selected || old.accentHue != new.accentHue || strip.arrangedSubviews.isEmpty else { return }
        strip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Favorites and pinned as icon-only chips, then today's tabs, oldest first like a classic tab bar.
        for row in new.favorites + new.pinned {
            strip.addArrangedSubview(chip(row, compact: true))
        }
        for row in new.today.reversed() {
            strip.addArrangedSubview(chip(row, compact: false))
        }
        if let selected = new.selected, let view = strip.arrangedSubviews.first(where: { ($0 as? TabChip)?.id == selected }) {
            DispatchQueue.main.async { view.scrollToVisible(view.bounds) }
        }
    }

    private func chip(_ row: SidebarState.Row, compact: Bool) -> TabChip {
        let c = TabChip(row: row, selected: row.id == state.selected, hue: state.accentHue, compact: compact, fill: state.style.selectionFill)
        c.onSelect = { [weak self] in self?.delegate?.sidebarSelect(row.id) }
        c.onClose = { [weak self] in self?.delegate?.sidebarClose(row.id) }
        c.menuProvider = { [weak self] in self?.delegate?.sidebarContextMenu(for: row.id) }
        return c
    }

    @objc private func goBack() { delegate?.sidebarBack() }
    @objc private func goForward() { delegate?.sidebarForward() }
    @objc private func doReload() { delegate?.sidebarReload() }
    @objc private func addTab() { delegate?.sidebarNewTab() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class TabChip: NSView {
    let id: TabID
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private let selected: Bool
    private let hue: Double
    private let close = NSButton()
    private var tracking: NSTrackingArea?

    private let fill: NSColor

    init(row: SidebarState.Row, selected: Bool, hue: Double, compact: Bool, fill: NSColor) {
        id = row.id
        self.fill = fill
        self.selected = selected
        self.hue = hue
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.tabRow
        layer?.cornerCurve = .continuous
        let icon = NSImageView()
        icon.image = Favicons.shared.cached(for: row.url) ?? Favicons.placeholder()
        if Favicons.shared.cached(for: row.url) == nil { Favicons.shared.load(for: row.url) { if let i = $0 { icon.image = i } } }
        let label = NSTextField(labelWithString: row.title)
        label.font = .systemFont(ofSize: 12, weight: selected ? .medium : .regular)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.isHidden = compact
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        close.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        close.isBordered = false
        close.contentTintColor = Tokens.secondaryInk
        close.target = self
        close.action = #selector(closeTapped)
        close.isHidden = true
        for v in [icon, label, close] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: compact ? 8 : 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 16),
        ])
        if compact {
            widthAnchor.constraint(equalToConstant: 32).isActive = true
            close.isHidden = true
        } else {
            widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
            widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
            let preferred = widthAnchor.constraint(equalToConstant: 200)
            preferred.priority = .defaultLow
            preferred.isActive = true
        }
        alphaValue = row.sleeping && !selected ? 0.6 : 1
        toolTip = row.title
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(row.title)
        setAccessibilityValue(selected ? 1 : 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (selected ? fill : .clear).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { if (constraints.first { $0.firstAttribute == .width && $0.constant == 32 }) == nil { close.isHidden = false } }
    override func mouseExited(with event: NSEvent) { close.isHidden = true }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { onClose?() } }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
    @objc private func closeTapped() { onClose?() }
}
