import Foundation

/// An sRGB colour, stored in the session so a space keeps its look.
public struct ThemeColor: Codable, Sendable, Hashable {
    public var r: Double, g: Double, b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    public init(hue: Double, saturation: Double, brightness: Double) {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let c = brightness * saturation, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = brightness - c
        let (r, g, b): (Double, Double, Double) = switch Int(h) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        self.init(r: r + m, g: g + m, b: b + m)
    }

    /// WCAG relative luminance, for picking light or dark text.
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    public func mixed(with other: ThemeColor, _ t: Double) -> ThemeColor {
        ThemeColor(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    public var saturation: Double {
        let mx = max(r, g, b), mn = min(r, g, b)
        return mx == 0 ? 0 : (mx - mn) / mx
    }
    public var brightness: Double { max(r, g, b) }

    public var hue: Double {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        guard d > 0 else { return 0 }
        var h: Double = mx == r ? (g - b) / d : mx == g ? 2 + (b - r) / d : 4 + (r - g) / d
        h /= 6
        return h < 0 ? h + 1 : h
    }
}

/// A space's look: a two-stop gradient that tints the window frame, like a
/// coloured sheet of glass behind the sidebar and around the page.
public struct SpaceTheme: Codable, Sendable, Hashable {
    public var top: ThemeColor
    public var bottom: ThemeColor
    /// 0 = barely tinted (near the system background), 1 = full colour.
    public var intensity: Double
    /// A fine film-grain texture over the gradient.
    public var grain: Bool

    public init(top: ThemeColor, bottom: ThemeColor, intensity: Double = 0.7, grain: Bool = true) {
        self.top = top; self.bottom = bottom; self.intensity = intensity; self.grain = grain
    }

    /// A pleasant two-tone gradient around one hue (an analogous neighbour below).
    public static func from(hue: Double) -> SpaceTheme {
        SpaceTheme(top: ThemeColor(hue: hue, saturation: 0.42, brightness: 0.96),
                   bottom: ThemeColor(hue: hue + 0.06, saturation: 0.55, brightness: 0.86))
    }

    /// The colour text and selection should key off (the gradient's middle at this intensity).
    public func effectiveMiddle(over base: ThemeColor) -> ThemeColor {
        base.mixed(with: top.mixed(with: bottom, 0.5), intensity)
    }

    public static let presets: [(name: String, theme: SpaceTheme)] = [
        ("Lagoon", SpaceTheme(top: ThemeColor(r: 0.62, g: 0.88, b: 0.84), bottom: ThemeColor(r: 0.36, g: 0.70, b: 0.78))),
        ("Dusk", SpaceTheme(top: ThemeColor(r: 0.98, g: 0.74, b: 0.62), bottom: ThemeColor(r: 0.80, g: 0.52, b: 0.74))),
        ("Grape", SpaceTheme(top: ThemeColor(r: 0.78, g: 0.70, b: 0.98), bottom: ThemeColor(r: 0.52, g: 0.46, b: 0.88))),
        ("Meadow", SpaceTheme(top: ThemeColor(r: 0.80, g: 0.92, b: 0.62), bottom: ThemeColor(r: 0.48, g: 0.76, b: 0.50))),
        ("Ember", SpaceTheme(top: ThemeColor(r: 1.00, g: 0.80, b: 0.46), bottom: ThemeColor(r: 0.94, g: 0.46, b: 0.34))),
        ("Ocean", SpaceTheme(top: ThemeColor(r: 0.60, g: 0.78, b: 1.00), bottom: ThemeColor(r: 0.30, g: 0.46, b: 0.86))),
        ("Rose", SpaceTheme(top: ThemeColor(r: 1.00, g: 0.78, b: 0.84), bottom: ThemeColor(r: 0.90, g: 0.50, b: 0.62))),
        ("Graphite", SpaceTheme(top: ThemeColor(r: 0.80, g: 0.81, b: 0.84), bottom: ThemeColor(r: 0.56, g: 0.58, b: 0.63), grain: true)),
        ("Midnight", SpaceTheme(top: ThemeColor(r: 0.20, g: 0.22, b: 0.34), bottom: ThemeColor(r: 0.08, g: 0.09, b: 0.16), intensity: 1)),
        ("Forest", SpaceTheme(top: ThemeColor(r: 0.18, g: 0.34, b: 0.28), bottom: ThemeColor(r: 0.07, g: 0.16, b: 0.13), intensity: 1)),
    ]
}

/// App-wide appearance, edited in Settings → Appearance.
public struct AppearanceSettings: Codable, Sendable, Hashable {
    public enum Mode: String, Codable, Sendable, CaseIterable { case system, light, dark }
    public enum Density: String, Codable, Sendable, CaseIterable { case compact, comfortable, spacious }
    public var mode: Mode = .system
    public var density: Density = .comfortable
    /// Page card corner radius in points.
    public var cornerRadius: Double = 12
    /// Sidebar text size in points.
    public var fontSize: Double = 13
    /// Gap around the page card.
    public var cardInset: Double = 8
    /// Show the space's gradient behind the window (off = plain system sidebar).
    public var tintWindow = true
    public init() {}

    public var rowHeight: Double {
        switch density { case .compact: 26; case .comfortable: 30; case .spacious: 36 }
    }
}
