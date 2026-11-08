import AppKit
import UniformTypeIdentifiers
import BrowserCore
import WebEngine
import ChromeUI
import Credentials

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var services: AppServices!

    func applicationDidFinishLaunching(_ notification: Notification) {
        services = AppServices()
        NSApp.mainMenu = Menus.build(target: self)
        Task {
            await services.start()
            services.newWindow()
            DebugSnapshot.runIfRequested(services: services)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { services.newWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        services.saveSession()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { services.openExternal(url) }
    }

    private var front: BrowserWindowController? { services.frontController }

    // MARK: File
    @objc func newTab() { front?.openPalette(.newTab) ?? services.newWindow() }
    @objc func newWindow() { services.newWindow() }
    @objc func newPrivateWindow() { services.newPrivateWindow() }
    @objc func openLocation() { front?.openPalette(.navigate) }
    @objc func closeTab() { front?.closeCurrentTab() }
    @objc func reopenClosedTab() { front?.reopenClosedTab() }

    @objc func importPasswords() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Choose a CSV exported from Passwords, Safari or Chrome."
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        Task {
            let (summary, errors) = await PasswordCSVImporter.importCSV(text, into: services.passwords, overwriteConflicts: false)
            let alert = NSAlert()
            alert.messageText = "Imported \(summary.imported) passwords"
            alert.informativeText = "Skipped \(summary.skippedDuplicates) duplicates, \(summary.conflicts) conflicts, \(errors.count) unreadable rows. Delete the CSV file now — it contains your passwords in plain text."
            alert.runModal()
        }
    }

    @objc func exportPasswords() {
        Task {
            guard let csv = try? await PasswordCSVExporter.exportAll(from: services.passwords, reason: "export your saved passwords") else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Aegis Passwords.csv"
            panel.allowedContentTypes = [.commaSeparatedText]
            if panel.runModal() == .OK, let url = panel.url { try? csv.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    // MARK: Edit / View
    @objc func copyURL() { front?.copyURL() }
    @objc func find() { front?.showFind() }
    @objc func commandPalette() { front?.openPalette(.command) }
    @objc func toggleSidebar() { front?.toggleSidebar() }
    @objc func toggleReader() { front?.toggleReader() }
    @objc func cycleReaderTheme() { front?.cycleReaderTheme() }
    @objc func reload() { front?.sidebarReload() }
    @objc func zoomIn() { zoom(by: 1.1) }
    @objc func zoomOut() { zoom(by: 1 / 1.1) }
    @objc func zoomReset() { currentWebView?.pageZoom = 1 }
    private func zoom(by f: CGFloat) { if let w = currentWebView { w.pageZoom = min(3, max(0.3, w.pageZoom * f)) } }
    private var currentWebView: WKWebViewRef? {
        guard let c = front, let id = c.store.selectedTab?.id else { return nil }
        return c.runtime.tab(id)?.webView
    }

    // MARK: Tabs / Spaces
    @objc func goBack() { front?.sidebarBack() }
    @objc func goForward() { front?.sidebarForward() }
    @objc func nextTab() { front?.cycleTab(1) }
    @objc func previousTab() { front?.cycleTab(-1) }
    @objc func togglePin() { front?.togglePin() }
    @objc func toggleFavorite() { front?.toggleFavorite() }
    @objc func hibernateBackground() { front?.hibernateCurrentSpaceBackground() }
    @objc func selectTabNumber(_ sender: NSMenuItem) { front?.selectTab(at: sender.tag) }
    @objc func newSpace() { front?.newSpace() }
    @objc func nextSpace() { front?.switchSpace(1) }
    @objc func previousSpace() { front?.switchSpace(-1) }

    // MARK: Privacy
    @objc func toggleBlocking() { services.privacy.blockContent.toggle(); services.applyPrivacy() }
    @objc func toggleFingerprinting() { services.privacy.fingerprintProtection.toggle(); services.applyPrivacy() }
    @objc func toggleStripping() { services.privacy.stripTrackingParameters.toggle(); services.applyPrivacy() }
    @objc func toggleHTTPSOnly() { services.privacy.httpsOnly.toggle(); services.applyPrivacy() }
    @objc func updateFilters() { services.updateFilters(force: true) }

    @objc func clearSpaceData() {
        guard let c = front else { return }
        let alert = NSAlert()
        alert.messageText = "Clear website data for “\(c.store.currentSpace.name)”?"
        alert.informativeText = "Signs you out of sites in this space and removes their cookies, storage and cache. Tabs stay open."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let profile = c.store.profile(for: c.store.currentSpace)
        Task { await c.runtime.context(for: profile).clearData() }
    }

    @objc func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear all browsing history?"
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        services.clearHistory()
    }

    @objc func showSettings() { services.showSettings() }

    @objc func makeDefaultBrowser() {
        let url = Bundle.main.bundleURL
        Task {
            try? await NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: "http")
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleBlocking): item.state = services.privacy.blockContent ? .on : .off
        case #selector(toggleFingerprinting): item.state = services.privacy.fingerprintProtection ? .on : .off
        case #selector(toggleStripping): item.state = services.privacy.stripTrackingParameters ? .on : .off
        case #selector(toggleHTTPSOnly): item.state = services.privacy.httpsOnly ? .on : .off
        case #selector(togglePin):
            item.title = front?.store.selectedTab?.tier == .pinned ? "Unpin Tab" : "Pin Tab"
            return front?.store.selectedTab != nil
        case #selector(toggleFavorite):
            item.title = front?.store.selectedTab?.tier == .favorite ? "Remove from Favorites" : "Add to Favorites"
            return front?.store.selectedTab != nil
        case #selector(goBack): return currentWebView?.canGoBack ?? false
        case #selector(goForward): return currentWebView?.canGoForward ?? false
        default: break
        }
        return true
    }
}

import WebKit
typealias WKWebViewRef = WKWebView
