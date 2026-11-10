import SwiftUI
import BrowserCore

struct TabsPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        SettingsPageHeader(title: "Search & Tabs", subtitle: "Where tabs live, how long they stay, and where searches go.")

        SettingsCard(title: "Tab layout", help: "Switch any time from the View menu or ⌘K.") {
            HStack(spacing: 14) {
                SettingsChoiceTile(title: "Sidebar", selected: !model.tabsOnTop) { model.tabsOnTop = false } thumbnail: {
                    LayoutThumbnail(onTop: false, theme: model.store.currentSpace.resolvedTheme)
                }
                SettingsChoiceTile(title: "Tabs on top", selected: model.tabsOnTop) { model.tabsOnTop = true } thumbnail: {
                    LayoutThumbnail(onTop: true, theme: model.store.currentSpace.resolvedTheme)
                }
            }
            .frame(maxWidth: 360)
        }

        HStack(alignment: .top, spacing: 16) {
            SettingsCard(title: "Tab lifetime", help: "Favorites and pinned tabs are never archived.", fillHeight: true) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Archive today's tabs after").font(.system(size: 13))
                    Picker("Archive today's tabs after", selection: $model.archiveHours) {
                        Text("12 hours").tag(12.0); Text("1 day").tag(24.0); Text("1 week").tag(168.0); Text("30 days").tag(720.0)
                    }
                    .labelsHidden().pickerStyle(.segmented)
                    Text("Archived tabs stay searchable from ⌘K.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Put background tabs to sleep after").font(.system(size: 13))
                    Picker("Put background tabs to sleep after", selection: $model.sleepMinutes) {
                        Text("5 min").tag(5.0); Text("15 min").tag(15.0); Text("30 min").tag(30.0); Text("2 hours").tag(120.0)
                    }
                    .labelsHidden().pickerStyle(.segmented)
                    Text("Tabs playing media, recording or with unsaved forms never sleep.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            SettingsCard(title: "Search", help: "For anything that isn't a web address.", fillHeight: true) {
                SettingsRow(title: "Search engine", help: "Results open on duckduckgo.com.", systemImage: "magnifyingglass") {
                    SettingsBadge(text: "DuckDuckGo")
                }
                Divider()
                SettingsRow(title: "Suggestions", help: "From your tabs and history only.", systemImage: "text.magnifyingglass") {
                    SettingsBadge(text: "On this Mac", tint: .secondary)
                }
                Divider()
                SettingsRow(title: "Command palette", help: "Tabs, history and commands.", systemImage: "command") {
                    Text("⌘K").font(.system(size: 12, weight: .medium).monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LayoutThumbnail: View {
    let onTop: Bool
    let theme: SpaceTheme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let page = scheme == .dark ? Color(white: 0.17) : Color.white
        ZStack {
            SpaceGradientView(theme: theme)
            if onTop {
                VStack(spacing: 4) {
                    HStack(spacing: 3) {
                        ForEach(0..<4, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(i == 0 ? 0.3 : 0.15)).frame(height: 7)
                        }
                    }
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(page)
                }
                .padding(6)
            } else {
                HStack(spacing: 5) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(0..<5, id: \.self) { i in
                            Capsule().fill(Color.primary.opacity(i == 1 ? 0.35 : 0.18)).frame(width: CGFloat(22 - i % 3 * 4), height: 3)
                        }
                        Spacer()
                    }
                    .padding(.top, 4)
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(page)
                }
                .padding(6)
            }
        }
    }
}
