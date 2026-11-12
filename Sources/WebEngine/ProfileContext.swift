import Foundation
import WebKit
import Network
import BrowserCore

/// What the privacy layer supplies to every web view. Implemented in the app
/// by an adapter over ContentBlocking, so WebEngine stays testable alone.
@MainActor
public protocol ContentPolicy: AnyObject {
    var ruleLists: [WKContentRuleList] { get }
    /// CSS-hiding script for a host, injected in the cosmetic world; nil for none.
    func cosmeticScript(forHost host: String) -> String?
    /// Returns a cleaned URL when tracking parameters were removed.
    func strippedURL(_ url: URL) -> URL?
}

public struct PrivacySettings: Sendable, Equatable {
    /// Off by default: a content-blocker extension (uBlock Origin) does this better and runs once, not twice.
    public var blockContent = false
    public var fingerprintProtection = true
    public var httpsOnly = true
    public var stripTrackingParameters = true
    /// True only when the app carries Apple's browser-passkey entitlement;
    /// otherwise pages are told passkeys are unavailable (see PasskeyShim).
    public var passkeysAvailable = false
    public init() {}
}

/// One browsing identity: its own persistent data store, scripts and rules.
/// Every tab in a space that uses this profile shares this configuration.
@MainActor
public final class ProfileContext {
    public let profile: Profile
    public let dataStore: WKWebsiteDataStore
    let userContent = WKUserContentController()
    private let sessionSeed = UInt32.random(in: 1...UInt32.max)
    weak var policy: ContentPolicy?
    var settings: PrivacySettings
    private var live: [ObjectIdentifier: WeakTab] = [:]
    /// Attaches the extension controller to every web view in this profile.
    weak var extensionHost: ExtensionHost?

    public init(profile: Profile, ephemeral: Bool = false, policy: ContentPolicy?, settings: PrivacySettings, proxy: ProxyConfiguration? = nil) {
        self.profile = profile
        self.policy = policy
        self.settings = settings
        dataStore = ephemeral ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: profile.id)
        // Encrypted DNS: all of this profile's traffic goes through the local
        // DoH proxy. Must be set before the store's first load.
        if let proxy { dataStore.proxyConfigurations = [proxy] }
        installScripts()
        reloadRules()
        userContent.add(ScriptRelay(self), contentWorld: Worlds.autofill, name: "aegisAutofill")
        userContent.add(ScriptRelay(self), contentWorld: Worlds.media, name: "aegisMedia")
        userContent.add(ScriptRelay(self), contentWorld: .page, name: "aegisPasskey")
    }

    func register(_ tab: WebTab, for view: WKWebView) { live[ObjectIdentifier(view)] = WeakTab(tab: tab) }
    func unregister(_ view: WKWebView) { live[ObjectIdentifier(view)] = nil }
    fileprivate func route(_ body: [String: Any], from view: WKWebView?) {
        guard let view, let tab = live[ObjectIdentifier(view)]?.tab else { return }
        tab.receiveScriptMessage(body)
    }

    /// A configuration for a new web view in this profile.
    func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.userContentController = userContent
        config.mediaTypesRequiringUserActionForPlayback = .audio
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        config.preferences.isElementFullscreenEnabled = true
        // Popup blocker: window.open only from a user gesture.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences.preferredHTTPSNavigationPolicy = settings.httpsOnly ? .userMediatedFallbackToHTTP : .keepAsRequested
        config.upgradeKnownHostsToHTTPS = true
        config.applicationNameForUserAgent = "Version/27.0 Safari/605.1.15"
        extensionHost?.configure(config)
        return config
    }

    public func reloadRules() {
        userContent.removeAllContentRuleLists()
        guard settings.blockContent, let policy else { return }
        for list in policy.ruleLists { userContent.add(list) }
    }

    public func apply(_ settings: PrivacySettings) {
        self.settings = settings
        userContent.removeAllUserScripts()
        installScripts()
        reloadRules()
    }

    private func installScripts() {
        if !settings.passkeysAvailable {
            userContent.addUserScript(WKUserScript(source: PasskeyShim.source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        if settings.fingerprintProtection {
            userContent.addUserScript(WKUserScript(source: Farbling.source(seed: sessionSeed), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        // Only the 4 KB readerable check runs on every page; Readability and DOMPurify (~110 KB)
        // are injected when Reader actually opens. Both live in the isolated reader world.
        userContent.addUserScript(WKUserScript(source: Bundled.readerable, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Worlds.reader))
        userContent.addUserScript(WKUserScript(source: MediaScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Worlds.media))
        if !Bundled.autofill.isEmpty {
            userContent.addUserScript(WKUserScript(source: Bundled.autofill, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Worlds.autofill))
        }
    }

    /// Deletes everything this profile stored (cookies, storage, cache, HSTS).
    public func clearData() async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await dataStore.removeData(ofTypes: types, modifiedSince: .distantPast)
    }
}

private struct WeakTab { weak var tab: WebTab? }

/// One message handler per profile, routing by sending web view. Holds the
/// context weakly so the content controller doesn't retain it.
private final class ScriptRelay: NSObject, WKScriptMessageHandler {
    weak var context: ProfileContext?
    init(_ context: ProfileContext) { self.context = context }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any] else { return }
            context?.route(body, from: message.webView)
        }
    }
}
