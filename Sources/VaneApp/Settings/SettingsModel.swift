import AppKit
import SwiftUI
import BrowserCore
import WebEngine
import Credentials

/// The panes in the Settings sidebar, in order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance, spaces, privacy, tabs, passwords, extensions, downloads, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .spaces: "Spaces"
        case .privacy: "Privacy & Security"
        case .tabs: "Search & Tabs"
        case .passwords: "Passwords"
        case .extensions: "Extensions"
        case .downloads: "Downloads"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: "paintbrush.fill"
        case .spaces: "square.grid.2x2.fill"
        case .privacy: "hand.raised.fill"
        case .tabs: "magnifyingglass"
        case .passwords: "key.fill"
        case .extensions: "puzzlepiece.extension.fill"
        case .downloads: "arrow.down.circle.fill"
        case .about: "info.circle.fill"
        }
    }

    /// The icon tile colour, like System Settings.
    var tint: Color {
        switch self {
        case .appearance: Color(red: 0.36, green: 0.42, blue: 0.95)
        case .spaces: Color(red: 0.05, green: 0.60, blue: 0.55)
        case .privacy: Color(red: 0.20, green: 0.48, blue: 0.96)
        case .tabs: Color(red: 0.55, green: 0.56, blue: 0.60)
        case .passwords: Color(red: 0.55, green: 0.56, blue: 0.60)
        case .extensions: Color(red: 0.95, green: 0.55, blue: 0.15)
        case .downloads: Color(red: 0.18, green: 0.62, blue: 0.95)
        case .about: Color(red: 0.55, green: 0.56, blue: 0.60)
        }
    }
}

/// State for the Settings window. Reads and writes go straight through to
/// `AppServices`; values that live on non-observable types are mirrored here
/// so SwiftUI redraws, and pushed back in `didSet`.
@MainActor
@Observable
final class SettingsModel {
    unowned let services: AppServices
    var pane: SettingsPane = .appearance

    // Appearance (AppServices.appearance re-themes every window on set).
    var appearance: AppearanceSettings { didSet { if appearance != oldValue { services.appearance = appearance } } }

    // Privacy
    var blockContent: Bool { didSet { pushPrivacy() } }
    var fingerprint: Bool { didSet { pushPrivacy() } }
    var strip: Bool { didSet { pushPrivacy() } }
    var httpsOnly: Bool { didSet { pushPrivacy() } }
    var resolver: EncryptedDNSProxy.Resolver { didSet { if resolver != oldValue { services.setResolver(resolver) } } }

    // Tabs
    var tabsOnTop: Bool { didSet { if tabsOnTop != oldValue { services.forEachController { $0.tabsOnTop = tabsOnTop } } } }
    var archiveHours: Double { didSet { services.store.setArchiveInterval(archiveHours * 3600) } }
    var sleepMinutes: Double {
        didSet {
            services.runtime.hibernation.idleTimeout = sleepMinutes * 60
            UserDefaults.standard.set(sleepMinutes, forKey: "sleepMinutes")
        }
    }

    var searchEngine: SearchEngine = SearchEngine.current { didSet { SearchEngine.current = searchEngine } }
    var searchSuggestions = SearchEngine.suggestionsEnabled { didSet { SearchEngine.suggestionsEnabled = searchSuggestions } }

    // Spaces pane selection
    var selectedSpaceID: UUID?

    /// Bumped to redraw views that read non-observable sources (extensions, downloads, rule count).
    var tick = 0

    let passkeyStatus: String
    let passkeysReady: Bool

    init(services: AppServices) {
        self.services = services
        appearance = services.appearance
        let p = services.privacy
        blockContent = p.blockContent
        fingerprint = p.fingerprintProtection
        strip = p.stripTrackingParameters
        httpsOnly = p.httpsOnly
        resolver = services.dnsProxy.resolver
        tabsOnTop = UserDefaults.standard.bool(forKey: "tabsOnTop")
        archiveHours = services.store.currentSpace.archiveAfter / 3600
        sleepMinutes = services.runtime.hibernation.idleTimeout / 60
        selectedSpaceID = services.store.currentSpaceID
        let state = PasskeyAuthorization().authorizationState
        passkeysReady = state == .authorized
        passkeyStatus = switch state {
        case .unavailableNoEntitlement: "Needs Apple's browser passkey entitlement (not in this build)"
        case .notDetermined: "Not yet allowed"
        case .denied: "Denied in System Settings"
        case .authorized: "Using iCloud Keychain passkeys"
        }
    }

    /// Re-reads values other parts of the app may have changed while the window was closed.
    func resync() {
        if services.appearance != appearance { appearance = services.appearance }
        let onTop = UserDefaults.standard.bool(forKey: "tabsOnTop")
        if onTop != tabsOnTop { tabsOnTop = onTop }
        if services.dnsProxy.resolver != resolver { resolver = services.dnsProxy.resolver }
        if let id = selectedSpaceID, !services.store.spaces.contains(where: { $0.id == id }) {
            selectedSpaceID = services.store.currentSpaceID
        }
        tick += 1
    }

    private func pushPrivacy() {
        var p = services.privacy
        p.blockContent = blockContent
        p.fingerprintProtection = fingerprint
        p.stripTrackingParameters = strip
        p.httpsOnly = httpsOnly
        guard p != services.privacy else { return }
        services.privacy = p
        services.applyPrivacy()
    }

    // MARK: Spaces

    var store: BrowserStore { services.store }

    func isPrivate(_ space: Space) -> Bool { services.privateProfiles.contains(space.profileID) }

    /// Spaces Settings can list and edit: a private window's throwaway space
    /// is never listed, renamed, themed or deleted from here.
    var spaces: [Space] { store.spaces.filter { !store.ephemeralSpaces.contains($0.id) } }

    /// Other spaces that share this space's cookies and logins.
    func spacesSharingProfile(with space: Space) -> [Space] {
        store.spaces.filter { $0.profileID == space.profileID && $0.id != space.id }
    }

    func addSpace() {
        let hues = [0.48, 0.60, 0.08, 0.92, 0.33, 0.68]
        let space = store.addSpace(name: "Space \(store.spaces.count + 1)", accentHue: hues[store.spaces.count % hues.count], newProfile: true)
        selectedSpaceID = space.id
        services.forEachController { $0.refresh() }
    }

    func setTheme(_ theme: SpaceTheme, for id: UUID) {
        store.setTheme(theme, for: id)
        services.applyAppearance()
    }

    func rename(_ id: UUID, to name: String) {
        store.renameSpace(id, name: name)
        services.forEachController { $0.refresh() }
    }

    func moveSpace(_ id: UUID, before target: UUID) {
        guard let from = store.spaces.firstIndex(where: { $0.id == id }),
              let to = store.spaces.firstIndex(where: { $0.id == target }), from != to else { return }
        store.moveSpace(from: from, to: to > from ? to + 1 : to)
        services.forEachController { $0.refresh() }
    }

    /// Deletes a space the caller already confirmed (no second alert). A normal
    /// window does the work so tabs, reader and extensions are torn down the
    /// same way as from the sidebar; with no window open it's done here.
    func deleteSpace(_ id: UUID) {
        guard spaces.count > 1, let space = spaces.first(where: { $0.id == id }) else { return }
        var window = services.frontController.flatMap { $0.isPrivateWindow ? nil : $0 }
        if window == nil { services.forEachController { c in if window == nil, !c.isPrivateWindow { window = c } } }
        if let window {
            window.deleteSpace(id, confirm: false)
        } else {
            let profile = store.profile(for: space)
            let sharedProfile = store.spaces.filter { $0.profileID == profile.id }.count > 1
            for tab in space.allTabs { services.runtime.discard(tab) }
            store.removeSpace(id)
            if !sharedProfile {
                let runtime = services.runtime
                Task { await runtime.removeProfile(profile.id) }
            }
            services.forEachController { $0.refresh() }
        }
        if !store.spaces.contains(where: { $0.id == selectedSpaceID }) { selectedSpaceID = store.currentSpaceID }
    }

    // MARK: Website data

    func clearData(for space: Space) async {
        await services.runtime.context(for: store.profile(for: space)).clearData()
    }

    func clearAllWebsiteData() async {
        for profile in store.profiles { await services.runtime.context(for: profile).clearData() }
    }
}
