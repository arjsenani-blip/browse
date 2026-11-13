import SwiftUI
import BrowserCore

struct AppearancePane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        SettingsPageHeader(title: "Appearance", subtitle: "How Vane looks in every window. Changes apply as you make them.")

        SettingsCard(title: "Preview", help: "Your current space, drawn with these settings.") {
            BrowserPreview(theme: model.store.currentSpace.resolvedTheme, appearance: model.appearance)
                .frame(height: 210)
        }

        HStack(alignment: .top, spacing: 16) {
            SettingsCard(title: "Theme", help: "Follow macOS, or keep Vane light or dark.", fillHeight: true) {
                HStack(spacing: 10) {
                    ForEach(AppearanceSettings.Mode.allCases, id: \.self) { mode in
                        SettingsChoiceTile(title: mode.title, selected: model.appearance.mode == mode) {
                            model.appearance.mode = mode
                        } thumbnail: {
                            ModeThumbnail(mode: mode, theme: model.store.currentSpace.resolvedTheme)
                        }
                    }
                }
                Divider()
                SettingsToggleRow(title: "Tint window with space color",
                                  help: "Off uses the plain sidebar.",
                                  isOn: $model.appearance.tintWindow)
            }
            SettingsCard(title: "Layout", help: "Spacing and sizes in the sidebar and around the page.", fillHeight: true) {
                // Density on its own line keeps this card's minimum width under
                // half the pane, so it and the Theme card split the row evenly.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Density").font(.system(size: 13))
                    Picker("Density", selection: $model.appearance.density) {
                        ForEach(AppearanceSettings.Density.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                }
                SettingsSliderRow(title: "Corner radius", value: $model.appearance.cornerRadius, range: 0...24) { "\(Int($0)) pt" }
                SettingsSliderRow(title: "Text size", value: $model.appearance.fontSize, range: 11...17) { "\(Int($0)) pt" }
                SettingsSliderRow(title: "Card inset", value: $model.appearance.cardInset, range: 0...20) { "\(Int($0)) pt" }
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        var a = AppearanceSettings()
                        a.mode = model.appearance.mode
                        model.appearance = a
                    }
                    .controlSize(.small)
                    .disabled({ var a = model.appearance; a.mode = .system; return a == AppearanceSettings() }())
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension AppearanceSettings.Mode {
    var title: String {
        switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" }
    }
}

/// A miniature Vane window: the space gradient behind a sidebar of tabs and
/// an inset page card, scaled from the real settings.
struct BrowserPreview: View {
    let theme: SpaceTheme
    let appearance: AppearanceSettings
    @Environment(\.colorScheme) private var systemScheme

    private var scheme: ColorScheme {
        switch appearance.mode { case .system: systemScheme; case .light: .light; case .dark: .dark }
    }

    var body: some View {
        let dark = scheme == .dark
        let scale = 0.8
        let inset = appearance.cardInset * scale
        let row = appearance.rowHeight * 0.72
        let ink: Color = appearance.tintWindow
            ? (theme.prefersDarkInk(dark: dark) ? .black : .white)
            : (dark ? .white : .black)
        let pageFill = dark ? Color(white: 0.16) : Color.white

        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                    Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
                }
                .frame(height: 8)
                .padding(.bottom, 8)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ink.opacity(0.10))
                    .frame(height: 20)
                    .overlay(alignment: .leading) {
                        Text("vane.app").font(.system(size: appearance.fontSize * scale)).foregroundStyle(ink.opacity(0.6)).padding(.leading, 7)
                    }
                    .padding(.bottom, 6)
                HStack(spacing: 5) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ink.opacity(0.09)).frame(height: 24)
                    }
                }
                .padding(.bottom, 6)
                ForEach(Array(["Inbox", "Design review", "Ownership — Rust", "Weather", "Recipes"].enumerated()), id: \.offset) { i, title in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(ink.opacity(0.3)).frame(width: 10, height: 10)
                        Text(title).font(.system(size: appearance.fontSize * scale)).foregroundStyle(ink.opacity(i == 1 ? 0.95 : 0.7)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7)
                    .frame(height: row)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(i == 1 ? ink.opacity(0.13) : .clear))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(width: 168)

            // Page card
            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.22)).frame(width: 150, height: 10)
                    .padding(.bottom, 4)
                ForEach([0.92, 1.0, 0.86, 0.97, 0.62, 0.9, 0.78], id: \.self) { w in
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.09)).frame(width: g.size.width * w, height: 5)
                    }
                    .frame(height: 5)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: appearance.cornerRadius * scale, style: .continuous).fill(pageFill))
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            .padding(.vertical, max(inset, 2))
            .padding(.trailing, max(inset, 2))
        }
        .background(SpaceGradientView(theme: theme, tinted: appearance.tintWindow))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .environment(\.colorScheme, scheme)
        .animation(.smooth(duration: 0.2), value: appearance)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of a browser window with the current appearance settings")
    }
}

/// System / Light / Dark tile: a sliver of sidebar and page in that mode.
private struct ModeThumbnail: View {
    let mode: AppearanceSettings.Mode
    let theme: SpaceTheme

    var body: some View {
        switch mode {
        case .light: half(.light)
        case .dark: half(.dark)
        case .system:
            HStack(spacing: 0) { half(.light); half(.dark) }
        }
    }

    private func half(_ scheme: ColorScheme) -> some View {
        let dark = scheme == .dark
        return ZStack(alignment: .topLeading) {
            SpaceGradientView(theme: theme).environment(\.colorScheme, scheme)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill((dark ? Color.white : .black).opacity(0.25)).frame(width: CGFloat(18 - i * 3), height: 3)
                }
            }
            .padding(.top, 10).padding(.leading, 7)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(dark ? Color(white: 0.17) : .white)
                .padding(.leading, 32).padding(.vertical, 6).padding(.trailing, -6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}
