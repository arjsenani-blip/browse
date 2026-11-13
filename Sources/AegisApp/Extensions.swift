import AppKit
import WebKit
import BrowserCore
import WebEngine

/// Chrome Web Store extensions, hosted by WebKit's WKWebExtension runtime.
/// Nothing touches the network until the user chooses "Add to Aegis".
extension AppServices {
    func extensionTab(_ tab: WebTab) -> ExtensionTabAdapter {
        extensions.adapter(for: tab,
            isSelected: { [weak self] in self?.store.space(containing: tab.id)?.selected == tab.id },
            window: { [weak self] in self?.controller(containing: tab.id)?.extensionWindow },
            activate: { [weak self] in self?.controller(containing: tab.id)?.select(tab.id) },
            close: { [weak self] in self?.controller(containing: tab.id)?.closeTab(tab.id) })
    }

    func controller(containing id: TabID) -> BrowserWindowController? {
        frontController
    }

    func wireExtensions() {
        runtime.onTabCreated = { [weak self] tab in
            guard let self else { return }
            self.extensions.didOpen(tab: self.extensionTab(tab))
        }
        extensions.openWindows = { [unowned self] in
            forEachControllerSorted().map(\.extensionWindow)
        }
        extensions.openTab = { [unowned self] request in
            guard frontController != nil else { return nil }
            let id = store.openTab(request.url, select: request.active)
            guard let tab = runtime.tab(id) else { return nil }
            if let url = request.url, request.active { tab.load(url) }
            return extensionTab(tab)
        }
        extensions.presentActionPopup = { [unowned self] action, id in
            if CommandLine.arguments.contains("--snapshot") { print("POPUP id=\(id) button=\(frontController?.extensionButton(for: id) != nil) popover=\(action.popupPopover != nil) webView=\(action.popupWebView != nil)"); fflush(stdout) }
            guard let button = frontController?.extensionButton(for: id) else { return }
            ExtensionPopup.show(action: action, from: button)
        }
        extensions.actionDidUpdate = { [unowned self] _, _ in
            forEachController { $0.refreshExtensionButtons() }
        }
        extensions.promptForPermissions = { prompt in
            let alert = NSAlert()
            alert.messageText = "“\(prompt.name)” wants more access"
            let what = (prompt.permissions + prompt.matchPatterns + prompt.urls.map { $0.host() ?? $0.absoluteString })
            alert.informativeText = what.prefix(8).joined(separator: "\n")
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Don't Allow")
            guard alert.runModal() == .alertFirstButtonReturn else { return .deny }
            return .init(permissions: Set(prompt.permissions), matchPatterns: Set(prompt.matchPatterns), urls: Set(prompt.urls))
        }
        extensions.openOptionsPage = { url, configuration, id in
            ExtensionOptionsWindow.show(url: url, configuration: configuration, title: "Extension Options")
        }
        extensions.onChange = { [unowned self] in
            forEachController { $0.refreshExtensionButtons() }
        }
    }

    func forEachControllerSorted() -> [BrowserWindowController] {
        var all: [BrowserWindowController] = []
        forEachController { all.append($0) }
        return all.sorted { a, _ in a.window?.isKeyWindow == true }
    }

    /// On a Chrome Web Store detail page, offer to add the extension.
    func offerStoreInstall(for url: URL) {
        guard let id = extensions.storeExtensionID(for: url) else { return }
        let installed = extensions.isInstalled(id)
        CredentialBanner.show(in: frontController?.window, symbol: "puzzlepiece.extension",
                              text: installed ? "This extension is installed in Vane." : "Add this extension to Vane?",
                              primary: installed ? "Remove" : "Add to Vane", secondary: "Not Now", timeout: 30,
                              primaryAction: { [weak self] in
                                  guard let self else { return }
                                  if installed { Task { try? await self.extensions.uninstall(id: id) } }
                                  else { self.installExtension(from: url) }
                              })
    }

    func installExtension(from url: URL) {
        Task {
            do {
                Toast.show("Downloading extension…", in: frontController?.window)
                let ext = try await extensions.install(fromWebStoreURL: url)
                guard let request = extensions.pendingPermissions(for: ext.id) else {
                    try extensions.grant(ExtensionPermissionGrant(extensionID: ext.id, permissions: [], matchPatterns: []))
                    return
                }
                let manifest = try? ExtensionManifest.read(from: extensions.installer.directory(for: ext.id))
                let warnings = (manifest.map { ExtensionCompatibility.unsupported(in: $0) } ?? []).map { "\($0.permission): \($0.note)" }
                if CommandLine.arguments.contains("--auto-consent") || consent(name: ext.name, request: request, warnings: warnings) {
                    try extensions.grant(ExtensionPermissionGrant(request))
                    Toast.show("Added \(ext.name)", in: frontController?.window)
                } else {
                    try await extensions.uninstall(id: ext.id)
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't add the extension"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func consent(name: String, request: ExtensionPermissionRequest, warnings: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Add “\(name)”?"
        var text = request.summary.isEmpty ? "It asks for no special access." : "It will be able to:\n• " + request.summary.joined(separator: "\n• ")
        if !warnings.isEmpty {
            text += "\n\nNot supported in Vane (parts of the extension may not work):\n• " + warnings.prefix(6).joined(separator: "\n• ")
        }
        alert.informativeText = text
        alert.addButton(withTitle: "Add Extension")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Options pages are webkit-extension:// URLs that need the extension's own
/// configuration, so they get a small window of their own.
@MainActor
enum ExtensionOptionsWindow {
    private static var windows: [NSWindow] = []
    static func show(url: URL, configuration: WKWebViewConfiguration?, title: String) {
        guard let configuration else { return }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 560), configuration: configuration)
        web.load(URLRequest(url: url))
        let w = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = title
        w.contentView = web
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        windows.append(w)
        windows.removeAll { !$0.isVisible && $0 !== w }
    }
}

/// Hosts an extension's popup web view in our own popover, sized to the
/// popup's content (WebKit reports it via the web view's frame).
@MainActor
enum ExtensionPopup {
    private static var current: NSPopover?
    static func show(action: WKWebExtension.Action, from button: NSView) {
        current?.close()
        guard let web = action.popupWebView else { action.popupPopover?.show(relativeTo: button.bounds, of: button, preferredEdge: .maxX); return }
        let vc = NSViewController()
        let size = web.frame.size.width > 40 ? web.frame.size : NSSize(width: 360, height: 480)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)
        vc.view = container
        let popover = NSPopover()
        popover.contentViewController = vc
        popover.contentSize = size
        popover.behavior = .semitransient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = PopupLogger.shared
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxX)
        current = popover
    }
}

final class PopupLogger: NSObject, NSPopoverDelegate {
    @MainActor static let shared = PopupLogger()
    func popoverWillClose(_ notification: Notification) {
        guard CommandLine.arguments.contains("--snapshot") else { return }
        print("POPOVER CLOSING\n" + Thread.callStackSymbols.prefix(14).joined(separator: "\n")); fflush(stdout)
    }
    func popoverDidShow(_ notification: Notification) {
        if CommandLine.arguments.contains("--snapshot") { print("POPOVER SHOWN"); fflush(stdout) }
    }
}
