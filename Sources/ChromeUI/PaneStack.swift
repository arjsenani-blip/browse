import AppKit

/// Lays out one to four content cards side by side (or stacked) for split view. Each pane is a
/// full `ContentCard`; the gaps between them are drag handles that resize the panes. A click in
/// an unfocused pane focuses it. While a tab is dragged from the sidebar, `beginTabDrop()` puts
/// up drop zones over the panes (WKWebView would otherwise take the drag as a link).
@MainActor
public final class PaneStack: NSView {
    public enum Edge: Sendable { case leading, trailing, top, bottom }

    /// Cards in display order.
    public private(set) var cards: [ContentCard] = []
    private var keys: [AnyHashable] = []
    private var pool: [ContentCard] = []
    public private(set) var focusedIndex = 0
    public private(set) var vertical = false
    private var sizes: [CGFloat] = [1]
    public var gap: CGFloat = 8
    public var cornerRadius: CGFloat = 10 { didSet { (cards + pool).forEach { $0.setCornerRadius(cornerRadius) } } }
    public var accentHue: Double = 0.48 { didSet { if oldValue != accentHue { updateFocusRing() } } }

    /// New pane sizes after a divider drag (sum 1).
    public var onResize: (([Double]) -> Void)?
    /// A click landed in pane `index`.
    public var onFocus: ((Int) -> Void)?
    /// A sidebar tab (its id string) was dropped on pane `index` at `edge`.
    public var onDropTab: ((String, Int, Edge) -> Void)?
    /// The × on pane `index` (take it out of the split).
    public var onUnsplitPane: ((Int) -> Void)?
    /// Whether a drop is allowed (e.g. not past four panes); `index`/`edge` as for `onDropTab`.
    public var canDropTab: ((String, Int, Edge) -> Bool)?

    private var clickMonitor: Any?
    private var dropOverlay: PaneDropOverlay?

    public init(primary: ContentCard) {
        super.init(frame: .zero)
        primary.removeFromSuperview()
        addSubview(primary)
        cards = [primary]
        keys = [AnyHashable("primary")]
    }

    required init?(coder: NSCoder) { fatalError() }

    public var focused: ContentCard { cards.indices.contains(focusedIndex) ? cards[focusedIndex] : cards[0] }
    public var isSplit: Bool { cards.count > 1 }

    public func card(for key: AnyHashable) -> ContentCard? {
        keys.firstIndex(of: key).map { cards[$0] }
    }

    /// Shows one pane per key (a tab ID), reusing each key's card so a page never moves between
    /// cards. `sizes` sum to 1.
    public func arrange(keys newKeys: [AnyHashable], sizes newSizes: [Double], vertical: Bool, focused: Int, animated: Bool) {
        precondition(!newKeys.isEmpty)
        var byKey: [AnyHashable: ContentCard] = [:]
        for (k, c) in zip(keys, cards) { byKey[k] = c }
        // Cards whose key went away are reused for new keys (the caller swaps their page),
        // so the single-page case keeps the same card and its page never moves.
        var spare = zip(keys, cards).filter { !newKeys.contains($0.0) }.map(\.1) + pool
        pool = []
        let next: [ContentCard] = newKeys.map { k in
            if let c = byKey[k] { return c }
            let c = spare.isEmpty ? ContentCard() : spare.removeFirst()
            c.setCornerRadius(cornerRadius)
            if c.superview !== self { addSubview(c, positioned: .below, relativeTo: dropOverlay) }
            return c
        }
        for c in spare {
            c.show(nil)
            c.removeFromSuperview()
            pool.append(c)
        }
        let changedCount = next.count != cards.count || self.vertical != vertical
        cards = next
        keys = newKeys
        self.vertical = vertical
        sizes = newSizes.count == next.count ? newSizes.map { CGFloat($0) } : Array(repeating: 1 / CGFloat(next.count), count: next.count)
        focusedIndex = min(max(focused, 0), next.count - 1)
        updateFocusRing()
        if animated && changedCount && !Tokens.Motion.reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Tokens.Motion.duration(0.22)
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                ctx.allowsImplicitAnimation = true
                layoutPanes(animated: true)
            }
        } else {
            needsLayout = true
        }
        window?.invalidateCursorRects(for: self)
    }

    public func setFocused(_ index: Int) {
        guard cards.indices.contains(index), index != focusedIndex else { return }
        focusedIndex = index
        updateFocusRing()
    }

    private func updateFocusRing() {
        for (i, c) in cards.enumerated() {
            c.onUnsplit = { [weak self, weak c] in
                guard let self, let c, let i = self.cards.firstIndex(where: { $0 === c }) else { return }
                self.onUnsplitPane?(i)
            }
            c.setPaneFocus(cards.count > 1 ? (i == focusedIndex) : nil, hue: accentHue)
        }
    }

    // MARK: Layout

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        layoutPanes(animated: false)
    }

    private func frames(in bounds: NSRect) -> [NSRect] {
        let n = CGFloat(cards.count)
        let total = (vertical ? bounds.height : bounds.width) - gap * (n - 1)
        var offset: CGFloat = 0
        return sizes.map { f in
            let length = (total * f).rounded()
            defer { offset += length + gap }
            return vertical
                ? NSRect(x: 0, y: offset, width: bounds.width, height: length)
                : NSRect(x: offset, y: 0, width: length, height: bounds.height)
        }.enumerated().map { i, r in
            // The last pane absorbs rounding so the edge stays flush.
            guard i == cards.count - 1 else { return r }
            return vertical ? NSRect(x: 0, y: r.minY, width: bounds.width, height: bounds.height - r.minY)
                            : NSRect(x: r.minX, y: 0, width: bounds.width - r.minX, height: bounds.height)
        }
    }

    private func layoutPanes(animated: Bool) {
        for (c, r) in zip(cards, frames(in: bounds)) {
            if animated { c.animator().frame = r } else { c.frame = r }
        }
        dropOverlay?.frame = bounds
    }

    // MARK: Divider drag

    private func dividerIndex(at p: NSPoint) -> Int? {
        guard cards.count > 1 else { return nil }
        let f = frames(in: bounds)
        for i in 0..<(f.count - 1) {
            let a = vertical ? f[i].maxY : f[i].maxX
            let b = vertical ? f[i + 1].minY : f[i + 1].minX
            let v = vertical ? p.y : p.x
            if v >= a - 2 && v <= b + 2 { return i }
        }
        return nil
    }

    public override func resetCursorRects() {
        guard cards.count > 1 else { return }
        let f = frames(in: bounds)
        for i in 0..<(f.count - 1) {
            let r = vertical
                ? NSRect(x: 0, y: f[i].maxY - 2, width: bounds.width, height: gap + 4)
                : NSRect(x: f[i].maxX - 2, y: 0, width: gap + 4, height: bounds.height)
            addCursorRect(r, cursor: vertical ? .resizeUpDown : .resizeLeftRight)
        }
    }

    private var dragging: (index: Int, start: CGFloat, sizes: [CGFloat])?

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = dividerIndex(at: p) else { super.mouseDown(with: event); return }
        dragging = (i, vertical ? p.y : p.x, sizes)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let d = dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        let total = (vertical ? bounds.height : bounds.width) - gap * CGFloat(cards.count - 1)
        guard total > 0 else { return }
        let delta = ((vertical ? p.y : p.x) - d.start) / total
        let pair = d.sizes[d.index] + d.sizes[d.index + 1]
        let minimum: CGFloat = 0.15
        let a = min(max(d.sizes[d.index] + delta, minimum), pair - minimum)
        sizes = d.sizes
        sizes[d.index] = a
        sizes[d.index + 1] = pair - a
        layoutPanes(animated: false)
    }

    public override func mouseUp(with event: NSEvent) {
        guard dragging != nil else { super.mouseUp(with: event); return }
        dragging = nil
        window?.invalidateCursorRects(for: self)
        onResize?(sizes.map(Double.init))
    }

    // MARK: Click to focus

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        guard window != nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.window === self.window, self.cards.count > 1 else { return }
                let p = self.convert(event.locationInWindow, from: nil)
                if event.type == .leftMouseDown, event.clickCount == 2, self.dividerIndex(at: p) != nil {
                    self.sizes = Array(repeating: 1 / CGFloat(self.cards.count), count: self.cards.count)
                    self.layoutPanes(animated: false)
                    self.onResize?(self.sizes.map(Double.init))
                    return
                }
                if let i = self.cards.firstIndex(where: { $0.frame.contains(p) }), i != self.focusedIndex {
                    self.setFocused(i)
                    self.onFocus?(i)
                }
            }
            return event
        }
    }

    // MARK: Tab drops

    /// Called when a sidebar tab drag starts: zones appear only while the cursor is over the page.
    public func beginTabDrop() {
        guard dropOverlay == nil else { return }
        let o = PaneDropOverlay(stack: self)
        o.frame = bounds
        o.autoresizingMask = [.width, .height]
        addSubview(o)
        dropOverlay = o
    }

    public func endTabDrop() {
        dropOverlay?.removeFromSuperview()
        dropOverlay = nil
    }

    /// The pane and edge a point (in this view) targets: the nearer side of that pane, along the
    /// split's axis (or the left/right halves of a single page).
    func dropTarget(at p: NSPoint) -> (Int, Edge)? {
        let f = frames(in: bounds)
        guard let i = f.firstIndex(where: { $0.insetBy(dx: -gap / 2, dy: -gap / 2).contains(p) }) else { return nil }
        let r = f[i]
        if vertical && cards.count > 1 { return (i, p.y < r.midY ? .top : .bottom) }
        return (i, p.x < r.midX ? .leading : .trailing)
    }

    /// Where the dropped pane would go, for the highlight.
    func dropRect(pane i: Int, edge: Edge) -> NSRect {
        let r = frames(in: bounds)[i]
        switch edge {
        case .leading: return NSRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height)
        case .trailing: return NSRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height)
        case .top: return NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2)
        case .bottom: return NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2)
        }
    }
}

/// Transparent layer over the panes during a sidebar tab drag: tints the half where the tab
/// would land and takes the drop.
@MainActor
final class PaneDropOverlay: NSView {
    private weak var stack: PaneStack?
    private let highlight = NSView()
    private let label = NSTextField(labelWithString: "")
    private var target: (Int, PaneStack.Edge)?

    init(stack: PaneStack) {
        self.stack = stack
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.aegisTab])
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = stack.cornerRadius
        highlight.layer?.cornerCurve = .continuous
        highlight.layer?.borderWidth = 2
        highlight.alphaValue = 0
        addSubview(highlight)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.alignment = .center
        label.wantsLayer = true
        highlight.addSubview(label)
        tint(hue: stack.accentHue)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    // Clicks pass through; only drags stop here.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func tint(hue: Double) {
        let accent = Tokens.accent(hue: hue)
        highlight.layer?.backgroundColor = accent.withAlphaComponent(0.14).cgColor
        highlight.layer?.borderColor = accent.withAlphaComponent(0.7).cgColor
        label.textColor = accent
    }

    private func update(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let stack, let raw = info.draggingPasteboard.string(forType: .aegisTab) else { return [] }
        let p = convert(info.draggingLocation, from: nil)
        guard let t = stack.dropTarget(at: p), stack.canDropTab?(raw, t.0, t.1) ?? true else {
            target = nil
            fade(to: 0)
            return []
        }
        let changed = target.map { $0.0 != t.0 || $0.1 != t.1 } ?? true
        target = t
        let r = stack.dropRect(pane: t.0, edge: t.1).insetBy(dx: 6, dy: 6)
        label.stringValue = stack.isSplit ? "Add to Split View" : "Open in Split View"
        label.sizeToFit()
        if changed {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Tokens.Motion.duration(highlight.alphaValue == 0 ? 0 : 0.14)
                ctx.allowsImplicitAnimation = true
                highlight.animator().frame = r
            }
            label.frame = NSRect(x: (r.width - label.frame.width) / 2, y: (r.height - label.frame.height) / 2,
                                 width: label.frame.width, height: label.frame.height)
        }
        fade(to: 1)
        return .move
    }

    private func fade(to alpha: CGFloat) {
        guard highlight.alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Tokens.Motion.duration(0.12)
            highlight.animator().alphaValue = alpha
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { target = nil; fade(to: 0) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let stack, let t = target, let raw = sender.draggingPasteboard.string(forType: .aegisTab) else { return false }
        stack.onDropTab?(raw, t.0, t.1)
        return true
    }
}
