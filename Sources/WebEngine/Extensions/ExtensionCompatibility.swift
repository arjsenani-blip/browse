import Foundation

/// What WebKit's extension runtime (macOS 15.4+) does and doesn't provide,
/// from the WKWebExtensionPermission constants in the SDK headers plus
/// WebKit's documented API coverage. Used to warn on the consent sheet.
///
/// Namespaces: WebKit exposes the same API objects as both `browser.*`
/// (promise-based) and `chrome.*`, so Chrome-targeted code runs unchanged;
/// verified by `ExtensionHostTests` (a background worker calling
/// `chrome.storage.local.set` persists data).
public enum ExtensionCompatibility {
    /// Permission strings WebKit declares constants for (WKWebExtensionPermission.h).
    public static let supportedPermissions: [String] = [
        "activeTab", "alarms", "clipboardWrite", "contextMenus", "cookies",
        "declarativeNetRequest", "declarativeNetRequestFeedback", "declarativeNetRequestWithHostAccess",
        "menus", "nativeMessaging", "scripting", "storage", "tabs", "unlimitedStorage",
        "webNavigation", "webRequest",
    ]

    /// Chrome permissions that are commonly requested but have no WebKit
    /// implementation, with what the user should expect.
    public static let knownUnsupported: [String: String] = [
        "webRequestBlocking": "Cannot block or modify requests (WebKit only supports declarativeNetRequest)",
        "offscreen": "No offscreen documents",
        "sidePanel": "No side panel",
        "identity": "No Google sign-in (chrome.identity)",
        "downloads": "Cannot manage downloads",
        "history": "Cannot read browsing history",
        "bookmarks": "Cannot read or change bookmarks",
        "notifications": "Cannot show system notifications",
        "tabGroups": "No tab groups",
        "debugger": "No debugger access",
        "proxy": "Cannot change proxy settings",
        "privacy": "Cannot change privacy settings",
        "management": "Cannot manage other extensions",
        "topSites": "No top sites",
        "sessions": "No recently closed sessions",
        "tts": "No text-to-speech",
        "idle": "No idle detection",
        "power": "Cannot keep the system awake",
        "background": "No background app mode",
        "userScripts": "No user scripts API",
        "fontSettings": "No font settings",
        "contentSettings": "No per-site content settings",
        "declarativeContent": "No declarativeContent",
        "gcm": "No push messaging (gcm)",
        "pageCapture": "No MHTML page capture",
        "tabCapture": "No tab capture",
        "desktopCapture": "No screen capture",
        "system.display": "No display info", "system.cpu": "No CPU info", "system.memory": "No memory info",
        "favicon": "No favicon API",
        "readingList": "No reading list",
        "search": "No search API",
    ]

    /// Requested permissions that won't work, with an explanation each.
    public static func unsupported(in manifest: ExtensionManifest) -> [(permission: String, note: String)] {
        let supported = Set(supportedPermissions)
        return (manifest.permissions + manifest.optionalPermissions)
            .filter { !supported.contains($0) }
            .map { ($0, knownUnsupported[$0] ?? "Not supported by WebKit") }
    }
}
