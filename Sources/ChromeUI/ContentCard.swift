import AppKit

/// The page as an opaque, rounded card inset in the window. Hosts whichever
/// web view (or reader view) is current, a thin progress line, and the
/// sleeping-tab snapshot while a tab wakes.
@MainActor
public final class ContentCard: NSView {
    private let clip = NSView()
    private let progress = ProgressLine()
    private let snapshotView = NSImageView()
    private let emptyView = NSHostingSafeEmptyView()
    public private(set) var current: NSView?
    /// When each page view last left the card. WebKit doesn't always repaint a page that sat
    /// detached (and its process suspended) for minutes: it comes back white though fully loaded.
    private var detachedAt: [ObjectIdentifier: CFTimeInterval] = [:]
    private var trailing: NSLayoutConstraint?
    /// Split panes only: an × on hover that takes this pane out of the split (the tab stays open).
    public var onUnsplit: (() -> Void)?
    private let unsplitButton = NSButton()
    private var hoverArea: NSTrackingArea?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.contentCard
        layer?.cornerCurve = .continuous
        // Lifted off the coloured frame: a soft ambient shadow plus a tight contact one.
        layer?.shadowOpacity = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0 : 0.22
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -6)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Tokens.Radius.contentCard
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        unsplitButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove from Split View")
        unsplitButton.symbolConfiguration = .init(pointSize: 10, weight: .bold)
        unsplitButton.isBordered = false
        unsplitButton.wantsLayer = true
        unsplitButton.layer?.cornerRadius = 11
        unsplitButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        unsplitButton.contentTintColor = .white
        unsplitButton.toolTip = "Remove from Split View (⌃⇧−). The tab stays open."
        unsplitButton.target = self
        unsplitButton.action = #selector(unsplitClicked)
        unsplitButton.alphaValue = 0
        unsplitButton.isHidden = true
        clip.layer?.borderWidth = 0.5
        snapshotView.imageScaling = .scaleAxesIndependently
        snapshotView.isHidden = true
        for v in [clip] as [NSView] { pin(v, in: self) }
        pin(emptyView, in: clip)
        pin(snapshotView, in: clip)
        progress.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(progress)
        NSLayoutConstraint.activate([
            progress.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            progress.topAnchor.constraint(equalTo: clip.topAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    public override var wantsUpdateLayer: Bool { true }
    /// nil: not split. true/false: a split pane, focused or not; the focused one gets an accent ring.
    private var paneFocus: Bool?
    private var paneHue: Double = 0.48

    @objc private func unsplitClicked() { onUnsplit?() }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a)
        hoverArea = a
    }

    public override func mouseEntered(with event: NSEvent) { setUnsplitVisible(paneFocus != nil) }
    public override func mouseExited(with event: NSEvent) { setUnsplitVisible(false) }

    private func setUnsplitVisible(_ visible: Bool) {
        if unsplitButton.superview == nil {
            unsplitButton.translatesAutoresizingMaskIntoConstraints = false
            addSubview(unsplitButton)
            NSLayoutConstraint.activate([
                unsplitButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                unsplitButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                unsplitButton.widthAnchor.constraint(equalToConstant: 22),
                unsplitButton.heightAnchor.constraint(equalToConstant: 22),
            ])
        }
        addSubview(unsplitButton, positioned: .above, relativeTo: nil)
        if visible { unsplitButton.isHidden = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Tokens.Motion.duration(0.12)
            unsplitButton.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { if !visible, self?.unsplitButton.alphaValue == 0 { self?.unsplitButton.isHidden = true } }
        })
    }

    public func setPaneFocus(_ focus: Bool?, hue: Double) {
        if focus == nil { setUnsplitVisible(false) }
        guard focus != paneFocus || hue != paneHue else { return }
        paneFocus = focus
        paneHue = hue
        needsDisplay = true
        applyBorder()
    }

    private func applyBorder() {
        let ring = paneFocus == true && !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? Tokens.accent(hue: paneHue).withAlphaComponent(0.8) : nil
        let contrast = paneFocus == true ? NSColor.controlAccentColor : NSColor.separatorColor
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Tokens.Motion.duration(0.15)
            clip.layer?.borderWidth = paneFocus == true ? 2 : 0.5
            clip.layer?.borderColor = (ring ?? contrast).cgColor
        }
    }

    public override func updateLayer() {
        clip.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        applyBorder()
        layer?.shadowColor = NSColor.black.cgColor
    }

    /// Shows a view in the card, replacing the previous one.
    public func show(_ view: NSView?, snapshot: NSImage? = nil, crossfade: Bool = false) {
        if current === view { return }
        if crossfade, !Tokens.Motion.reduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.layer?.add(fade, forKey: "swap")
        }
        if let old = current {
            if detachedAt.count > 256 { detachedAt.removeAll() }
            detachedAt[ObjectIdentifier(old)] = CACurrentMediaTime()
        }
        // A page can move to another pane's card; only take it out if it's still ours.
        if let old = current, old.superview === clip { old.removeFromSuperview() }
        current = view
        emptyView.isHidden = view != nil
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = false
            clip.addSubview(view, positioned: .below, relativeTo: snapshotView)
            let trailing = view.trailingAnchor.constraint(equalTo: clip.trailingAnchor)
            self.trailing = trailing
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                trailing,
                view.topAnchor.constraint(equalTo: clip.topAnchor),
                view.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            ])
            let key = ObjectIdentifier(view)
            if let left = detachedAt.removeValue(forKey: key), CACurrentMediaTime() - left > 20 {
                forceRepaint(view, trailing: trailing)
            }
        }
        if let snapshot {
            snapshotView.image = snapshot
            snapshotView.isHidden = false
            snapshotView.alphaValue = 1
            // Never leave a stale picture over a live page, whatever the load does.
            let shown = snapshot
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.snapshotView.image === shown else { return }
                self.dismissSnapshot()
            }
        } else {
            snapshotView.isHidden = true
        }
    }

    /// True while the wake snapshot covers the page (debug harness).
    public var isSnapshotCovering: Bool { !snapshotView.isHidden && snapshotView.alphaValue > 0 }

    /// A one-pixel resize for a single frame: WebKit relayouts and repaints every tile, which
    /// brings back a page that would otherwise stay blank. Invisible at the card's edge.
    private func forceRepaint(_ view: NSView, trailing: NSLayoutConstraint) {
        trailing.constant = -1
        layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard self?.trailing === trailing else { return }
            trailing.constant = 0
        }
    }

    /// Fades the wake snapshot once the real page has painted.
    public func dismissSnapshot() {
        guard !snapshotView.isHidden else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Tokens.Motion.duration(0.2)
            snapshotView.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.snapshotView.isHidden = true }
        })
    }

    /// Hidden while the palette is open, so the two never stack.
    public func setEmptyStateHidden(_ hidden: Bool) {
        emptyView.alphaValue = hidden ? 0 : 1
    }

    public func setCornerRadius(_ r: CGFloat) {
        layer?.cornerRadius = r
        clip.layer?.cornerRadius = r
    }

    private var lastProgress: (Double, Bool, Double)?

    public func setProgress(_ value: Double, loading: Bool, hue: Double) {
        // Redraws are frequent; only animate when the bar actually changes.
        if let last = lastProgress, last.0 == value, last.1 == loading, last.2 == hue { return }
        lastProgress = (value, loading, hue)
        progress.color = Tokens.accent(hue: hue)
        progress.set(value: loading ? value : 1, visible: loading)
    }

    private func pin(_ v: NSView, in parent: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            v.topAnchor.constraint(equalTo: parent.topAnchor),
            v.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }
}

/// Shown when a space has no tabs.
final class NSHostingSafeEmptyView: NSView {
    init() {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: "Nothing open")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let hint = NSTextField(labelWithString: "Press ⌘T or ⌘K to search or open a site.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [title, hint])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class ProgressLine: NSView {
    var color: NSColor = .controlAccentColor { didSet { bar.layer?.backgroundColor = color.cgColor } }
    private let bar = NSView()
    private var width: NSLayoutConstraint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        bar.wantsLayer = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        width = bar.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            width!,
        ])
        alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(value: Double, visible: Bool) {
        let target = bounds.width * max(0.08, min(1, value))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Tokens.Motion.duration(0.2)
            ctx.allowsImplicitAnimation = true
            width?.animator().constant = target
            animator().alphaValue = visible ? 1 : 0
        }
    }
}
