import AppKit
import WebKit
import os
import BrowserCore
import WebEngine
import ChromeUI
import Persistence
import Search
import Credentials

/// Process-wide services shared by every window.
@MainActor
final class AppServices {
    let store: BrowserStore
    let runtime: TabRuntime
    let sessionStore = SessionStore(directory: AppPaths.support)
    let history: HistoryStore?
    let engine: PaletteEngine
    let passwords = PasswordStore()
    lazy var credentials = CredentialsCoordinator(store: passwords)
    let blocking = BlockingAdapter()
    let extensions = ExtensionHost()
    var privacy = PrivacySettings()
    /// App-wide look (Settings → Appearance). Windows re-theme on change.
    var appearance: AppearanceSettings = {
        guard let data = UserDefaults.standard.data(forKey: "appearance"),
              let a = try? JSONDecoder().decode(AppearanceSettings.self, from: data) else { return AppearanceSettings() }
        return a
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(appearance) { UserDefaults.standard.set(data, forKey: "appearance") }
            applyAppearance()
        }
    }
    let dnsProxy = EncryptedDNSProxy(resolver: EncryptedDNSProxy.Resolver(rawValue: UserDefaults.standard.string(forKey: "dohResolver") ?? "") ?? .quad9)
    private var controllers: [BrowserWindowController] = []
    private var saveTimer: Timer?
    private let log = Logger(subsystem: "app.vane", category: "app")

    init() {
        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        store = BrowserStore(snapshot: sessionStore.load())
        runtime = TabRuntime(store: store)
        // Settings → Search & Tabs "sleep after" (it used to reset every launch).
        let sleepMinutes = UserDefaults.standard.double(forKey: "sleepMinutes")
        if sleepMinutes > 0 { runtime.hibernation.idleTimeout = sleepMinutes * 60 }
        history = try? HistoryStore(url: AppPaths.support.appending(path: "history.sqlite"))
        engine = PaletteEngine(history: history, suggester: SearchSuggester())
        if let saved = UserDefaults.standard.data(forKey: "privacy"), let p = try? JSONDecoder().decode(CodablePrivacy.self, from: saved) {
            privacy = p.settings
        }
        // 2026-11: built-in blocking became opt-in (the user runs uBlock Origin). Turn it off once
        // for existing installs; the Settings toggle still works afterwards.
        if !UserDefaults.standard.bool(forKey: "blockingOptInMigrated") {
            UserDefaults.standard.set(true, forKey: "blockingOptInMigrated")
            privacy.blockContent = false
            if let data = try? JSONEncoder().encode(CodablePrivacy(privacy)) { UserDefaults.standard.set(data, forKey: "privacy") }
        }
    }

    func start() async {
        runtime.policy = blocking
        privacy.passkeysAvailable = PasskeyAuthorization.isEntitlementLikelyPresent
        blocking.onRulesChanged = { [weak self] in self?.runtime.reloadRules() }
        // No filter-list download or 130k-rule compile unless built-in blocking is on.
        if privacy.blockContent { await blocking.start() }
        do {
            try await dnsProxy.start()
            // VANE_NO_PROXY=1: benchmarking only (load times without the DoH proxy).
            if ProcessInfo.processInfo.environment["VANE_NO_PROXY"] != "1" {
                runtime.proxyConfiguration = dnsProxy.proxyConfiguration
            }
        } catch {
            log.error("DoH proxy failed to start: \(error.localizedDescription, privacy: .public); using system DNS")
        }
        // VANE_NO_BLOCK=1: benchmarking only (load times without content blocking).
        if ProcessInfo.processInfo.environment["VANE_NO_BLOCK"] == "1" { privacy.blockContent = false }
        runtime.settings = privacy
        runtime.delegate = self
        runtime.extensionHost = extensions
        wireExtensions()
        await extensions.loadInstalled()
        runtime.startHibernation()
        store.runArchive()
        Task { try? await engine.refreshHistoryCache() }
        // Battery: nothing polls. The session saves a few seconds after it
        // actually changes; archiving runs every 10 minutes with generous
        // tolerance so macOS can coalesce the wake-up with other work.
        observeForSave()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.store.runArchive() }
        }
        saveTimer?.tolerance = 120
        Task.detached(priority: .background) { [history] in try? await history?.decayInputHistory() }
        DownloadCenter.shared.onChange = { [weak self] in self?.controllers.forEach { $0.refreshLibrary() } }
        DownloadCenter.shared.onStart = { [weak self] item in self?.frontController?.downloadStarted(item) }
    }

    // MARK: Windows

    var frontController: BrowserWindowController? {
        controllers.first { $0.window?.isKeyWindow == true } ?? controllers.first { $0.window?.isMainWindow == true } ?? controllers.last
    }

    func newWindow(spaceID: UUID? = nil, isPrivate: Bool = false) {
        let normal = store.spaces.first { $0.id == store.currentSpaceID && !store.ephemeralSpaces.contains($0.id) }
            ?? store.spaces.first { !store.ephemeralSpaces.contains($0.id) }
        let c = BrowserWindowController(app: self, spaceID: spaceID ?? normal?.id, isPrivate: isPrivate)
        if let front = frontController?.window, !front.styleMask.contains(.fullScreen), let window = c.window {
            // Cascade, so a new window doesn't land exactly on top of the last
            // one, but keep it on the front window's screen (wrap to the top-left
            // corner once it would run off the bottom or right edge).
            let frame = front.frame
            let visible = front.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
            var size = window.frame.size
            size.width = min(size.width, visible.width)
            size.height = min(size.height, visible.height)
            var origin = NSPoint(x: frame.minX + 28, y: frame.maxY - 28 - size.height)
            if origin.x + size.width > visible.maxX { origin.x = visible.minX }
            if origin.y < visible.minY { origin.y = visible.maxY - size.height }
            window.setFrame(NSRect(origin: origin, size: size), display: false)
        }
        controllers.append(c)
        c.showWindow(nil)
        if c.windowSpace.allTabs.isEmpty { c.openPalette(.newTab) }
    }

    func newPrivateWindow() {
        // A private window owns one non-persistent space: never saved, never
        // shown in other windows, torn down with its cookies when it closes.
        let space = store.addSpace(name: "Private", accentHue: 0.68, newProfile: true)
        privateProfiles.insert(space.profileID)
        runtime.ephemeralProfiles.insert(space.profileID)
        store.ephemeralSpaces.insert(space.id)
        if let midnight = SpaceTheme.presets.first(where: { $0.name == "Midnight" })?.theme { store.setTheme(midnight, for: space.id) }
        store.currentSpaceID = space.id
        newWindow(spaceID: space.id, isPrivate: true)
    }
    var privateProfiles: Set<UUID> = []
    private var crashTimes: [TabID: [Date]] = [:]
    private var passkeyHostsExplained: Set<String> = []

    func forEachController(_ body: (BrowserWindowController) -> Void) { controllers.forEach(body) }

    func applyAppearance() {
        switch appearance.mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        controllers.forEach { $0.applyTheme(animated: true) }
    }

    func windowClosed(_ c: BrowserWindowController) {
        controllers.removeAll { $0 === c }
        updateForeground()
        if c.isPrivateWindow, let sid = c.spaceID, let space = store.spaces.first(where: { $0.id == sid }) {
            let profile = space.profileID
            for id in space.allTabs { runtime.discard(id) }
            store.removeSpace(sid)
            privateProfiles.remove(profile)
            DownloadCenter.shared.forgetEphemeral()
            Task { await runtime.removeProfile(profile) }
        }
        saveSession()
    }

    func openExternal(_ url: URL) {
        if controllers.isEmpty { newWindow() }
        frontController?.navigate(to: url, newTab: true, typed: false)
        NSApp.activate()
    }

    /// A sidebar tab dropped outside every window: a new window at the drop point shows it, and
    /// the source window moves on to a neighbour. The tab stays in its space's list.
    func tearOff(_ id: TabID, from source: BrowserWindowController, at screenPoint: NSPoint) {
        guard let space = store.space(containing: id), store.tabs[id] != nil else { return }
        source.releaseTab(id)
        let c = BrowserWindowController(app: self, spaceID: space.id, isPrivate: source.isPrivateWindow)
        if let window = c.window, let srcWindow = source.window {
            let size = NSSize(width: max(srcWindow.frame.width * 0.6, 760), height: srcWindow.frame.height)
            var origin = NSPoint(x: screenPoint.x - 120, y: screenPoint.y - size.height + 20)
            if let visible = (NSScreen.screens.first { $0.frame.contains(screenPoint) } ?? srcWindow.screen)?.visibleFrame {
                origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
                origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
            }
            window.setFrame(NSRect(origin: origin, size: size), display: false)
        }
        controllers.append(c)
        c.adoptTab(id)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    /// Every tab on screen in any window: never hibernated, crash-reloaded in place.
    func updateForeground() {
        runtime.foreground = Set(controllers.flatMap(\.visibleTabs))
    }

    func move(_ id: TabID, toSpace spaceID: UUID) {
        guard let tab = store.tabs[id] else { return }
        // Moving across profiles means a different data store: reopen fresh.
        frontController?.closeTab(id)
        let newID = store.openTab(tab.url, select: false, in: spaceID)
        _ = newID
    }

    // MARK: Session

    private var saveWork: DispatchWorkItem?
    private var lastStateCapture = Date.distantPast

    private func observeForSave() {
        withObservationTracking {
            _ = store.spaces
            _ = store.tabs
            _ = store.currentSpaceID
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleSave()
                self?.observeForSave()
            }
        }
    }

    /// Coalesces bursts (page loads update titles many times) into one write.
    private func scheduleSave() {
        guard saveWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.saveWork = nil
            self?.saveSession(captureLiveState: false)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// `captureLiveState` serializes every awake tab's back/forward history,
    /// which is the expensive part: done at quit, and at most once a minute otherwise.
    func saveSession(captureLiveState: Bool = true) {
        if captureLiveState || Date().timeIntervalSince(lastStateCapture) > 60 {
            runtime.captureStates()
            lastStateCapture = Date()
        }
        var snap = store.snapshot()
        // Private spaces are never written to disk.
        let privateSpaces = Set(snap.spaces.filter { privateProfiles.contains($0.profileID) }.map(\.id))
        if !privateSpaces.isEmpty {
            let privateTabs = Set(snap.spaces.filter { privateSpaces.contains($0.id) }.flatMap(\.allTabs))
            snap.spaces.removeAll { privateSpaces.contains($0.id) }
            snap.tabs.removeAll { privateTabs.contains($0.id) }
            snap.profiles.removeAll { privateProfiles.contains($0.id) }
            if privateSpaces.contains(snap.currentSpaceID), let first = snap.spaces.first { snap.currentSpaceID = first.id }
        }
        do { try sessionStore.save(snap) } catch { log.error("session save failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: Privacy

    func applyPrivacy() {
        if privacy.blockContent && blocking.ruleLists.isEmpty { Task { await blocking.start(); runtime.reloadRules() } }
        runtime.settings = privacy
        if let data = try? JSONEncoder().encode(CodablePrivacy(privacy)) { UserDefaults.standard.set(data, forKey: "privacy") }
        controllers.forEach { $0.refresh() }
    }

    func setResolver(_ resolver: EncryptedDNSProxy.Resolver) {
        dnsProxy.resolver = resolver
        UserDefaults.standard.set(resolver.rawValue, forKey: "dohResolver")
    }

    func updateFilters(force: Bool) {
        blocking.update(force: force) { [weak self] message in
            Toast.show(message, in: self?.frontController?.window)
        }
    }

    func clearHistory() {
        Task {
            try? await history?.clear(since: .distantPast)
            try? await engine.refreshHistoryCache()
        }
    }

    func showSettings() {
        SettingsWindow.shared.show(services: self)
    }

    // MARK: Palette

    func paletteSource(for controller: BrowserWindowController, mode: BrowserWindowController.PaletteMode) -> PaletteSource {
        PaletteSource(services: self, controller: controller, mode: mode)
    }

    /// The window whose space holds this tab (banners belong beside their
    /// page, not in whichever window happens to be in front).
    func window(showing tabID: TabID) -> NSWindow? {
        let space = store.space(containing: tabID)?.id
        return controllers.first { $0.windowSpace.id == space }?.window
            ?? controllers.first { c in c.visibleSpaces.contains { $0.id == space } }?.window
            ?? frontController?.window
    }

    func isPrivate(_ tabID: TabID) -> Bool {
        guard let space = store.space(containing: tabID) else { return false }
        return privateProfiles.contains(space.profileID)
    }
}

// MARK: - Web tab events

extension AppServices: WebTabDelegate {
    func webTabDidChange(_ tab: WebTab) {
        extensions.webTabDidChange(tab)
        store.update(tab.id) { record in
            // A failed HTTPS upgrade (or an aborted load) briefly reports
            // about:blank; never let it overwrite the address the tab is for,
            // or the session restores a blank tab.
            if let url = tab.url, url.scheme != "about" || record.url == nil {
                record.url = url
                if !tab.title.isEmpty { record.title = tab.title }
            }
            if record.activity != tab.activity { record.activity = tab.activity }
        }
        for c in controllers where c.store.currentSpace.selected == tab.id { c.scheduleRefresh() }
    }

    func webTab(_ tab: WebTab, didCommit url: URL, title: String?, typed: Bool) {
        if tab.id == frontController?.store.currentSpace.selected, extensions.storeExtensionID(for: url) != nil, title == nil || !typed {
            offerStoreInstall(for: url)
        }
        guard !isPrivate(tab.id), let history, url.scheme == "http" || url.scheme == "https" else { return }
        Task.detached(priority: .utility) {
            try? await history.recordVisit(url: url, title: title, kind: typed ? .typed : .link, at: Date())
        }
    }

    func webTab(_ tab: WebTab, openInNewTab request: URLRequest, background: Bool, configuration: WKWebViewConfiguration?) -> WKWebView? {
        guard let space = store.space(containing: tab.id) else { return nil }
        let id = store.openTab(request.url, select: !background, in: space.id)
        guard let configuration else {
            // ⌘-click: a normal tab that loads its URL when shown.
            if !background { frontController?.scheduleRefresh() }
            return nil
        }
        // window.open / target=_blank: WebKit requires a view built from exactly
        // this configuration (anything else raises and aborts the app). It
        // loads the request itself, and keeps window.opener working.
        return runtime.adopt(id, configuration: configuration)
    }

    func webTabDidFinish(_ tab: WebTab, url: URL, title: String?) {
        guard !isPrivate(tab.id), let history, let title, !title.isEmpty, url.scheme == "http" || url.scheme == "https" else { return }
        Task.detached(priority: .utility) { try? await history.updateTitle(url: url, title: title) }
    }

    func webTabProcessDidTerminate(_ tab: WebTab) {
        let id = tab.id
        if runtime.foreground.contains(id) {
            let now = Date()
            crashTimes[id, default: []].append(now)
            crashTimes[id] = crashTimes[id]?.filter { now.timeIntervalSince($0) < 60 }
            if (crashTimes[id]?.count ?? 0) <= 3 {
                tab.reload()
            } else {
                Toast.show("This page keeps crashing, so Vane stopped reloading it", in: frontController?.window)
                Task { await runtime.sleep(id) }
            }
        } else {
            // Background: free it now; it reloads from its saved state when shown.
            Task { await runtime.sleep(id) }
        }
    }

    /// Once per site per launch: say why the passkey prompt didn't appear and
    /// offer the ways in that do work.
    private func explainPasskeys(host: String, tab: WebTab) {
        guard !passkeyHostsExplained.contains(host), let url = tab.url else { return }
        passkeyHostsExplained.insert(host)
        CredentialBanner.show(in: frontController?.window, symbol: "person.badge.key",
                              text: "Passkeys aren't available in Vane yet — use \u{201C}Try another way\u{201D} to sign in with your password.",
                              primary: "Open in Safari", secondary: "OK", timeout: 25,
                              primaryAction: {
                                  if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
                                      NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
                                  }
                              })
    }

    func webTabDidRequestClose(_ tab: WebTab) {
        frontController?.closeTab(tab.id)
    }

    func webTab(_ tab: WebTab, autofillMessage body: [String: Any]) {
        if CommandLine.arguments.contains("--snapshot") { print("AUTOFILL \(body["type"] ?? "?") host=\(body["host"] ?? "?") tab=\(tab.url?.host() ?? "nil") at \(Date().timeIntervalSince1970)"); fflush(stdout) }
        guard let type = body["type"] as? String, let host = body["host"] as? String else { return }
        if type == "passkeyBlocked" { explainPasskeys(host: host, tab: tab); return }
        // Only trust messages whose host matches the tab's top-level page.
        guard host == tab.url?.host() else { return }
        switch type {
        case "formsFound":
            Task { [weak self] in
                guard let self else { return }
                let suggestions = await credentials.didFindForms(host: host)
                guard let first = suggestions.first else { return }
                CredentialBanner.offerFill(suggestion: first, count: suggestions.count, insecure: tab.url?.scheme != "https",
                                           in: window(showing: tab.id)) { [weak self] in
                    guard let self else { return }
                    Task {
                        guard let values = await self.credentials.fillValues(for: first) else { return }
                        tab.fillCredentials(username: values.username, password: values.password)
                    }
                }
            }
        case "submitted":
            guard !isPrivate(tab.id), let username = body["username"] as? String, let password = body["password"] as? String else { return }
            Task {
                let t0 = Date()
                let decision = await credentials.didSubmit(host: host, username: username, password: password)
                if CommandLine.arguments.contains("--snapshot") { print("AUTOFILL decision \(decision) in \(Date().timeIntervalSince(t0))s"); fflush(stdout) }
                CredentialBanner.offerSave(decision, insecure: tab.url?.scheme != "https", in: window(showing: tab.id),
                                           credentials: credentials, password: password)
            }
        default: break
        }
    }
}

/// PrivacySettings is a WebEngine type; persist it without making it Codable there.
struct CodablePrivacy: Codable {
    var blockContent, fingerprintProtection, httpsOnly, stripTrackingParameters: Bool
    init(_ s: PrivacySettings) {
        blockContent = s.blockContent; fingerprintProtection = s.fingerprintProtection
        httpsOnly = s.httpsOnly; stripTrackingParameters = s.stripTrackingParameters
    }
    var settings: PrivacySettings {
        var s = PrivacySettings()
        s.blockContent = blockContent; s.fingerprintProtection = fingerprintProtection
        s.httpsOnly = httpsOnly; s.stripTrackingParameters = stripTrackingParameters
        return s
    }
}
