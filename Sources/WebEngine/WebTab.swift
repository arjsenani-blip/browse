import AppKit
import WebKit
import BrowserCore

@MainActor
public protocol WebTabDelegate: AnyObject {
    func webTabDidChange(_ tab: WebTab)
    func webTab(_ tab: WebTab, didCommit url: URL, title: String?, typed: Bool)
    /// `configuration` is WebKit's own for window.open/target=_blank: the returned view MUST be built
    /// from it, or WebKit raises an exception. It's nil for ⌘-click, where nothing should be returned.
    func webTab(_ tab: WebTab, openInNewTab request: URLRequest, background: Bool, configuration: WKWebViewConfiguration?) -> WKWebView?
    func webTabDidRequestClose(_ tab: WebTab)
    func webTab(_ tab: WebTab, autofillMessage body: [String: Any])
    /// The page finished loading (title is final). History is recorded on commit, not here.
    func webTabDidFinish(_ tab: WebTab, url: URL, title: String?)
    /// The tab's web content process died (crash or killed under memory pressure).
    func webTabProcessDidTerminate(_ tab: WebTab)
}

/// The live half of a tab: a WKWebView that can be put to sleep and woken.
/// The record half (URL, title, interaction state) lives in BrowserStore.
@MainActor
public final class WebTab: NSObject {
    public let id: TabID
    public let context: ProfileContext
    public private(set) var webView: WKWebView?
    public weak var delegate: WebTabDelegate?

    public private(set) var url: URL?
    public private(set) var title = ""
    public private(set) var progress: Double = 0
    public private(set) var isLoading = false
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    public private(set) var isSecure = false
    public private(set) var isReaderable = false
    public private(set) var activity: TabActivity = []
    public enum MediaState: Sendable { case none, playing, paused }
    public private(set) var mediaState: MediaState = .none
    public private(set) var hasVideo = false
    /// From the page's Media Session metadata, when it sets any.
    public private(set) var mediaTitle: String?
    public private(set) var mediaArtist: String?
    public private(set) var mediaArtwork: URL?

    public func togglePlayback() {
        webView?.evaluateJavaScript(MediaScript.togglePlayback, in: nil, in: Worlds.media)
    }

    public func togglePictureInPicture() {
        webView?.evaluateJavaScript(MediaScript.pictureInPicture, in: nil, in: Worlds.media)
    }

    /// Snapshot shown while a sleeping tab wakes.
    public private(set) var snapshot: NSImage?

    private var observations: [NSKeyValueObservation] = []
    private var dialogTimes: [Date] = []
    private var dialogsSuppressed = false
    private var pendingTyped = false

    public init(id: TabID, context: ProfileContext) {
        self.id = id
        self.context = context
    }

    public var isAwake: Bool { webView != nil }

    /// Creates the web view, restoring history if we have it. `existing` adopts
    /// a view WebKit created for a window.open/target=_blank request.
    @discardableResult
    public func wake(url: URL?, interactionState: Data?, existing: WKWebView? = nil) -> WKWebView {
        if let webView { return webView }
        let view = existing ?? WKWebView(frame: .zero, configuration: context.makeConfiguration())
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        #if DEBUG
        view.isInspectable = true
        #endif
        context.register(self, for: view)
        webView = view
        observe(view)
        if existing == nil {
            if let interactionState {
                view.interactionState = interactionState as NSData
            } else if let url {
                view.load(URLRequest(url: url))
            }
        }
        return view
    }

    /// Tears down the web view so its WebContent process can exit.
    /// Returns the interaction state to persist.
    @discardableResult
    public func sleep() async -> Data? {
        guard let view = webView else { return nil }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        snapshot = try? await view.takeSnapshot(configuration: config)
        let state = view.interactionState as? Data
        observations.removeAll()
        context.unregister(view)
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
        webView = nil
        activity = []
        isLoading = false
        mediaState = .none
        delegate?.webTabDidChange(self)
        return state
    }

    /// Closing for good: tear down now (no snapshot, no state, no change
    /// callbacks), so a closed tab's audio stops at once and nothing reports
    /// on a tab the store and extensions have already forgotten.
    public func close() {
        delegate = nil
        snapshot = nil
        guard let view = webView else { return }
        observations.removeAll()
        context.unregister(view)
        view.stopLoading()
        view.pauseAllMediaPlayback(completionHandler: nil)
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
        webView = nil
    }

    public var interactionState: Data? { webView?.interactionState as? Data }

    public func load(_ url: URL, typed: Bool = false) {
        pendingTyped = typed
        let target = context.settings.stripTrackingParameters ? (context.policy?.strippedURL(url) ?? url) : url
        (webView ?? wake(url: nil, interactionState: nil)).load(URLRequest(url: target))
    }

    public func goBack() { webView?.goBack() }
    public func goForward() { webView?.goForward() }
    public func reload() { webView?.reload() }
    public func stop() { webView?.stopLoading() }

    /// Runs the reader extraction in the isolated reader world.
    public func extractArticle() async -> ReaderArticle? {
        guard let view = webView else { return nil }
        let loaded = (try? await view.evaluateJavaScript("typeof Readability === 'function'", in: nil, contentWorld: Worlds.reader)) as? Bool ?? false
        if !loaded {
            _ = try? await view.evaluateJavaScript(Bundled.readability + "\n" + Bundled.purify + "\n;true", in: nil, contentWorld: Worlds.reader)
        }
        let result = try? await view.evaluateJavaScript(ReaderScript.extract, in: nil, contentWorld: Worlds.reader)
        guard let dict = result as? [String: Any], let content = dict["content"] as? String else { return nil }
        return ReaderArticle(title: dict["title"] as? String ?? title, byline: dict["byline"] as? String ?? "", site: dict["site"] as? String ?? "", html: content, url: url)
    }

    public func fillCredentials(username: String, password: String) {
        guard let view = webView,
              let u = try? JSONEncoder().encode(username), let p = try? JSONEncoder().encode(password),
              let us = String(data: u, encoding: .utf8), let ps = String(data: p, encoding: .utf8) else { return }
        view.evaluateJavaScript("window.__aegisFill && window.__aegisFill(\(us), \(ps));", in: nil, in: Worlds.autofill)
    }

    // MARK: Observation

    private func observe(_ view: WKWebView) {
        observations = [
            view.observe(\.title) { [weak self] v, _ in MainActor.assumeIsolated { self?.title = v.title ?? ""; self?.changed() } },
            view.observe(\.url) { [weak self] v, _ in MainActor.assumeIsolated { self?.url = v.url; self?.changed() } },
            view.observe(\.estimatedProgress) { [weak self] v, _ in MainActor.assumeIsolated { self?.progress = v.estimatedProgress; self?.changed() } },
            view.observe(\.isLoading) { [weak self] v, _ in MainActor.assumeIsolated { self?.isLoading = v.isLoading; self?.changed() } },
            view.observe(\.canGoBack) { [weak self] v, _ in MainActor.assumeIsolated { self?.canGoBack = v.canGoBack; self?.changed() } },
            view.observe(\.canGoForward) { [weak self] v, _ in MainActor.assumeIsolated { self?.canGoForward = v.canGoForward; self?.changed() } },
            view.observe(\.hasOnlySecureContent) { [weak self] v, _ in MainActor.assumeIsolated { self?.isSecure = v.hasOnlySecureContent; self?.changed() } },
            view.observe(\.cameraCaptureState) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshActivity() } },
            view.observe(\.microphoneCaptureState) { [weak self] _, _ in MainActor.assumeIsolated { self?.refreshActivity() } },
        ]
        url = view.url
        title = view.title ?? ""
    }

    private func refreshActivity() {
        guard let view = webView else { return }
        var a = activity.subtracting(.capturing)
        if view.cameraCaptureState != .none || view.microphoneCaptureState != .none { a.insert(.capturing) }
        activity = a
        changed()
    }

    /// Asks WebKit whether media is playing; called before hibernation decisions.
    public func refreshMediaState() async {
        guard let view = webView else { return }
        let state = await view.requestMediaPlaybackState()
        if state == .playing { activity.insert(.playingMedia) } else { activity.remove(.playingMedia) }
    }

    func setFormDirty(_ dirty: Bool) {
        if dirty { activity.insert(.unsavedForm) } else { activity.remove(.unsavedForm) }
    }

    private func changed() { delegate?.webTabDidChange(self) }

    private func probeReader() {
        guard let view = webView else { return }
        view.evaluateJavaScript(ReaderScript.probe, in: nil, in: Worlds.reader) { [weak self] result in
            MainActor.assumeIsolated {
                if case .success(let value) = result { self?.isReaderable = (value as? Bool) ?? false }
                self?.changed()
            }
        }
    }

    private func injectCosmetics(host: String) {
        guard context.settings.blockContent, let source = context.policy?.cosmeticScript(forHost: host) else { return }
        webView?.evaluateJavaScript(source, in: nil, in: Worlds.cosmetic)
    }
}

public struct ReaderArticle: Sendable {
    public let title: String
    public let byline: String
    public let site: String
    public let html: String
    public let url: URL?
}

// MARK: - Navigation

extension WebTab: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let modifiers = action.modifierFlags
        // ⌘-click or middle-click: open in a new tab (background unless ⇧).
        if action.navigationType == .linkActivated, modifiers.contains(.command) || action.buttonNumber == 2 {
            _ = delegate?.webTab(self, openInNewTab: action.request, background: !modifiers.contains(.shift), configuration: nil)
            return (.cancel, preferences)
        }
        // Strip tracking parameters from top-level GET link/other navigations only:
        // re-issuing a form POST, reload or back/forward would lose its body or state.
        let strippable = action.request.httpMethod?.uppercased() ?? "GET" == "GET"
            && (action.navigationType == .linkActivated || action.navigationType == .other)
        if strippable, action.targetFrame?.isMainFrame == true, context.settings.stripTrackingParameters,
           let url = action.request.url, let clean = context.policy?.strippedURL(url) {
            webView.load(URLRequest(url: clean))
            return (.cancel, preferences)
        }
        if action.shouldPerformDownload { return (.download, preferences) }
        // Site quirks: a different user agent for the few sites that need one.
        if action.targetFrame?.isMainFrame == true {
            let wanted = SiteQuirks.userAgent(for: action.request.url?.host())
            if webView.customUserAgent != (wanted ?? "") { webView.customUserAgent = wanted }
        }
        return (.allow, preferences)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let attachment = (response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") ?? false
        // No drive-by downloads: subframes (e.g. hidden cross-origin iframes) may
        // never start a download; only the page itself can.
        if !response.isForMainFrame && (attachment || !response.canShowMIMEType) { return .cancel }
        if attachment { return .download }
        return response.canShowMIMEType ? .allow : .download
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isReaderable = false
        dialogsSuppressed = false
        dialogTimes = []
        changed()
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let host = webView.url?.host() { injectCosmetics(host: host) }
        if let url = webView.url { delegate?.webTab(self, didCommit: url, title: webView.title, typed: pendingTyped) }
        pendingTyped = false
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url { delegate?.webTabDidFinish(self, url: url, title: webView.title) }
        probeReader()
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The app decides: background tabs sleep (reload when shown), the
        // visible tab reloads with a retry cap. Never an unconditional loop.
        delegate?.webTabProcessDidTerminate(self)
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadCenter.shared.track(download, ephemeral: !context.dataStore.isPersistent)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadCenter.shared.track(download, ephemeral: !context.dataStore.isPersistent)
    }
}

// MARK: - UI

extension WebTab: WKUIDelegate {
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        delegate?.webTab(self, openInNewTab: action.request, background: false, configuration: configuration)
    }

    public func webViewDidClose(_ webView: WKWebView) {
        delegate?.webTabDidRequestClose(self)
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        _ = await presentDialog(webView, title: frame.securityOrigin.host, message: message, buttons: ["OK"])
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await presentDialog(webView, title: frame.securityOrigin.host, message: message, buttons: ["OK", "Cancel"]) == .alertFirstButtonReturn
    }

    /// Page dialogs are sheets on the tab's own window, never app-modal: a
    /// background tab (no window) can't interrupt, and a page that loops
    /// dialogs can be silenced.
    private func presentDialog(_ webView: WKWebView, title: String, message: String, buttons: [String]) async -> NSApplication.ModalResponse {
        guard !dialogsSuppressed, let window = webView.window, window.attachedSheet == nil else { return .alertSecondButtonReturn }
        let alert = NSAlert()
        alert.messageText = title.isEmpty ? "This page says" : "\(title) says"
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        let now = Date()
        dialogTimes = dialogTimes.filter { now.timeIntervalSince($0) < 15 } + [now]
        if dialogTimes.count > 2 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't show more dialogs from this page"
        }
        let response = await alert.beginSheetModal(for: window)
        if alert.suppressionButton?.state == .on { dialogsSuppressed = true }
        return response
    }

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        // A sheet on the tab's window, like page dialogs: an app-modal panel
        // would freeze every other window. Background tabs get nothing.
        guard let window = webView.window, window.attachedSheet == nil else { return nil }
        return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
    }
}

extension WebTab {
    func receiveScriptMessage(_ body: [String: Any]) {
        if body["type"] as? String == "media" {
            let state = body["state"] as? String
            if state == "playing" { activity.insert(.playingMedia) } else { activity.remove(.playingMedia) }
            mediaState = state == "playing" ? .playing : state == "paused" ? .paused : .none
            hasVideo = (body["kind"] as? String) == "video"
            if let t = body["title"] as? String, !t.isEmpty { mediaTitle = t }
            if let a = body["artist"] as? String { mediaArtist = a }
            if let art = body["art"] as? String, let u = URL(string: art), u.scheme == "https" { mediaArtwork = u }
            delegate?.webTabDidChange(self)
            return
        }
        if body["type"] as? String == "formDirty" { setFormDirty(body["dirty"] as? Bool ?? false) }
        delegate?.webTab(self, autofillMessage: body)
    }
}
