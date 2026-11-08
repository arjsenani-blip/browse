import AppKit
import WebKit

public enum ExtensionBridgeError: Error, Sendable {
    case notSupported
    case noWebView
}

/// A `WKWebExtensionTab` made of closures, so the app's tab type doesn't have
/// to adopt the protocol itself. WebKit tracks tabs by object identity: keep
/// exactly one adapter per tab for its whole life (see
/// `ExtensionHost.tabAdapter(for:make:)`).
///
/// Anything left nil falls back to acting on `webView()` or reports
/// "not supported" to the extension.
@MainActor
public final class ExtensionTabAdapter: NSObject, WKWebExtensionTab {
    public var webView: () -> WKWebView?
    public var title: () -> String?
    public var url: () -> URL?
    public var isSelected: () -> Bool
    public var window: () -> (any WKWebExtensionWindow)?
    public var activate: () -> Void
    public var close: () -> Void
    public var reload: ((_ fromOrigin: Bool) -> Void)?
    public var goBack: (() -> Void)?
    public var goForward: (() -> Void)?
    public var load: ((URL) -> Void)?
    public var isLoadingComplete: (() -> Bool)?
    public var indexInWindow: (() -> Int?)?
    public var parent: (() -> (any WKWebExtensionTab)?)?
    public var isPinned: () -> Bool = { false }
    public var setPinned: ((Bool) -> Void)?
    public var isMuted: () -> Bool = { false }
    public var setMuted: ((Bool) -> Void)?
    public var isPlayingAudio: () -> Bool = { false }
    public var isPrivate: () -> Bool = { false }
    public var isReaderModeAvailable: () -> Bool = { false }
    public var isReaderModeActive: () -> Bool = { false }
    public var setReaderModeActive: ((Bool) -> Void)?
    public var duplicate: (() -> (any WKWebExtensionTab)?)?

    public init(
        webView: @escaping () -> WKWebView?,
        title: @escaping () -> String? = { nil },
        url: @escaping () -> URL? = { nil },
        isSelected: @escaping () -> Bool,
        window: @escaping () -> (any WKWebExtensionWindow)?,
        activate: @escaping () -> Void,
        close: @escaping () -> Void
    ) {
        self.webView = webView
        self.title = title
        self.url = url
        self.isSelected = isSelected
        self.window = window
        self.activate = activate
        self.close = close
    }

    // MARK: WKWebExtensionTab

    public func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { window() }

    public func indexInWindow(for context: WKWebExtensionContext) -> Int {
        if let i = indexInWindow?() { return i }
        guard let tabs = window()?.tabs?(for: context) else { return NSNotFound }
        return tabs.firstIndex { $0 === self } ?? NSNotFound
    }

    public func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { parent?() }

    public func webView(for context: WKWebExtensionContext) -> WKWebView? { webView() }

    public func title(for context: WKWebExtensionContext) -> String? { title() ?? webView()?.title }

    public func url(for context: WKWebExtensionContext) -> URL? { url() ?? webView()?.url }

    public func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        isLoadingComplete?() ?? !(webView()?.isLoading ?? false)
    }

    public func isSelected(for context: WKWebExtensionContext) -> Bool { isSelected() }

    public func isPinned(for context: WKWebExtensionContext) -> Bool { isPinned() }

    public func isMuted(for context: WKWebExtensionContext) -> Bool { isMuted() }

    public func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { isPlayingAudio() }

    public func isReaderModeAvailable(for context: WKWebExtensionContext) -> Bool { isReaderModeAvailable() }

    public func isReaderModeActive(for context: WKWebExtensionContext) -> Bool { isReaderModeActive() }

    public func size(for context: WKWebExtensionContext) -> CGSize { webView()?.frame.size ?? .zero }

    public func activate(for context: WKWebExtensionContext) async throws { activate() }

    public func close(for context: WKWebExtensionContext) async throws { close() }

    public func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws {
        if let reload { reload(fromOrigin); return }
        guard let view = webView() else { throw ExtensionBridgeError.noWebView }
        if fromOrigin { view.reloadFromOrigin() } else { view.reload() }
    }

    public func goBack(for context: WKWebExtensionContext) async throws {
        if let goBack { goBack(); return }
        guard let view = webView() else { throw ExtensionBridgeError.noWebView }
        view.goBack()
    }

    public func goForward(for context: WKWebExtensionContext) async throws {
        if let goForward { goForward(); return }
        guard let view = webView() else { throw ExtensionBridgeError.noWebView }
        view.goForward()
    }

    public func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        if let load { load(url); return }
        guard let view = webView() else { throw ExtensionBridgeError.noWebView }
        view.load(URLRequest(url: url))
    }

    public func setPinned(_ pinned: Bool, for context: WKWebExtensionContext) async throws {
        guard let setPinned else { throw ExtensionBridgeError.notSupported }
        setPinned(pinned)
    }

    public func setMuted(_ muted: Bool, for context: WKWebExtensionContext) async throws {
        guard let setMuted else { throw ExtensionBridgeError.notSupported }
        setMuted(muted)
    }

    public func setReaderModeActive(_ active: Bool, for context: WKWebExtensionContext) async throws {
        guard let setReaderModeActive else { throw ExtensionBridgeError.notSupported }
        setReaderModeActive(active)
    }

    public func duplicate(using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        guard let duplicate else { throw ExtensionBridgeError.notSupported }
        return duplicate()
    }

    /// Private tabs should not get `activeTab` grants unless the extension may see private data.
    public func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        !isPrivate() || context.hasAccessToPrivateData
    }
}

/// A `WKWebExtensionWindow` made of closures. One adapter per window, kept for its life.
@MainActor
public final class ExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    public var tabs: () -> [any WKWebExtensionTab]
    public var activeTab: () -> (any WKWebExtensionTab)?
    public var frame: () -> CGRect
    public var focus: () -> Void
    /// Read once by WebKit and cached for the window's life.
    public var isPrivate: () -> Bool
    public var screenFrame: () -> CGRect = { NSScreen.main?.frame ?? .null }
    public var windowState: () -> WKWebExtension.WindowState = { .normal }
    public var windowType: () -> WKWebExtension.WindowType = { .normal }
    public var setFrame: ((CGRect) -> Void)?
    public var setWindowState: ((WKWebExtension.WindowState) -> Void)?
    public var close: (() -> Void)?

    public init(
        tabs: @escaping () -> [any WKWebExtensionTab],
        activeTab: @escaping () -> (any WKWebExtensionTab)?,
        frame: @escaping () -> CGRect,
        focus: @escaping () -> Void,
        isPrivate: @escaping () -> Bool = { false }
    ) {
        self.tabs = tabs
        self.activeTab = activeTab
        self.frame = frame
        self.focus = focus
        self.isPrivate = isPrivate
    }

    /// Convenience for an NSWindow-backed browser window.
    public convenience init(window: NSWindow, tabs: @escaping () -> [any WKWebExtensionTab],
                            activeTab: @escaping () -> (any WKWebExtensionTab)?, isPrivate: Bool = false) {
        self.init(tabs: tabs, activeTab: activeTab,
                  frame: { [weak window] in window?.frame ?? .null },
                  focus: { [weak window] in window?.makeKeyAndOrderFront(nil); NSApp.activate() },
                  isPrivate: { isPrivate })
        screenFrame = { [weak window] in (window?.screen ?? NSScreen.main)?.frame ?? .null }
        windowState = { [weak window] in
            guard let window else { return .normal }
            if window.styleMask.contains(.fullScreen) { return .fullscreen }
            if window.isMiniaturized { return .minimized }
            if window.isZoomed { return .maximized }
            return .normal
        }
        setFrame = { [weak window] rect in window?.setFrame(rect, display: true) }
        setWindowState = { [weak window] state in
            guard let window else { return }
            switch state {
            case .minimized: window.miniaturize(nil)
            case .maximized: if !window.isZoomed { window.zoom(nil) }
            case .fullscreen: if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            case .normal:
                if window.isMiniaturized { window.deminiaturize(nil) }
                if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            @unknown default: break
            }
        }
        close = { [weak window] in window?.performClose(nil) }
    }

    // MARK: WKWebExtensionWindow

    public func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabs() }
    public func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { activeTab() }
    public func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { windowType() }
    public func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { windowState() }
    public func isPrivate(for context: WKWebExtensionContext) -> Bool { isPrivate() }
    public func frame(for context: WKWebExtensionContext) -> CGRect { frame() }
    public func screenFrame(for context: WKWebExtensionContext) -> CGRect { screenFrame() }

    public func setWindowState(_ state: WKWebExtension.WindowState, for context: WKWebExtensionContext) async throws {
        guard let setWindowState else { throw ExtensionBridgeError.notSupported }
        setWindowState(state)
    }

    public func setFrame(_ frame: CGRect, for context: WKWebExtensionContext) async throws {
        guard let setFrame else { throw ExtensionBridgeError.notSupported }
        setFrame(frame)
    }

    public func focus(for context: WKWebExtensionContext) async throws { focus() }

    public func close(for context: WKWebExtensionContext) async throws {
        guard let close else { throw ExtensionBridgeError.notSupported }
        close()
    }
}
