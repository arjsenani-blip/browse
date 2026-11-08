import AppKit
import WebKit

/// Glue between `WebTab` and the extension runtime, using only WebTab's
/// public surface, so the lead's edits to WebTab stay a few lines.
extension ExtensionHost {
    /// The one adapter for `tab` (created on first call). The app supplies only
    /// what WebTab can't know: selection, window, activation, closing.
    public func adapter(for tab: WebTab,
                        isSelected: @escaping () -> Bool,
                        window: @escaping () -> (any WKWebExtensionWindow)?,
                        activate: @escaping () -> Void,
                        close: @escaping () -> Void) -> ExtensionTabAdapter {
        tabAdapter(for: tab) {
            let a = ExtensionTabAdapter(
                webView: { [weak tab] in tab?.webView },
                title: { [weak tab] in tab?.title },
                url: { [weak tab] in tab?.url },
                isSelected: isSelected, window: window, activate: activate, close: close)
            a.goBack = { [weak tab] in tab?.goBack() }
            a.goForward = { [weak tab] in tab?.goForward() }
            a.reload = { [weak tab] _ in tab?.reload() }
            a.load = { [weak tab] url in tab?.load(url) }
            a.isLoadingComplete = { [weak tab] in !(tab?.isLoading ?? false) }
            a.isPlayingAudio = { [weak tab] in tab?.activity.contains(.playingMedia) ?? false }
            a.isReaderModeAvailable = { [weak tab] in tab?.isReaderable ?? false }
            a.isPrivate = { [weak tab] in !(tab?.context.dataStore.isPersistent ?? true) }
            return a
        }
    }

    /// Call from `WebTabDelegate.webTabDidChange`. Diffs title/URL/loading and
    /// only notifies extensions when one of them actually changed (progress
    /// ticks are ignored).
    public func webTabDidChange(_ tab: WebTab) {
        guard let adapter = existingTabAdapter(for: tab) else { return }
        let now = TabSnapshot(title: tab.title, url: tab.url, loading: tab.isLoading, audio: tab.activity.contains(.playingMedia))
        let key = ObjectIdentifier(tab)
        let before = tabSnapshots[key]
        tabSnapshots[key] = now
        guard let before else { return }
        var changed: WKWebExtension.TabChangedProperties = []
        if before.title != now.title { changed.insert(.title) }
        if before.url != now.url { changed.insert(.URL) }
        if before.loading != now.loading { changed.insert(.loading) }
        if before.audio != now.audio { changed.insert(.playingAudio) }
        if !changed.isEmpty { didChangeProperties(changed, tab: adapter) }
    }

    /// Call when a WebTab is closed for good.
    public func webTabDidClose(_ tab: WebTab, windowIsClosing: Bool = false) {
        tabSnapshots[ObjectIdentifier(tab)] = nil
        guard let adapter = existingTabAdapter(for: tab) else { return }
        didClose(tab: adapter, windowIsClosing: windowIsClosing, owner: tab)
    }
}

struct TabSnapshot: Equatable {
    var title: String
    var url: URL?
    var loading: Bool
    var audio: Bool
}
