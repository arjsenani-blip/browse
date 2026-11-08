import AppKit
import SwiftUI
import BrowserCore
import WebEngine
import Credentials

/// Settings: privacy switches, tab lifetimes, passkeys status. SwiftUI leaf.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(services: AppServices) {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let view = SettingsView(model: SettingsModel(services: services))
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Aegis Settings"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

@MainActor
@Observable
final class SettingsModel {
    private unowned let services: AppServices
    var blockContent: Bool { didSet { push() } }
    var fingerprint: Bool { didSet { push() } }
    var strip: Bool { didSet { push() } }
    var httpsOnly: Bool { didSet { push() } }
    var archiveHours: Double { didSet { pushArchive() } }
    var sleepMinutes: Double { didSet { services.runtime.hibernation.idleTimeout = sleepMinutes * 60 } }
    var passkeyStatus = "Checking…"
    var resolver: EncryptedDNSProxy.Resolver { didSet { services.setResolver(resolver) } }

    init(services: AppServices) {
        self.services = services
        let p = services.privacy
        blockContent = p.blockContent
        fingerprint = p.fingerprintProtection
        strip = p.stripTrackingParameters
        httpsOnly = p.httpsOnly
        archiveHours = services.store.currentSpace.archiveAfter / 3600
        sleepMinutes = services.runtime.hibernation.idleTimeout / 60
        resolver = services.dnsProxy.resolver
        let passkeys = PasskeyAuthorization()
        passkeyStatus = switch passkeys.authorizationState {
        case .unavailableNoEntitlement: "Needs Apple's browser passkey entitlement (not in this build)"
        case .notDetermined: "Not yet allowed"
        case .denied: "Denied in System Settings"
        case .authorized: "Using iCloud Keychain passkeys"
        }
    }

    private func push() {
        services.privacy.blockContent = blockContent
        services.privacy.fingerprintProtection = fingerprint
        services.privacy.stripTrackingParameters = strip
        services.privacy.httpsOnly = httpsOnly
        services.applyPrivacy()
    }

    private func pushArchive() {
        services.store.setArchiveInterval(archiveHours * 3600)
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Privacy") {
                Toggle("Block ads and trackers", isOn: $model.blockContent)
                Toggle("Fingerprint protection", isOn: $model.fingerprint)
                Toggle("Remove tracking parameters from links", isOn: $model.strip)
                Toggle("HTTPS only (ask before falling back)", isOn: $model.httpsOnly)
                Picker("Encrypted DNS", selection: $model.resolver) {
                    ForEach(EncryptedDNSProxy.Resolver.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("Aegis sends no telemetry. The only requests it makes on its own are filter-list updates from easylist.to.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tabs") {
                Picker("Archive today's tabs after", selection: $model.archiveHours) {
                    Text("12 hours").tag(12.0); Text("1 day").tag(24.0); Text("1 week").tag(168.0); Text("30 days").tag(720.0)
                }
                Picker("Put background tabs to sleep after", selection: $model.sleepMinutes) {
                    Text("5 minutes").tag(5.0); Text("15 minutes").tag(15.0); Text("30 minutes").tag(30.0); Text("2 hours").tag(120.0)
                }
            }
            Section("Passwords") {
                LabeledContent("Passkeys", value: model.passkeyStatus)
                Text("Saved passwords are stored in your Mac's Keychain. Import from the Passwords app with File → Import Passwords.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
    }
}
