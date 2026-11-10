import AppKit
import BrowserCore

/// The window frame's colour: the current space's gradient behind the sidebar
/// and around the page card, with a fine grain. Two gradient layers cross-fade
/// so a swipe between spaces blends their colours in step with the fingers.
@MainActor
public final class ThemeBackgroundView: NSView {
    private let base = CAGradientLayer()
    private let incoming = CAGradientLayer()
    private let grain = CALayer()
    private var themes: [SpaceTheme] = []
    private var shown = 0
    public var enabled = true { didSet { refresh() } }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for g in [base, incoming] {
            g.startPoint = CGPoint(x: 0.5, y: 1)   // top (layer y is up)
            g.endPoint = CGPoint(x: 0.5, y: 0)
            g.actions = ["colors": NSNull(), "opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(g)
        }
        incoming.opacity = 0
        grain.actions = ["opacity": NSNull(), "bounds": NSNull(), "position": NSNull()]
        grain.backgroundColor = NSColor(patternImage: ThemeBackgroundView.noise).cgColor
        grain.compositingFilter = "overlayBlendMode"
        layer?.addSublayer(grain)
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [base, incoming, grain] { l.frame = bounds }
        CATransaction.commit()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    /// The window's themes, one per space, and which one is showing.
    public func set(themes: [SpaceTheme], current: Int, keepingAnimation: Bool = false) {
        let changed = themes != self.themes
        self.themes = themes
        let index = min(max(0, current), max(0, themes.count - 1))
        // A refresh while the cross-fade runs (or right after a swipe) must not snap it.
        if keepingAnimation, !changed, index == shown { return }
        if keepingAnimation, !changed, incoming.animation(forKey: "fade") != nil { shown = index; return }
        shown = index
        refresh()
    }

    /// Live blend from one space's theme to another (0…1). Cheap: two colour
    /// arrays and one opacity, no redraw.
    public func blend(from: Int, to: Int, fraction: Double) {
        guard enabled, themes.indices.contains(from), themes.indices.contains(to) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.colors = colors(for: themes[from])
        incoming.colors = colors(for: themes[to])
        incoming.opacity = Float(from == to ? 0 : fraction)
        grain.opacity = grainOpacity(themes[fraction > 0.5 ? to : from])
        CATransaction.commit()
        if fraction >= 1 || from == to { shown = fraction >= 1 ? to : from }
    }

    /// A programmatic switch: fade to the new theme over the strip's spring.
    public func animate(to index: Int) {
        guard enabled, themes.indices.contains(index), index != shown else { shown = index; refresh(); return }
        let from = shown
        shown = index
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.colors = colors(for: themes[from])
        incoming.colors = colors(for: themes[index])
        incoming.opacity = 1
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Tokens.Motion.duration(0.34)
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        incoming.add(fade, forKey: "fade")
        grain.opacity = grainOpacity(themes[index])
        // When the fade lands, make the new theme the base again.
        DispatchQueue.main.asyncAfter(deadline: .now() + fade.duration + 0.02) { [weak self] in
            guard let self, self.shown == index, self.incoming.animation(forKey: "fade") == nil else { return }
            self.refresh()
        }
    }

    private func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard enabled, themes.indices.contains(shown) else {
            base.colors = [NSColor.windowBackgroundColor.cgColor, NSColor.windowBackgroundColor.cgColor]
            incoming.opacity = 0
            grain.opacity = 0
            return
        }
        base.colors = colors(for: themes[shown])
        incoming.opacity = 0
        grain.opacity = grainOpacity(themes[shown])
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// The theme's stops mixed toward the system background by its intensity.
    /// In dark mode light themes are deepened so the frame never glares.
    func colors(for theme: SpaceTheme) -> [CGColor] {
        [resolved(theme.top, theme), resolved(theme.bottom, theme)].map {
            NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1).cgColor
        }
    }

    func resolved(_ c: ThemeColor, _ theme: SpaceTheme) -> ThemeColor {
        let dark = isDark
        let backdrop = dark ? ThemeColor(r: 0.11, g: 0.11, b: 0.12) : ThemeColor(r: 0.95, g: 0.95, b: 0.96)
        var color = c
        if dark, c.luminance > 0.35 {
            // Keep the hue, drop the brightness: a light theme becomes a deep tint.
            color = ThemeColor(r: c.r * 0.42, g: c.g * 0.42, b: c.b * 0.45)
        }
        return backdrop.mixed(with: color, theme.intensity)
    }

    /// The colour text sits on (the gradient's middle), for choosing light or dark text.
    public func middle(of theme: SpaceTheme) -> ThemeColor {
        resolved(theme.top, theme).mixed(with: resolved(theme.bottom, theme), 0.5)
    }

    private func grainOpacity(_ theme: SpaceTheme) -> Float {
        theme.grain && enabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? (isDark ? 0.10 : 0.16) : 0
    }

    /// 128×128 monochrome noise, tiled. Generated once.
    static let noise: NSImage = {
        let size = 128
        var rng = SystemRandomNumberGenerator()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 1, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite,
                                   bytesPerRow: size, bitsPerPixel: 8)!
        if let data = rep.bitmapData {
            for i in 0..<(size * size) { data[i] = UInt8.random(in: 64...192, using: &rng) }
        }
        let image = NSImage(size: NSSize(width: size / 2, height: size / 2))
        image.addRepresentation(rep)
        return image
    }()
}
