import AppKit
import CryptoKit
import WebKit
import os

public enum ExtensionHostError: Error, Sendable {
    case notAWebStoreURL
    case unknownExtension(String)
    case notSupported
}

/// What an extension asked WebKit to open; the app decides where and whether.
@MainActor
public struct ExtensionTabRequest {
    public let extensionID: String
    public let url: URL?
    public let window: (any WKWebExtensionWindow)?
    /// Index of `window` in `openWindows()`, when it's one of ours.
    public let windowIndex: Int?
    /// Requested position inside the window.
    public let index: Int
    public let active: Bool
    public let pinned: Bool
    public let muted: Bool
    public let parent: (any WKWebExtensionTab)?
}

@MainActor
public struct ExtensionWindowRequest {
    public let extensionID: String
    public let urls: [URL]
    /// Existing tabs to move into the new window.
    public let tabs: [any WKWebExtensionTab]
    /// Components are NaN when unspecified.
    public let frame: CGRect
    public let focused: Bool
    public let isPrivate: Bool
    public let type: WKWebExtension.WindowType
}

/// A runtime `permissions.request()` (or access request) from a loaded extension.
@MainActor
public struct ExtensionPermissionPrompt {
    public struct Answer: Sendable, Equatable {
        public var permissions: Set<String>
        public var matchPatterns: Set<String>
        public var urls: Set<URL>
        public static let deny = Answer(permissions: [], matchPatterns: [], urls: [])
        public init(permissions: Set<String> = [], matchPatterns: Set<String> = [], urls: Set<URL> = []) {
            self.permissions = permissions
            self.matchPatterns = matchPatterns
            self.urls = urls
        }
    }
    public let extensionID: String
    public let name: String
    public let permissions: [String]
    public let matchPatterns: [String]
    public let urls: [URL]
    public let tab: (any WKWebExtensionTab)?
}

/// Runtime status for the extensions list / settings UI.
public struct ExtensionStatus: Sendable {
    public let record: InstalledExtension
    public let isLoaded: Bool
    public let errors: [String]
    public let pending: ExtensionPermissionRequest?
}

/// Owns the app's `WKWebExtensionController`, the installed set on disk, the
/// user's permission grants, and the controller delegate that turns extension
/// requests into calls on closures the app supplies.
///
/// Lifecycle: `install` downloads, verifies and unpacks but does not load;
/// the app shows `pendingPermissions(for:)` in a consent sheet and calls
/// `grant(_:)` (which loads) or `uninstall(id:)`.
@MainActor
public final class ExtensionHost: NSObject {
    public let controller: WKWebExtensionController
    public let installer: ExtensionInstaller
    private let store: ExtensionStateStore
    private var state: ExtensionStateFile
    private var webExtensions: [String: WKWebExtension] = [:]
    private var contexts: [String: WKWebExtensionContext] = [:]
    private var failures: [String: String] = [:]
    private var tabAdapters: [ObjectIdentifier: ExtensionTabAdapter] = [:]
    private var windowAdapters: [ObjectIdentifier: ExtensionWindowAdapter] = [:]
    var tabSnapshots: [ObjectIdentifier: TabSnapshot] = [:]
    private let log = Logger(subsystem: "app.aegis", category: "extensions")

    // MARK: App-supplied callbacks

    /// Open a tab (chrome.tabs.create, options page fallback, …). Return the tab, or nil to refuse.
    public var openTab: ((ExtensionTabRequest) -> (any WKWebExtensionTab)?)?
    /// Open a window (chrome.windows.create). Return it, or nil to refuse.
    public var openWindow: ((ExtensionWindowRequest) -> (any WKWebExtensionWindow)?)?
    /// All browser windows, focused first. Required for chrome.tabs/windows queries.
    public var openWindows: () -> [any WKWebExtensionWindow] = { [] }
    /// The focused window; defaults to the first of `openWindows()`.
    public var focusedWindow: (() -> (any WKWebExtensionWindow)?)?
    /// Show `action.popupWebView` (an NSPopover anchored to the toolbar button). Called once the popup has loaded.
    public var presentActionPopup: ((WKWebExtension.Action, String) -> Void)?
    /// Badge/icon/label changed: refresh the toolbar button for this extension ID.
    public var actionDidUpdate: ((WKWebExtension.Action, String) -> Void)?
    /// Ask the user about a runtime permission request. Unset = deny.
    public var promptForPermissions: ((ExtensionPermissionPrompt) async -> ExtensionPermissionPrompt.Answer)?
    /// Show the options page. `configuration` must be used for the web view
    /// that loads `url`. Unset = open via `openTab`.
    public var openOptionsPage: ((_ url: URL, _ configuration: WKWebViewConfiguration?, _ extensionID: String) -> Void)?
    /// Anything visible changed (installed set, enabled, errors, grants).
    public var onChange: (() -> Void)?

    // MARK: Init

    /// - Parameters:
    ///   - root: install folder; `state.json` lives here.
    ///   - websiteDataStore: store whose cookies `chrome.cookies` sees by default (the default profile's).
    ///   - persistent: false keeps extension storage in memory (tests, throwaway sessions).
    public init(root: URL = ExtensionInstaller.defaultRoot, websiteDataStore: WKWebsiteDataStore? = nil, persistent: Bool = true) {
        installer = ExtensionInstaller(root: root)
        store = ExtensionStateStore(root: root)
        state = store.load()
        let config: WKWebExtensionController.Configuration = persistent
            ? .init(identifier: state.controllerID)
            : .nonPersistent()
        if let websiteDataStore { config.defaultWebsiteDataStore = websiteDataStore }
        controller = WKWebExtensionController(configuration: config)
        super.init()
        controller.delegate = self
        let nc = NotificationCenter.default
        for name in [WKWebExtensionContext.errorsDidUpdateNotification] {
            nc.addObserver(self, selector: #selector(contextErrorsChanged(_:)), name: name, object: nil)
        }
        for name in [WKWebExtensionContext.permissionsWereGrantedNotification,
                     WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
                     WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
                     WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification,
                     WKWebExtensionContext.permissionMatchPatternsWereDeniedNotification] {
            nc.addObserver(self, selector: #selector(contextPermissionsChanged(_:)), name: name, object: nil)
        }
    }

    /// Content scripts, declarativeNetRequest rules and tab APIs only reach web
    /// views whose configuration carries this controller. Call for every
    /// browsing web view configuration before creating the web view.
    public func configure(_ configuration: WKWebViewConfiguration) {
        configuration.webExtensionController = controller
    }

    /// Loads every installed, enabled, consented extension. Call once at launch.
    public func loadInstalled() async {
        for record in state.extensions {
            do {
                _ = try await prepare(record.id)
                if record.enabled, record.consented { try activate(record.id) }
            } catch {
                failures[record.id] = describe(error)
                log.error("extension \(record.id, privacy: .public) failed to load: \(String(describing: error), privacy: .public)")
            }
        }
        onChange?()
    }

    // MARK: Queries

    public var extensions: [InstalledExtension] { state.extensions }

    public func record(for id: String) -> InstalledExtension? { state.extensions.first { $0.id == id } }

    public func isInstalled(_ id: String) -> Bool { record(for: id) != nil }

    public func context(for id: String) -> WKWebExtensionContext? { contexts[id] }

    public func webExtension(for id: String) -> WKWebExtension? { webExtensions[id] }

    /// Parse-time and runtime errors, plus a load failure if there was one.
    public func errors(for id: String) -> [String] {
        var out = (contexts[id]?.errors ?? webExtensions[id]?.errors ?? []).map(describe)
        if let failure = failures[id] { out.insert(failure, at: 0) }
        return out
    }

    public func status(for id: String) -> ExtensionStatus? {
        guard let record = record(for: id) else { return nil }
        return ExtensionStatus(record: record, isLoaded: contexts[id]?.isLoaded ?? false,
                               errors: errors(for: id), pending: pendingPermissions(for: id))
    }

    /// Requested permissions and host patterns the user hasn't granted yet.
    /// Nil when there's nothing to ask (or the ID is unknown).
    public func pendingPermissions(for id: String) -> ExtensionPermissionRequest? {
        guard let record = record(for: id) else { return nil }
        let requested: (perms: [String], patterns: [String])
        if let ext = webExtensions[id] {
            requested = (ext.requestedPermissions.map(\.rawValue), ext.allRequestedMatchPatterns.map(\.string))
        } else if let m = try? ExtensionManifest.read(from: installer.directory(for: id)) {
            requested = (m.permissions, m.hostPermissions + m.contentScriptMatches)
        } else { return nil }
        let grantedP = Set(record.grantedPermissions), grantedM = Set(record.grantedMatchPatterns + record.deniedMatchPatterns)
        let request = ExtensionPermissionRequest(
            extensionID: id, name: record.name,
            permissions: Set(requested.perms).subtracting(grantedP).sorted(),
            matchPatterns: Set(requested.patterns).subtracting(grantedM).sorted())
        return request.isEmpty && record.consented ? nil : request
    }

    /// The Web Store ID for a store page URL, for the "Add to Aegis" banner.
    public func storeExtensionID(for url: URL) -> String? {
        ChromeWebStore.isStorePage(url) ? ChromeExtensionID.fromWebStoreURL(url) : nil
    }

    // MARK: Install / uninstall

    /// Store URL → download → verify CRX signatures → unpack. Does not load:
    /// show `pendingPermissions(for:)` and call `grant(_:)`.
    @discardableResult
    public func install(fromWebStoreURL url: URL) async throws -> InstalledExtension {
        guard let id = ChromeExtensionID.fromWebStoreURL(url) else { throw ExtensionHostError.notAWebStoreURL }
        return try await install(id: id)
    }

    @discardableResult
    public func install(id: String) async throws -> InstalledExtension {
        let crx = try await ChromeWebStore.downloadCRX(id: id)
        return try await install(crx: crx, id: id)
    }

    /// Installs CRX bytes obtained elsewhere. Web Store packages must carry the
    /// store's publisher signature unless `requirePublisherProof` is false.
    @discardableResult
    public func install(crx: Data, id: String, requirePublisherProof: Bool = true) async throws -> InstalledExtension {
        let zip = try await Task.detached {
            let package = try CRXPackage.parse(crx)
            try package.verify(expectedID: id, requirePublisherProof: requirePublisherProof)
            return package.zip
        }.value
        let manifest = try await installer.install(zip: zip, id: id)
        return try await register(id: id, manifest: manifest, source: .webStore)
    }

    /// Developer "load unpacked": copies the folder in. ID derives from the path, like Chrome.
    @discardableResult
    public func installUnpacked(from directory: URL) async throws -> InstalledExtension {
        let id = ChromeExtensionID.from(publicKey: Data(directory.standardizedFileURL.path.utf8))
        let manifest = try installer.install(directory: directory, id: id)
        return try await register(id: id, manifest: manifest, source: .unpacked)
    }

    private func register(id: String, manifest: ExtensionManifest, source: InstalledExtension.Source) async throws -> InstalledExtension {
        // Reinstall/update: drop the old WebKit objects, keep the user's grants.
        deactivate(id)
        webExtensions[id] = nil
        contexts[id] = nil
        failures[id] = nil
        var record = record(for: id) ?? InstalledExtension(id: id, manifest: manifest, source: source)
        record.name = manifest.name
        record.version = manifest.version
        record.manifestVersion = manifest.manifestVersion
        upsert(record)
        do {
            let ext = try await prepare(id)
            if let name = ext.displayName { record.name = name; upsert(record) }
        } catch {
            try? installer.remove(id: id)
            state.extensions.removeAll { $0.id == id }
            try? persist()
            throw error
        }
        // An update that asks for more needs consent again before it runs.
        if let pending = pendingPermissions(for: id), !pending.isEmpty { record.consented = false; upsert(record) }
        try persist()
        if record.enabled, record.consented { try? activate(id) }
        onChange?()
        return record
    }

    public func uninstall(id: String) async throws {
        guard record(for: id) != nil else { throw ExtensionHostError.unknownExtension(id) }
        if let ctx = contexts[id] {
            deactivate(id)
            if let data = await controller.dataRecord(ofTypes: WKWebExtensionController.allExtensionDataTypes, for: ctx) {
                await withCheckedContinuation { cont in
                    controller.removeData(ofTypes: WKWebExtensionController.allExtensionDataTypes, from: [data]) { cont.resume() }
                }
            }
        }
        contexts[id] = nil
        webExtensions[id] = nil
        failures[id] = nil
        state.extensions.removeAll { $0.id == id }
        try installer.remove(id: id)
        try persist()
        onChange?()
    }

    public func setEnabled(_ enabled: Bool, for id: String) throws {
        guard var record = record(for: id) else { throw ExtensionHostError.unknownExtension(id) }
        record.enabled = enabled
        upsert(record)
        try persist()
        if enabled, record.consented { try activate(id) } else { deactivate(id) }
        onChange?()
    }

    // MARK: Consent

    /// Records the user's consent (any subset of the request) and loads the extension if enabled.
    public func grant(_ grant: ExtensionPermissionGrant) throws {
        guard var record = record(for: grant.extensionID) else { throw ExtensionHostError.unknownExtension(grant.extensionID) }
        record.grantedPermissions = Array(Set(record.grantedPermissions).union(grant.permissions)).sorted()
        record.grantedMatchPatterns = Array(Set(record.grantedMatchPatterns).union(grant.matchPatterns)).sorted()
        record.deniedMatchPatterns.removeAll { grant.matchPatterns.contains($0) }
        record.allowInPrivate = grant.allowInPrivate
        record.consented = true
        upsert(record)
        try persist()
        if let ctx = contexts[record.id] {
            apply(record, to: ctx)
        }
        if record.enabled { try activate(record.id) }
        onChange?()
    }

    /// Withdraws previously granted permissions/patterns (settings UI).
    public func revoke(_ grant: ExtensionPermissionGrant) throws {
        guard var record = record(for: grant.extensionID) else { throw ExtensionHostError.unknownExtension(grant.extensionID) }
        record.grantedPermissions.removeAll { grant.permissions.contains($0) }
        record.grantedMatchPatterns.removeAll { grant.matchPatterns.contains($0) }
        upsert(record)
        try persist()
        if let ctx = contexts[record.id] {
            for p in grant.permissions { ctx.setPermissionStatus(.unknown, for: WKWebExtension.Permission(rawValue: p)) }
            for s in grant.matchPatterns {
                if let mp = try? WKWebExtension.MatchPattern(string: s) { ctx.setPermissionStatus(.unknown, for: mp) }
            }
        }
        onChange?()
    }

    // MARK: Actions & commands

    public func action(for id: String, tab: (any WKWebExtensionTab)?) -> WKWebExtension.Action? {
        contexts[id]?.action(for: tab)
    }

    /// Toolbar button clicked. WebKit grants activeTab, then either fires
    /// `action.onClicked` or loads the popup and calls `presentActionPopup`.
    public func performAction(for id: String, tab: (any WKWebExtensionTab)?) {
        if let tab { contexts[id]?.userGesturePerformed(in: tab) }
        contexts[id]?.performAction(for: tab)
    }

    /// Keyboard shortcut from an extension's `commands`. Returns true if handled.
    public func performCommand(for event: NSEvent) -> Bool {
        contexts.values.contains { $0.isLoaded && $0.performCommand(for: event) }
    }

    /// Context menu items for a tab, from every loaded extension.
    public func menuItems(for tab: any WKWebExtensionTab) -> [NSMenuItem] {
        contexts.values.filter(\.isLoaded).flatMap { $0.menuItems(for: tab) }
    }

    /// Navigating a tab to a `webkit-extension://` URL needs a web view built
    /// from this configuration (and back to the profile's for normal URLs).
    public func webViewConfiguration(forExtensionURL url: URL) -> WKWebViewConfiguration? {
        controller.extensionContext(for: url)?.webViewConfiguration
    }

    // MARK: Adapters (one per object, stable identity)

    public func tabAdapter(for owner: AnyObject, make: () -> ExtensionTabAdapter) -> ExtensionTabAdapter {
        let key = ObjectIdentifier(owner)
        if let a = tabAdapters[key] { return a }
        let a = make()
        tabAdapters[key] = a
        return a
    }

    public func existingTabAdapter(for owner: AnyObject) -> ExtensionTabAdapter? { tabAdapters[ObjectIdentifier(owner)] }

    public func windowAdapter(for owner: AnyObject, make: () -> ExtensionWindowAdapter) -> ExtensionWindowAdapter {
        let key = ObjectIdentifier(owner)
        if let a = windowAdapters[key] { return a }
        let a = make()
        windowAdapters[key] = a
        return a
    }

    public func existingWindowAdapter(for owner: AnyObject) -> ExtensionWindowAdapter? { windowAdapters[ObjectIdentifier(owner)] }

    // MARK: Notify (call from the app's tab/window lifecycle)

    public func didOpen(tab: any WKWebExtensionTab) { controller.didOpenTab(tab) }
    public func didActivate(tab: any WKWebExtensionTab, previous: (any WKWebExtensionTab)? = nil) {
        controller.didActivateTab(tab, previousActiveTab: previous)
        controller.didSelectTabs([tab])
        if let previous { controller.didDeselectTabs([previous]) }
    }
    /// Also forgets the adapter registered for `owner`, if given.
    public func didClose(tab: any WKWebExtensionTab, windowIsClosing: Bool = false, owner: AnyObject? = nil) {
        controller.didCloseTab(tab, windowIsClosing: windowIsClosing)
        if let owner { tabAdapters[ObjectIdentifier(owner)] = nil }
    }
    public func didChangeProperties(_ properties: WKWebExtension.TabChangedProperties, tab: any WKWebExtensionTab) {
        controller.didChangeTabProperties(properties, for: tab)
    }
    public func didMove(tab: any WKWebExtensionTab, from index: Int, in window: (any WKWebExtensionWindow)?) {
        controller.didMoveTab(tab, from: index, in: window)
    }
    public func didReplace(tab old: any WKWebExtensionTab, with new: any WKWebExtensionTab) {
        controller.didReplaceTab(old, with: new)
    }
    public func didOpen(window: any WKWebExtensionWindow) { controller.didOpenWindow(window) }
    public func didFocus(window: (any WKWebExtensionWindow)?) { controller.didFocusWindow(window) }
    public func didClose(window: any WKWebExtensionWindow, owner: AnyObject? = nil) {
        controller.didCloseWindow(window)
        if let owner { windowAdapters[ObjectIdentifier(owner)] = nil }
    }

    // MARK: Internals

    private func prepare(_ id: String) async throws -> WKWebExtension {
        if let ext = webExtensions[id] { return ext }
        let ext = try await WKWebExtension(resourceBaseURL: installer.directory(for: id))
        webExtensions[id] = ext
        return ext
    }

    private func activate(_ id: String) throws {
        guard let ext = webExtensions[id], let record = record(for: id) else { throw ExtensionHostError.unknownExtension(id) }
        let ctx: WKWebExtensionContext
        if let existing = contexts[id] {
            ctx = existing
        } else {
            ctx = WKWebExtensionContext(for: ext)
            // Stable identity across launches: runtime.id == the Chrome ID, and
            // storage keyed by base URL survives relaunch.
            ctx.uniqueIdentifier = id
            if let base = URL(string: "webkit-extension://\(id)/") { ctx.baseURL = base }
            ctx.inspectionName = record.name
            #if DEBUG
            ctx.isInspectable = true
            #endif
            apply(record, to: ctx)
            contexts[id] = ctx
        }
        guard !ctx.isLoaded else { return }
        do {
            try controller.load(ctx)
            failures[id] = nil
        } catch {
            failures[id] = describe(error)
            throw error
        }
    }

    private func deactivate(_ id: String) {
        guard let ctx = contexts[id], ctx.isLoaded else { return }
        do { try controller.unload(ctx) } catch { log.error("unload \(id, privacy: .public): \(String(describing: error), privacy: .public)") }
    }

    private func apply(_ record: InstalledExtension, to ctx: WKWebExtensionContext) {
        if !ctx.isLoaded { ctx.hasAccessToPrivateData = record.allowInPrivate }
        ctx.hasRequestedOptionalAccessToAllHosts = record.hasRequestedOptionalAccessToAllHosts
        for p in record.grantedPermissions {
            ctx.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: p))
        }
        for s in record.grantedMatchPatterns {
            if let mp = try? WKWebExtension.MatchPattern(string: s) { ctx.setPermissionStatus(.grantedExplicitly, for: mp) }
        }
        for s in record.deniedMatchPatterns {
            if let mp = try? WKWebExtension.MatchPattern(string: s) { ctx.setPermissionStatus(.deniedExplicitly, for: mp) }
        }
    }

    private func id(of context: WKWebExtensionContext) -> String? {
        contexts.first { $0.value === context }?.key
    }

    private func upsert(_ record: InstalledExtension) {
        if let i = state.extensions.firstIndex(where: { $0.id == record.id }) {
            state.extensions[i] = record
        } else {
            state.extensions.append(record)
        }
    }

    private func persist() throws { try store.save(state) }

    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        return ns.localizedFailureReason.map { "\(ns.localizedDescription) \($0)" } ?? ns.localizedDescription
    }

    @objc private func contextErrorsChanged(_ note: Notification) {
        guard let ctx = note.object as? WKWebExtensionContext, id(of: ctx) != nil else { return }
        onChange?()
    }

    /// WebKit changed grants (runtime prompt answered, expiry, revoke): mirror into state.json.
    @objc private func contextPermissionsChanged(_ note: Notification) {
        guard let ctx = note.object as? WKWebExtensionContext, let id = id(of: ctx), var record = record(for: id) else { return }
        record.grantedPermissions = ctx.grantedPermissions.keys.map(\.rawValue).sorted()
        record.grantedMatchPatterns = ctx.grantedPermissionMatchPatterns.keys.map(\.string).sorted()
        record.deniedMatchPatterns = ctx.deniedPermissionMatchPatterns.keys.map(\.string).sorted()
        record.hasRequestedOptionalAccessToAllHosts = ctx.hasRequestedOptionalAccessToAllHosts
        guard record != self.record(for: id) else { return }
        upsert(record)
        try? persist()
        onChange?()
    }
}

// MARK: - WKWebExtensionControllerDelegate

extension ExtensionHost: WKWebExtensionControllerDelegate {
    public func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        let windows = openWindows()
        return extensionContext.hasAccessToPrivateData ? windows : windows.filter { !($0.isPrivate?(for: extensionContext) ?? false) }
    }

    public func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        let window = focusedWindow?() ?? openWindows().first
        if let window, !extensionContext.hasAccessToPrivateData, window.isPrivate?(for: extensionContext) == true { return nil }
        return window
    }

    public func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        guard let openTab, let id = id(of: extensionContext) else { throw ExtensionHostError.notSupported }
        let windows = openWindows()
        let request = ExtensionTabRequest(
            extensionID: id, url: configuration.url, window: configuration.window,
            windowIndex: configuration.window.flatMap { w in windows.firstIndex { $0 === w } },
            index: configuration.index, active: configuration.shouldBeActive,
            pinned: configuration.shouldBePinned, muted: configuration.shouldBeMuted, parent: configuration.parentTab)
        return openTab(request)
    }

    public func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        guard let openWindow, let id = id(of: extensionContext) else { throw ExtensionHostError.notSupported }
        if configuration.shouldBePrivate, !extensionContext.hasAccessToPrivateData { throw ExtensionHostError.notSupported }
        return openWindow(ExtensionWindowRequest(
            extensionID: id, urls: configuration.tabURLs, tabs: configuration.tabs, frame: configuration.frame,
            focused: configuration.shouldBeFocused, isPrivate: configuration.shouldBePrivate, type: configuration.windowType))
    }

    public func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext) async throws {
        guard let id = id(of: extensionContext), let url = extensionContext.optionsPageURL else { throw ExtensionHostError.notSupported }
        if let openOptionsPage {
            openOptionsPage(url, extensionContext.webViewConfiguration, id)
            return
        }
        guard let openTab else { throw ExtensionHostError.notSupported }
        let request = ExtensionTabRequest(extensionID: id, url: url, window: nil, windowIndex: nil, index: 0, active: true,
                                          pinned: false, muted: false, parent: nil)
        guard openTab(request) != nil else { throw ExtensionHostError.notSupported }
    }

    public func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        let answer = await prompt(extensionContext, tab: tab, permissions: permissions.map(\.rawValue))
        return (Set(answer.permissions.map(WKWebExtension.Permission.init(rawValue:))).intersection(permissions), nil)
    }

    public func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        let answer = await prompt(extensionContext, tab: tab, urls: Array(urls))
        return (answer.urls.intersection(urls), nil)
    }

    public func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        let answer = await prompt(extensionContext, tab: tab, patterns: matchPatterns.map(\.string))
        return (matchPatterns.filter { answer.matchPatterns.contains($0.string) }, nil)
    }

    public func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        guard let id = id(of: context) else { return }
        actionDidUpdate?(action, id)
    }

    public func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext) async throws {
        guard let presentActionPopup, let id = id(of: context) else { throw ExtensionHostError.notSupported }
        presentActionPopup(action, id)
    }

    private func prompt(_ ctx: WKWebExtensionContext, tab: (any WKWebExtensionTab)?, permissions: [String] = [],
                        patterns: [String] = [], urls: [URL] = []) async -> ExtensionPermissionPrompt.Answer {
        guard let promptForPermissions, let id = id(of: ctx) else { return .deny }
        let request = ExtensionPermissionPrompt(extensionID: id, name: record(for: id)?.name ?? id, permissions: permissions.sorted(),
                                                matchPatterns: patterns.sorted(), urls: urls, tab: tab)
        return await promptForPermissions(request)
    }
}
