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

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Tokens.Radius.contentCard
        layer?.cornerCurve = .continuous
        layer?.shadowOpacity = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0 : 0.10
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -1)
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
    public func show(_ view: NSView?, snapshot: NSImage? = nil) {
        if current === view { return }
        current?.removeFromSuperview()
        current = view
        emptyView.isHidden = view != nil
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = false
            clip.addSubview(view, positioned: .below, relativeTo: snapshotView)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
                view.topAnchor.constraint(equalTo: clip.topAnchor),
                view.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            ])
        }
        if let snapshot {
            snapshotView.image = snapshot
            snapshotView.isHidden = false
            snapshotView.alphaValue = 1
        } else {
            snapshotView.isHidden = true
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

    public func setProgress(_ value: Double, loading: Bool, hue: Double) {
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
