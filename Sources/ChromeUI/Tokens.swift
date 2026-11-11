import AppKit

/// Design tokens from docs/research/05-design-language.md. Window radii come
/// from the system; everything here is the chrome inside it.
public enum Tokens {
    public enum Radius {
        public static let contentCard: CGFloat = 12
        public static let tabRow: CGFloat = 8
        public static let control: CGFloat = 6
        public static let tile: CGFloat = 10
        public static let palette: CGFloat = 18
    }

    public enum Space {
        public static let cardInset: CGFloat = 8
        public static let sidebarPadding: CGFloat = 10
        public static let tabGap: CGFloat = 2
        public static let sectionGap: CGFloat = 14
    }

    public enum Size {
        public static let tabRow: CGFloat = 30
        public static let favicon: CGFloat = 16
        public static let favoriteTile: CGFloat = 44
        public static let urlPill: CGFloat = 32
        public static let sidebarDefault: CGFloat = 248
        public static let sidebarMin: CGFloat = 200
        public static let sidebarMax: CGFloat = 400
        public static let paletteWidth: CGFloat = 620
    }

    public enum Motion {
        public static let select: TimeInterval = 0.25
        public static let sidebarToggle: TimeInterval = 0.35
        public static let reduced: TimeInterval = 0.15
        /// Space paging spring response: quick and snappy, still critically damped.
        public static let pageResponse: Double = 0.24
        public static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        public static func duration(_ d: TimeInterval) -> TimeInterval { reduceMotion ? reduced : d }
    }

    /// The space accent, from its hue. Dark mode lifts luminance.
    public static func accent(hue: Double) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(calibratedHue: hue, saturation: dark ? 0.55 : 0.85, brightness: dark ? 0.85 : 0.55, alpha: 1)
        }
    }

    /// Selected-tab fill: the accent at 14% (22% with Increase Contrast).
    public static func selectionFill(hue: Double) -> NSColor {
        let alpha = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.22 : 0.14
        return accent(hue: hue).withAlphaComponent(alpha)
    }

    public static let secondaryInk = NSColor.secondaryLabelColor
    public static let tertiaryInk = NSColor.tertiaryLabelColor
}
