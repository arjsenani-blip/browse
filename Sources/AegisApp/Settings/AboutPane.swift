import AppKit
import SwiftUI

struct AboutPane: View {
    @Bindable var model: SettingsModel

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        let _ = model.tick
        let store = model.store

        SettingsCard(padding: 24) {
            HStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Aegis").font(.system(size: 26, weight: .bold))
                    Text("Version \(version)").font(.system(size: 12.5)).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("A private, keyboard-driven browser for macOS, on the system WebKit.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.top, 8)

        HStack(spacing: 12) {
            SettingsStat(value: "\(store.spaces.count - store.ephemeralSpaces.count)", label: "Spaces", systemImage: "square.grid.2x2.fill", tint: SettingsPane.spaces.tint)
            SettingsStat(value: "\(store.tabs.count)", label: "Tabs", systemImage: "square.on.square", tint: SettingsPane.appearance.tint)
            SettingsStat(value: model.services.blocking.ruleCount.formatted(), label: "Blocking rules", systemImage: "shield.lefthalf.filled", tint: SettingsPane.privacy.tint)
        }

        SettingsCard(title: "What Aegis connects to", help: "The app itself makes only these requests. There is no analytics or crash reporting.") {
            connection("Filter list updates", "easylist.to, secure.fanboy.co.uk", "list.bullet.rectangle")
            Divider()
            connection("Encrypted DNS", model.resolver == .off ? "Off: system DNS" : model.resolver.displayName, "lock.shield")
            Divider()
            connection("Site icons", "From the sites you visit", "photo")
            Divider()
            connection("Extensions", "Google's store servers, only when you add one", "puzzlepiece.extension")
        }

        SettingsCard(title: "Keyboard", help: nil) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow { key("⌘K", "Command palette"); key("⌘T", "New tab") }
                GridRow { key("⌘L", "Open location"); key("⇧⌘T", "Reopen closed tab") }
                GridRow { key("⌥⌘J", "Library"); key("⌘,", "Settings") }
            }
        }
    }

    private func connection(_ title: String, _ detail: String, _ icon: String) -> some View {
        SettingsRow(title: title, systemImage: icon) {
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func key(_ k: String, _ label: String) -> some View {
        HStack(spacing: 10) {
            Text(k)
                .font(.system(size: 11.5, weight: .medium))
                .fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                .frame(width: 52, alignment: .leading)
            Text(label).font(.system(size: 12.5))
        }
    }
}
