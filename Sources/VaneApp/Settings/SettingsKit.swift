import AppKit
import SwiftUI
import BrowserCore

// Building blocks shared by every Settings pane: page header, cards, rows,
// sliders and colour helpers. Cards are opaque surfaces (glass stays on the
// sidebar, per CLAUDE.md); the sidebar uses the system sidebar material
// unless Reduce Transparency is on.

/// Large title and one line of helper text at the top of a pane.
struct SettingsPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }
}

/// A rounded dashboard card with an optional title, helper text and a
/// trailing accessory in the header.
struct SettingsCard<Content: View, Accessory: View>: View {
    var title: String?
    var help: String?
    var padding: CGFloat = 16
    var fillHeight = false
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || help != nil {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let title {
                            Text(title).font(.system(size: 13, weight: .semibold))
                                .accessibilityAddTraits(.isHeader)
                        }
                        if let help {
                            Text(help).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    accessory()
                }
            }
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SettingsColors.card(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(SettingsColors.cardStroke(scheme), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.05), radius: 1.5, y: 1)
    }
}

extension SettingsCard where Accessory == EmptyView {
    init(title: String? = nil, help: String? = nil, padding: CGFloat = 16, fillHeight: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.help = help
        self.padding = padding
        self.fillHeight = fillHeight
        self.accessory = { EmptyView() }
        self.content = content
    }
}

enum SettingsColors {
    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.17) : Color(white: 1)
    }
    static func cardStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }
    static func page(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.115) : Color(red: 0.955, green: 0.958, blue: 0.965)
    }
    static func well(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
    }
}

/// A label on the left, a control on the right, optional helper text under the label.
struct SettingsRow<Control: View>: View {
    let title: String
    var help: String?
    var systemImage: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let help {
                    Text(help).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .frame(minHeight: 26)
        .accessibilityElement(children: .combine)
    }
}

/// A toggle row; the whole row is one accessible switch.
struct SettingsToggleRow: View {
    let title: String
    var help: String?
    var systemImage: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, help: help, systemImage: systemImage) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize()
        }
    }
}

/// Label, slider and the current value, aligned in columns.
struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13)).frame(width: 92, alignment: .leading)
            // Continuous track (a `step:` draws tick marks); values snap in the binding.
            Slider(value: Binding(get: { value }, set: { value = (($0 / step).rounded() * step) }), in: range)
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(format(value))
            Text(format(value))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 26)
    }
}

/// A big number with a caption, for the stat strips at the top of panes.
struct SettingsStat: View {
    let value: String
    let label: String
    var systemImage: String?
    var tint: Color = .accentColor

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.gradient))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SettingsColors.card(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SettingsColors.cardStroke(scheme), lineWidth: 0.5))
        .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.05), radius: 1.5, y: 1)
        .accessibilityElement(children: .combine)
    }
}

/// A selectable tile with a drawn thumbnail and a caption under it
/// (theme mode, tab layout). Outlined in the accent when selected.
struct SettingsChoiceTile<Thumb: View>: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var thumbnail: () -> Thumb

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                thumbnail()
                    .frame(height: 58)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 0.5)
                    )
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A small capsule label ("Current", "Loaded", "Off").
struct SettingsBadge: View {
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

// MARK: - Colour helpers

extension Color {
    init(_ c: ThemeColor) { self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1) }
}

extension ThemeColor {
    /// sRGB components of a SwiftUI colour (from a ColorPicker).
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
    }
}

extension SpaceTheme {
    /// The two stops as shown on screen: mixed over the window base by `intensity`.
    func displayStops(dark: Bool) -> (Color, Color) {
        let base = dark ? ThemeColor(r: 0.11, g: 0.11, b: 0.12) : ThemeColor(r: 0.96, g: 0.96, b: 0.97)
        return (Color(base.mixed(with: top, intensity)), Color(base.mixed(with: bottom, intensity)))
    }

    /// True when text over the gradient should be dark.
    func prefersDarkInk(dark: Bool) -> Bool {
        let base = dark ? ThemeColor(r: 0.11, g: 0.11, b: 0.12) : ThemeColor(r: 0.96, g: 0.96, b: 0.97)
        return effectiveMiddle(over: base).luminance > 0.45
    }
}

/// The space gradient, optionally with film grain, the way the window draws it.
struct SpaceGradientView: View {
    let theme: SpaceTheme
    var tinted = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let (a, b) = theme.displayStops(dark: dark)
        ZStack {
            if tinted {
                LinearGradient(colors: [a, b], startPoint: .top, endPoint: .bottom)
                if theme.grain { GrainView(opacity: dark ? 0.10 : 0.07) }
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
    }
}

/// A deterministic speckle so the preview matches the window's grain without noise per frame.
struct GrainView: View {
    var opacity: Double

    var body: some View {
        Canvas(rendersAsynchronously: true) { ctx, size in
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            func next() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 33) / Double(UInt32.max >> 1)
            }
            let count = Int(size.width * size.height / 14)
            for _ in 0..<min(count, 9000) {
                let x = next() * size.width, y = next() * size.height
                let light = next() > 0.5
                ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)),
                         with: .color(light ? .white.opacity(opacity) : .black.opacity(opacity)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
