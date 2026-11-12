import SwiftUI
import BrowserCore
import WebEngine

struct PrivacyPane: View {
    @Bindable var model: SettingsModel
    @State private var confirm: ClearAction?
    @State private var cleared: String?

    enum ClearAction: Identifiable {
        case currentSpace, allSpaces, history
        var id: Self { self }
    }

    var body: some View {
        let rules = model.services.blocking.ruleCount
        let _ = model.tick

        SettingsPageHeader(title: "Privacy & Security", subtitle: "Aegis sends no telemetry. Everything below runs on this Mac.")

        HStack(spacing: 12) {
            SettingsStat(value: rules > 0 ? rules.formatted() : "—", label: "Blocking rules", systemImage: "shield.lefthalf.filled", tint: SettingsPane.privacy.tint)
            SettingsStat(value: model.resolver == .off ? "Off" : model.resolver.displayName, label: "Encrypted DNS", systemImage: "lock.shield.fill", tint: SettingsPane.spaces.tint)
            SettingsStat(value: "None", label: "Telemetry", systemImage: "antenna.radiowaves.left.and.right.slash", tint: Color(red: 0.55, green: 0.56, blue: 0.60))
        }

        SettingsCard(title: "Protection", help: "Applied to every tab in every space.") {
            SettingsToggleRow(title: "Block ads and trackers", help: "Built in: EasyList and EasyPrivacy. Leave off if you use an extension like uBlock Origin.", systemImage: "hand.raised", isOn: $model.blockContent)
            Divider()
            SettingsToggleRow(title: "Fingerprint protection", help: "Adds noise to canvas, audio and WebGL; hides hardware details.", systemImage: "touchid", isOn: $model.fingerprint)
            Divider()
            SettingsToggleRow(title: "Remove tracking parameters", help: "Strips utm_, fbclid and similar from links you open.", systemImage: "link", isOn: $model.strip)
            Divider()
            SettingsToggleRow(title: "HTTPS only", help: "Asks before falling back to an insecure connection.", systemImage: "lock", isOn: $model.httpsOnly)
        }

        HStack(alignment: .top, spacing: 16) {
            SettingsCard(title: "Encrypted DNS", help: "Lookups go over HTTPS to the resolver you pick.", fillHeight: true) {
                VStack(spacing: 4) {
                    ForEach(EncryptedDNSProxy.Resolver.allCases, id: \.self) { r in
                        ResolverRow(resolver: r, selected: model.resolver == r) { model.resolver = r }
                    }
                }
                Text("WebRTC traffic and HTTP/3 don't go through the encrypted resolver.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            VStack(spacing: 16) {
                SettingsCard(title: "Filter lists", help: "Updated from easylist.to, only when you ask or on schedule.") {
                    SettingsRow(title: rules > 0 ? "\(rules.formatted()) rules active" : "Compiling rules…", systemImage: "list.bullet.rectangle") {
                        Button("Update Now") {
                            model.services.updateFilters(force: true)
                            Task { try? await Task.sleep(for: .seconds(4)); model.tick += 1 }
                        }
                        .controlSize(.small)
                    }
                }
                SettingsCard(title: "Website data", help: "Cookies, storage and caches. Signed-in sites will sign you out.", fillHeight: true) {
                    clearRow("Current space", detail: model.store.currentSpace.name, action: .currentSpace)
                    Divider()
                    clearRow("All spaces", detail: "\(model.store.profiles.count) profiles", action: .allSpaces)
                    Divider()
                    clearRow("Browsing history", detail: "Search and palette suggestions", action: .history)
                    if let cleared {
                        Label(cleared, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11.5)).foregroundStyle(.green)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .alert(title(for: confirm), isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { action in
            Button("Clear", role: .destructive) { perform(action) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This can't be undone.")
        }
    }

    private func clearRow(_ title: String, detail: String, action: ClearAction) -> some View {
        SettingsRow(title: title, help: detail) {
            Button("Clear…") { confirm = action }.controlSize(.small)
        }
    }

    private func title(for action: ClearAction?) -> String {
        switch action {
        case .currentSpace: "Clear website data for “\(model.store.currentSpace.name)”?"
        case .allSpaces: "Clear website data for all spaces?"
        case .history: "Clear all browsing history?"
        case nil: ""
        }
    }

    private func perform(_ action: ClearAction) {
        switch action {
        case .currentSpace:
            Task { await model.clearData(for: model.store.currentSpace); cleared = "Cleared data for \(model.store.currentSpace.name)" }
        case .allSpaces:
            Task { await model.clearAllWebsiteData(); cleared = "Cleared data for all spaces" }
        case .history:
            model.services.clearHistory()
            cleared = "Cleared browsing history"
        }
    }
}

private struct ResolverRow: View {
    let resolver: EncryptedDNSProxy.Resolver
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var detail: String {
        switch resolver {
        case .quad9: "Swiss nonprofit, blocks known malware domains"
        case .cloudflare: "Fast, logs purged within 24 hours"
        case .mullvad: "No logging, run by a VPN provider"
        case .off: "Use the system resolver, unencrypted"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(resolver.displayName).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor.opacity(0.1) : SettingsColors.well(scheme).opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(resolver.displayName). \(detail)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
