import AppKit
import BrowserCore

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
            progress.heightAnchor.constraint(equalToConstant: 14),   // room for the glow
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

    private var lastProgress: (Double, Bool, ThemeColor)?

    /// `glow` is the space gradient's bottom stop; the bar shows its neon version.
    public func setProgress(_ value: Double, loading: Bool, glow: ThemeColor) {
        // Redraws are frequent; only animate when the bar actually changes.
        if let last = lastProgress, last.0 == value, last.1 == loading, last.2 == glow { return }
        lastProgress = (value, loading, glow)
        progress.color = Tokens.neon(from: glow)
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

/// The page-load line: a neon tube in the space's bottom gradient colour,
/// with a bloom underneath, a white-hot comet head and a shimmer sweeping
/// toward the head while loading.
final class ProgressLine: NSView {
    var color: NSColor = .systemRed { didSet { if color != oldValue { recolor() } } }
    private let bloom = CALayer()          // wide, soft halo
    private let glow = CALayer()           // tight halo hugging the tube
    private let core = CAGradientLayer()   // the tube itself
    private let filament = CAGradientLayer() // white-hot centre line
    private let head = CALayer()
    private let shimmer = CAGradientLayer()
    private let barHeight: CGFloat = 3
    private var fraction: CGFloat = 0
    private var shown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for l in [bloom, glow, core, head] as [CALayer] { layer?.addSublayer(l) }
        core.addSublayer(filament)
        core.addSublayer(shimmer)
        for g in [core, filament, shimmer] { g.startPoint = CGPoint(x: 0, y: 0.5); g.endPoint = CGPoint(x: 1, y: 0.5) }
        core.masksToBounds = true
        core.cornerRadius = barHeight / 2
        for (l, r, o) in [(bloom, CGFloat(14), Float(0.9)), (glow, 4, 1), (head, 8, 1)] {
            l.shadowOffset = .zero; l.shadowRadius = r; l.shadowOpacity = o
        }
        shimmer.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.85).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        alphaValue = 0
        recolor()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Purely decorative: clicks go through to the page.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }

    private func recolor() {
        let c = color.usingColorSpace(.sRGB) ?? color
        let hot = c.blended(withFraction: 0.7, of: .white) ?? .white
        CATransaction.begin(); CATransaction.setDisableActions(true)
        core.colors = [c.withAlphaComponent(0).cgColor, c.withAlphaComponent(0.85).cgColor, c.cgColor]
        core.locations = [0, 0.25, 1]
        filament.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.55).cgColor, NSColor.white.withAlphaComponent(0.9).cgColor]
        filament.locations = [0.3, 0.8, 1]
        for l in [bloom, glow] { l.shadowColor = c.cgColor }
        head.backgroundColor = hot.cgColor
        head.shadowColor = c.cgColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        place()
        CATransaction.commit()
    }

    private func place() {
        let w = bounds.width * fraction
        core.frame = CGRect(x: 0, y: 0, width: w, height: barHeight)
        filament.frame = CGRect(x: 0, y: barHeight / 2 - 0.5, width: w, height: 1)
        // Halos are shadow-only wedges: hairline at the tail, full height at the head, so they fade in.
        for (l, start) in [(glow, CGFloat(0.15)), (bloom, 0.4)] {
            l.frame = CGRect(x: 0, y: 0, width: w, height: barHeight)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: w * start, y: barHeight / 2))
            path.addLine(to: CGPoint(x: w, y: 0))
            path.addLine(to: CGPoint(x: w, y: barHeight))
            path.closeSubpath()
            l.shadowPath = path
        }
        let headWidth = min(28, max(8, w * 0.08))
        head.frame = CGRect(x: max(0, w - headWidth), y: 0, width: headWidth, height: barHeight)
        head.cornerRadius = barHeight / 2
        shimmer.frame = CGRect(x: 0, y: 0, width: min(180, max(60, w * 0.35)), height: barHeight)
    }

    func set(value: Double, visible: Bool) {
        let newFraction = CGFloat(max(0.08, min(1, value)))
        let starting = visible && !shown
        if starting {
            // A fresh load starts from the left edge instead of shrinking back from the last one.
            fraction = 0
            CATransaction.begin(); CATransaction.setDisableActions(true); place(); CATransaction.commit()
        }
        shown = visible
        fraction = newFraction
        CATransaction.begin()
        CATransaction.setAnimationDuration(Tokens.Motion.duration(0.25))
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        place()
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Tokens.Motion.duration(visible ? 0.12 : 0.35)
            animator().alphaValue = visible ? 1 : 0
        }
        updateShimmer(visible)
    }

    private func updateShimmer(_ on: Bool) {
        let running = shimmer.animation(forKey: "sweep") != nil
        if on && !running && !Tokens.Motion.reduceMotion {
            let a = CABasicAnimation(keyPath: "transform.translation.x")
            a.fromValue = -160
            a.toValue = 2000
            a.duration = 1.4
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shimmer.add(a, forKey: "sweep")
        } else if !on && running {
            shimmer.removeAnimation(forKey: "sweep")
        }
    }
}
