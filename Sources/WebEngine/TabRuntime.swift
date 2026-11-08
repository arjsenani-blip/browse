import AppKit
import WebKit
import BrowserCore
import os

/// Owns every live WebTab, one ProfileContext per profile, and runs hibernation.
@MainActor
public final class TabRuntime {
    private let store: BrowserStore
    private var contexts: [UUID: ProfileContext] = [:]
    private var tabs: [TabID: WebTab] = [:]
    public weak var policy: ContentPolicy?
    public var settings = PrivacySettings() {
        didSet { contexts.values.forEach { $0.apply(settings) } }
    }
    public var hibernation = HibernationPolicy.balanced
    public private(set) var pressure: MemoryPressure = .normal
    /// Tabs on screen right now; set by window controllers.
    public var foreground: Set<TabID> = []
    public weak var delegate: WebTabDelegate?
    /// Profiles whose data must never touch disk (private windows).
    public var ephemeralProfiles: Set<UUID> = []

    private var pressureSource: DispatchSourceMemoryPressure?
    private var timer: Timer?
    private let log = Logger(subsystem: "app.aegis", category: "hibernation")

    public init(store: BrowserStore) {
        self.store = store
    }

    public func context(for profile: Profile) -> ProfileContext {
        if let c = contexts[profile.id] { return c }
        let c = ProfileContext(profile: profile, ephemeral: ephemeralProfiles.contains(profile.id), policy: policy, settings: settings)
        contexts[profile.id] = c
        return c
    }

    public func reloadRules() { contexts.values.forEach { $0.reloadRules() } }

    /// The live tab for an ID, creating (but not waking) it if needed.
    public func tab(_ id: TabID) -> WebTab? {
        if let t = tabs[id] { return t }
        guard let space = store.space(containing: id) else { return nil }
        let t = WebTab(id: id, context: context(for: store.profile(for: space)))
        t.delegate = delegate
        tabs[id] = t
        return t
    }

    /// Wakes a tab for display, restoring its history.
    @discardableResult
    public func show(_ id: TabID) -> WKWebView? {
        guard let record = store.tabs[id], let t = tab(id) else { return nil }
        let view = t.wake(url: record.url, interactionState: record.isSleeping ? record.interactionState : nil)
        store.update(id) { $0.isSleeping = false; $0.lastActive = Date() }
        return view
    }

    /// Adopts a web view WebKit created for window.open into a new tab.
    public func adopt(_ id: TabID, configuration: WKWebViewConfiguration) -> WKWebView? {
        guard let t = tab(id) else { return nil }
        let view = WKWebView(frame: .zero, configuration: configuration)
        t.wake(url: nil, interactionState: nil, existing: view)
        store.update(id) { $0.isSleeping = false }
        return view
    }

    public func discard(_ id: TabID) {
        if let t = tabs.removeValue(forKey: id) { Task { await t.sleep() } }
    }

    public func sleep(_ id: TabID) async {
        guard let t = tabs[id], t.isAwake else { return }
        let state = await t.sleep()
        store.update(id) { $0.isSleeping = true; if let state { $0.interactionState = state } }
        log.info("slept tab \(id, privacy: .public)")
    }

    /// Captures interaction state of live tabs into the store before saving.
    public func captureStates() {
        for (id, t) in tabs where t.isAwake {
            if let state = t.interactionState { store.update(id) { $0.interactionState = state } }
        }
    }

    public var liveCount: Int { tabs.values.filter(\.isAwake).count }

    // MARK: Hibernation loop

    public func startHibernation() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self, let event = source?.data else { return }
                self.pressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
                self.log.info("memory pressure \(self.pressure.rawValue)")
                Task { await self.runHibernation() }
            }
        }
        source.activate()
        pressureSource = source
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.runHibernation() } }
        }
    }

    public func runHibernation(now: Date = Date()) async {
        for t in tabs.values where t.isAwake { await t.refreshMediaState() }
        for (id, t) in tabs { store.update(id) { $0.activity = t.activity } }
        let records = tabs.keys.compactMap { store.tabs[$0] }.filter { !$0.isSleeping }
        let victims = hibernation.tabsToSleep(records, foreground: foreground, pressure: pressure, now: now)
        for id in victims { await sleep(id) }
    }
}

/// Tracks downloads into ~/Downloads, never overwriting.
@MainActor
public final class DownloadCenter: NSObject, WKDownloadDelegate {
    public static let shared = DownloadCenter()
    public struct Item: Identifiable {
        public let id = UUID()
        public var filename: String
        public var destination: URL?
        public var progress: Progress?
        public var finished = false
        public var failed = false
    }
    public private(set) var items: [Item] = []
    public var onChange: (() -> Void)?
    private var map: [ObjectIdentifier: UUID] = [:]

    func track(_ download: WKDownload) {
        download.delegate = self
        let item = Item(filename: download.originalRequest?.url?.lastPathComponent ?? "download", progress: download.progress)
        items.append(item)
        map[ObjectIdentifier(download)] = item.id
        onChange?()
    }

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var url = folder.appending(path: suggestedFilename)
        var n = 1
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = folder.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        }
        update(download) { $0.filename = url.lastPathComponent; $0.destination = url }
        return url
    }

    public func downloadDidFinish(_ download: WKDownload) {
        update(download) { $0.finished = true }
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        update(download) { $0.failed = true }
    }

    private func update(_ download: WKDownload, _ change: (inout Item) -> Void) {
        guard let id = map[ObjectIdentifier(download)], let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        onChange?()
    }
}
