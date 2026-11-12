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
    public override func updateLayer() {
        clip.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        clip.layer?.borderColor = NSColor.separatorColor.cgColor
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
        current?.removeFromSuperview()
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
