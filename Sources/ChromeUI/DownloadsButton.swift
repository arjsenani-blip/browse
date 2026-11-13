import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BrowserCore

/// The toolbar downloads control, left of Back. It only exists while there is
/// something to show: it appears when a download starts, rings its arrow with
/// a neon progress arc (the space's load-bar colour), flashes a check when a
/// file lands, and steps aside a minute after the last one finishes.
@MainActor
public final class DownloadsButton: NSView {
    public var onClick: (() -> Void)?

    /// Everything drawn lives on one centred layer, so the bump scales about the middle.
    private let stage = CALayer()
    private let icon = CALayer()
    private var iconImage: NSImage?
    private var iconTint: NSColor = .labelColor
    private let trackRing = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let hover = CALayer()
    private var tracking: NSTrackingArea?
    private var mode: Mode = .idle
    private var neon: NSColor = .systemRed
    private enum Mode: Equatable { case idle, indeterminate, progress, done }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        hover.cornerRadius = 6
        hover.opacity = 0
        layer?.addSublayer(hover)
        layer?.addSublayer(stage)
        for l in [trackRing, ring] {
            l.fillColor = nil
            l.lineWidth = 1.8
            l.lineCap = .round
            stage.addSublayer(l)
        }
        icon.contentsGravity = .center
        stage.addSublayer(icon)
        ring.strokeEnd = 0
        ring.strokeColor = neon.cgColor
        ring.shadowColor = neon.cgColor
        ring.shadowOffset = .zero
        ring.shadowRadius = 3
        ring.shadowOpacity = 0.9
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 24),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        toolTip = "Downloads (⇧⌘J)"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Downloads")
        apply(.idle, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hover.frame = bounds
        stage.bounds = bounds
        stage.position = CGPoint(x: bounds.midX, y: bounds.midY)
        icon.frame = bounds
        icon.contentsScale = window?.backingScaleFactor ?? 2
        let d: CGFloat = 17
        let rect = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        // Start at 12 o'clock, run clockwise (the layer is unflipped: y up).
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: d / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for l in [trackRing, ring] { l.frame = bounds; l.path = path }
        CATransaction.commit()
        renderIcon()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderIcon()
    }

    /// Bake the tinted symbol into the icon layer (dynamic colours resolved for this appearance).
    private func renderIcon() {
        guard let base = iconImage else { return }
        var tinted: NSImage?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = iconTint.usingColorSpace(.sRGB) ?? iconTint
            tinted = base.withSymbolConfiguration(.init(paletteColors: [color]))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        icon.contents = tinted
        CATransaction.commit()
    }

    /// `progress`: nil = nothing in flight; 0 = in flight, size unknown; else the overall fraction.
    public func update(progress: Double?, neon: NSColor) {
        if neon != self.neon {
            self.neon = neon
            CATransaction.begin(); CATransaction.setDisableActions(true)
            ring.strokeColor = neon.cgColor
            ring.shadowColor = neon.cgColor
            CATransaction.commit()
        }
        let next: Mode = switch progress {
        case nil: mode == .done ? .done : .idle
        case .some(let p) where p <= 0: .indeterminate
        default: .progress
        }
        if next != mode { apply(next, animated: true) }
        if next == .progress, let p = progress {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Tokens.Motion.duration(0.25))
            ring.strokeEnd = CGFloat(min(1, max(0.04, p)))
            CATransaction.commit()
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.isDark
            trackRing.strokeColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.2 : 0.14).cgColor
            hover.backgroundColor = NSColor(white: dark ? 1 : 0, alpha: 0.08).cgColor
        }
    }

    /// A file landed: flash a check in a full ring, then settle back to the plain icon.
    public func finished() {
        apply(.done, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.mode == .done else { return }
            self.apply(.idle, animated: true)
        }
    }

    /// The little "caught it" squash when the flying file arrives.
    public func bump() {
        guard !Tokens.Motion.reduceMotion else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.scale")
        a.values = [1, 1.28, 0.92, 1.04, 1]
        a.keyTimes = [0, 0.25, 0.55, 0.8, 1]
        a.duration = 0.45
        stage.add(a, forKey: "bump")
    }

    private func apply(_ m: Mode, animated: Bool) {
        mode = m
        let symbol: String, size: CGFloat, weight: NSFont.Weight, tint: NSColor
        switch m {
        case .idle: (symbol, size, weight, tint) = ("arrow.down.circle", 13, .medium, Tokens.secondaryInk)
        case .indeterminate, .progress: (symbol, size, weight, tint) = ("arrow.down", 8.5, .heavy, .labelColor)
        case .done: (symbol, size, weight, tint) = ("checkmark", 8.5, .heavy, neon)
        }
        iconImage = NSImage(systemSymbolName: symbol, accessibilityDescription: "Downloads")?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
        iconTint = tint
        renderIcon()
        let ringVisible = m != .idle
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(Tokens.Motion.duration(0.2))
        trackRing.opacity = ringVisible ? 1 : 0
        ring.opacity = ringVisible ? 1 : 0
        if m == .done { ring.strokeEnd = 1 }
        if m == .idle { ring.strokeEnd = 0 }
        CATransaction.commit()

        ring.removeAnimation(forKey: "spin")
        if m == .indeterminate {
            ring.strokeEnd = 0.28
            if !Tokens.Motion.reduceMotion {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0; spin.toValue = -2 * Double.pi
                spin.duration = 0.9; spin.repeatCount = .infinity
                ring.add(spin, forKey: "spin")
            }
        } else {
            ring.transform = CATransform3DIdentity
        }
        if m == .done, animated, !Tokens.Motion.reduceMotion {
            let pop = CAKeyframeAnimation(keyPath: "shadowRadius")
            pop.values = [3, 9, 3]; pop.duration = 0.6
            ring.add(pop, forKey: "pop")
        }
    }

    // MARK: Mouse

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    public override func mouseEntered(with event: NSEvent) { hover.opacity = 1 }
    public override func mouseExited(with event: NSEvent) { hover.opacity = 0 }
    public override func mouseDown(with event: NSEvent) { stage.opacity = 0.6 }
    public override func mouseUp(with event: NSEvent) {
        stage.opacity = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    public override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    public override var mouseDownCanMoveWindow: Bool { false }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

// MARK: - Popover

/// The list the button opens: recent downloads, newest first, in a flat,
/// faintly filled popover. Rows drag out as files; hover shows the actions.
struct DownloadsListView: View {
    @Bindable var model: LibraryModel
    var neon: Color
    var openFolder: () -> Void
    var showAll: () -> Void

    private var recent: [LibraryItem] { Array(model.items.prefix(30)) }
    private var hasFinished: Bool { model.items.contains { $0.progress == nil } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Downloads").font(.system(size: 13, weight: .semibold))
                Spacer()
                if hasFinished {
                    Button("Clear") { model.actions?.libraryClearFinished() }
                        .buttonStyle(PillButtonStyle())
                        .help("Remove finished downloads from the list (files stay on disk)")
                }
                Button(action: openFolder) {
                    Image(systemName: "folder").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(IconButtonStyle())
                .help("Open the Downloads folder")
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            if recent.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary)
                    Text("No downloads yet").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(recent) { item in
                            DownloadsPopoverRow(item: item, neon: neon, actions: model.actions)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(height: min(CGFloat(recent.count), 6) * 50 + 4)
            }

            Divider().opacity(0.5).padding(.top, 4)
            Button(action: showAll) {
                HStack {
                    Text("Show all in Library")
                    Spacer()
                    Text("⌥⌘J").foregroundStyle(.tertiary)
                }
                .font(.system(size: 11.5, weight: .medium))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .frame(width: 320)
    }
}

struct DownloadsPopoverRow: View {
    let item: LibraryItem
    let neon: Color
    weak var actions: LibraryActions?
    @State private var hovering = false

    private var active: Bool { item.progress != nil && !item.failed }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                .opacity(item.exists || active ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if active {
                    HStack(spacing: 6) {
                        NeonBar(fraction: item.progress ?? 0, color: neon)
                        Text(sizeLine).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                    }
                } else {
                    Text(status).font(.system(size: 11)).foregroundStyle(item.failed ? AnyShapeStyle(.red.opacity(0.85)) : AnyShapeStyle(.secondary)).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if item.exists { actions?.libraryOpen(item) } }
        .onDrag { item.file.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
        .contextMenu {
            if item.exists {
                Button("Open") { actions?.libraryOpen(item) }
                Button("Show in Finder") { actions?.libraryReveal(item) }
            }
            if active { Button("Cancel Download") { actions?.libraryCancel(item) } }
            if item.failed, item.source != nil { Button("Try Again") { actions?.libraryRetry(item) } }
            if let source = item.source {
                Button("Copy Download Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source.absoluteString, forType: .string)
                }
            }
            Divider()
            Button("Remove from List") { actions?.libraryRemove(item) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(active ? sizeLine : status)")
    }

    @ViewBuilder private var trailing: some View {
        if active {
            Button { actions?.libraryCancel(item) } label: { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle()).help("Cancel")
        } else if item.failed, item.source != nil {
            Button { actions?.libraryRetry(item) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(IconButtonStyle()).help("Try Again")
        } else if item.exists {
            Button { actions?.libraryReveal(item) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(IconButtonStyle()).help("Show in Finder")
                .opacity(hovering ? 1 : 0.55)
        }
    }

    private var icon: NSImage {
        if let file = item.file, item.exists { return NSWorkspace.shared.icon(forFile: file.path) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
    }

    private var sizeLine: String {
        let f = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        if item.bytes > 0 { return "\(f(item.received)) of \(f(item.bytes))" }
        return item.received > 0 ? f(item.received) : "Starting…"
    }

    private var status: String {
        if item.cancelled { return "Cancelled" }
        if item.failed { return "Failed" }
        if !item.exists { return "Moved or deleted" }
        let size = item.bytes > 0 ? ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file) : ""
        let kind = (item.name as NSString).pathExtension.uppercased()
        return [kind, size, item.date.formatted(.relative(presentation: .named))].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A slim glowing progress capsule, the in-row cousin of the page load bar.
private struct NeonBar: View {
    var fraction: Double
    var color: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.55), color, .white.opacity(0.9)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, geo.size.width * fraction))
                    .shadow(color: color.opacity(0.9), radius: 3)
                    .animation(.easeOut(duration: 0.25), value: fraction)
            }
        }
        .frame(height: 3)
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07)))
            .contentShape(Circle())
    }
}

private struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(height: 22)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07)))
            .contentShape(Capsule())
    }
}

/// Shows the downloads list in a popover hanging from the toolbar button.
@MainActor
public final class DownloadsPopoverController: NSObject, NSPopoverDelegate {
    public let model: LibraryModel
    public var onOpenFolder: (() -> Void)?
    public var onShowAll: (() -> Void)?
    public var onVisibilityChange: (() -> Void)?
    private var popover: NSPopover?
    public var isShown: Bool { popover?.isShown == true }

    public init(model: LibraryModel) { self.model = model }

    public func toggle(relativeTo view: NSView, actions: LibraryActions, neon: NSColor) {
        if isShown { close(); return }
        show(relativeTo: view, actions: actions, neon: neon)
    }

    public func show(relativeTo view: NSView, actions: LibraryActions, neon: NSColor) {
        guard view.window != nil, !isShown else { return }
        model.actions = actions
        let p = NSPopover()
        p.behavior = .transient
        p.animates = !Tokens.Motion.reduceMotion
        p.delegate = self
        p.contentViewController = NSHostingController(rootView: DownloadsListView(
            model: model, neon: Color(nsColor: neon),
            openFolder: { [weak self] in self?.onOpenFolder?() },
            showAll: { [weak self] in self?.close(); self?.onShowAll?() }))
        p.show(relativeTo: view.bounds, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
        popover = p
        onVisibilityChange?()
    }

    public func close() { popover?.close() }

    public func popoverDidClose(_ notification: Notification) {
        popover = nil
        onVisibilityChange?()
    }
}
