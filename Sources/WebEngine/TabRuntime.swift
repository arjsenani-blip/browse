import AppKit
import WebKit
import Network
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
    /// The encrypted-DNS proxy every profile routes through (nil = direct).
    public var proxyConfiguration: ProxyConfiguration?
    public weak var extensionHost: ExtensionHost?
    /// Called once when a WebTab object is created (for extension bookkeeping).
    public var onTabCreated: ((WebTab) -> Void)?

    private var pressureSource: DispatchSourceMemoryPressure?
    private var timer: Timer?
    private let log = Logger(subsystem: "app.aegis", category: "hibernation")

    public init(store: BrowserStore) {
        self.store = store
    }

    public func context(for profile: Profile) -> ProfileContext {
        if let c = contexts[profile.id] { return c }
        let c = ProfileContext(profile: profile, ephemeral: ephemeralProfiles.contains(profile.id), policy: policy, settings: settings, proxy: proxyConfiguration)
        c.extensionHost = extensionHost
        contexts[profile.id] = c
        return c
    }

    /// Forgets a profile entirely: closes its live tabs, drops its context and
    /// deletes its website data store from disk (cookies, storage, cache, HSTS).
    public func removeProfile(_ id: UUID) async {
        for (tid, t) in tabs where t.context.profile.id == id {
            _ = await t.sleep()
            tabs[tid] = nil
        }
        let context = contexts.removeValue(forKey: id)
        ephemeralProfiles.remove(id)
        if let context, context.dataStore.isPersistent {
            await context.clearData()
            try? await WKWebsiteDataStore.remove(forIdentifier: id)
        }
    }

    public func reloadRules() { contexts.values.forEach { $0.reloadRules() } }

    /// The live tab if one exists; never creates one (cheap, for drawing).
    public func existingTab(_ id: TabID) -> WebTab? { tabs[id] }

    /// The live tab for an ID, creating (but not waking) it if needed.
    public func tab(_ id: TabID) -> WebTab? {
        if let t = tabs[id] { return t }
        guard let space = store.space(containing: id) else { return nil }
        let t = WebTab(id: id, context: context(for: store.profile(for: space)))
        t.delegate = delegate
        tabs[id] = t
        onTabCreated?(t)
        return t
    }

    /// Wakes a tab for display, restoring its history.
    @discardableResult
    public func show(_ id: TabID) -> WKWebView? {
        guard let record = store.tabs[id], let t = tab(id) else { return nil }
        let view = t.wake(url: record.url, interactionState: record.isSleeping ? record.interactionState : nil)
        // Write only on a real change. Showing happens on every redraw, and a
        // fresh timestamp each time made the store "change", which scheduled the
        // next redraw: a busy loop that pinned a CPU core while idle.
        if record.isSleeping || Date().timeIntervalSince(record.lastActive) > 30 {
            store.update(id) { $0.isSleeping = false; $0.lastActive = Date() }
        }
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
        timer?.tolerance = 15   // let macOS batch this wake-up
    }

    public func runHibernation(now: Date = Date()) async {
        for t in tabs.values where t.isAwake { await t.refreshMediaState() }
        for (id, t) in tabs { store.update(id) { $0.activity = t.activity } }
        let records = tabs.keys.compactMap { store.tabs[$0] }.filter { !$0.isSleeping }
        let victims = hibernation.tabsToSleep(records, foreground: foreground, pressure: pressure, now: now)
        for id in victims { await sleep(id) }
    }
}

/// Tracks downloads into ~/Downloads, never overwriting, and remembers them
/// across launches for the Library.
@MainActor
public final class DownloadCenter: NSObject, WKDownloadDelegate {
    public static let shared = DownloadCenter()
    public struct Item: Identifiable, Codable, Equatable {
        public var id = UUID()
        public var filename: String
        public var destination: URL?
        public var sourceURL: URL?
        public var started = Date()
        public var totalBytes: Int64 = 0
        public var finished = false
        public var failed = false
        public var fractionCompleted: Double = 0
        /// From a private window: listed while open, never written to disk.
        public var ephemeral: Bool?
        public var isMedia: Bool {
            guard let ext = destination?.pathExtension.lowercased() ?? filename.split(separator: ".").last.map({ String($0).lowercased() }) else { return false }
            return ["png", "jpg", "jpeg", "gif", "webp", "heic", "avif", "svg", "mp4", "mov", "m4v", "webm", "mp3", "m4a", "wav", "aac", "flac"].contains(ext)
        }
        public var fileExists: Bool { destination.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    }
    public private(set) var items: [Item] = []
    public var onChange: (() -> Void)?
    private var map: [ObjectIdentifier: UUID] = [:]
    private var progressObservers: [UUID: NSKeyValueObservation] = [:]
    private let file = AppPaths.support.appending(path: "downloads.json")

    override init() {
        super.init()
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Item].self, from: data) {
            // Interrupted downloads from a previous run are failed, not in flight.
            items = saved.map { var i = $0; if !i.finished { i.failed = true }; return i }
        }
    }

    public var active: [Item] { items.filter { !$0.finished && !$0.failed } }

    func track(_ download: WKDownload, ephemeral: Bool = false) {
        download.delegate = self
        var item = Item(filename: download.originalRequest?.url?.lastPathComponent ?? "download")
        item.sourceURL = download.originalRequest?.url
        item.ephemeral = ephemeral ? true : nil
        items.insert(item, at: 0)
        map[ObjectIdentifier(download)] = item.id
        let id = item.id
        progressObservers[id] = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted, total = progress.totalUnitCount
            Task { @MainActor in
                guard let self, let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[i].fractionCompleted = fraction
                if total > 0 { self.items[i].totalBytes = total }
                self.onChange?()
            }
        }
        changed()
    }

    public func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        changed()
    }

    /// Private window closed: drop its downloads from the list.
    public func forgetEphemeral() {
        items.removeAll { $0.ephemeral == true }
        onChange?()
    }

    public func clearFinished() {
        items.removeAll { $0.finished || $0.failed }
        changed()
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
        let expected = response.expectedContentLength
        update(download) { $0.filename = url.lastPathComponent; $0.destination = url; if expected > 0 { $0.totalBytes = expected } }
        return url
    }

    public func downloadDidFinish(_ download: WKDownload) {
        update(download) { $0.finished = true; $0.fractionCompleted = 1 }
        if let id = map[ObjectIdentifier(download)] { progressObservers[id] = nil }
        // Bounce the Downloads stack in the Dock, as Safari does.
        if let url = items.first(where: { $0.id == map[ObjectIdentifier(download)] })?.destination {
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
        }
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        update(download) { $0.failed = true }
    }

    private func update(_ download: WKDownload, _ change: (inout Item) -> Void) {
        guard let id = map[ObjectIdentifier(download)], let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        changed()
    }

    private func changed() {
        if items.count > 500 { items.removeLast(items.count - 500) }
        if let data = try? JSONEncoder().encode(items.filter { $0.ephemeral != true }) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        onChange?()
    }
}
