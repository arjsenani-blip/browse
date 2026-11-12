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
            SettingsWindow.runDebugSnapshotIfRequested(services: services)
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

    @objc func importBrowserData() {
        let sources = ImportSources.detect()
        guard !sources.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No other browsers found"
            alert.informativeText = "Aegis looks for Arc, Chrome, Brave, Edge, Vivaldi and Safari data on this Mac."
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Import from other browsers"
        alert.informativeText = "Arc spaces, favorites and pinned tabs come over as spaces. Bookmarks go into an “Imported Bookmarks” space. Nothing loads until you open it."
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        var boxes: [(NSButton, ImportSource)] = []
        for source in sources {
            let box = NSButton(checkboxWithTitle: source.status == .needsFullDiskAccess ? "\(source.displayName) (needs Full Disk Access)" : source.displayName, target: nil, action: nil)
            box.state = source.status == .readable ? .on : .off
            box.isEnabled = source.status == .readable
            stack.addArrangedSubview(box)
            boxes.append((box, source))
        }
        let separate = NSButton(checkboxWithTitle: "Give each imported space its own cookies and logins", target: nil, action: nil)
        separate.state = .on
        stack.addArrangedSubview(separate)
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: CGFloat(boxes.count + 1) * 24)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var plan = ImportPlan()
        var errors: [String] = []
        for (box, source) in boxes where box.state == .on {
            do { plan = plan.merged(with: try source.load(arcOptions: .init())) } catch { errors.append("\(source.displayName): \(error)") }
        }
        let summary = services.store.apply(plan, newProfilesPerSpace: separate.state == .on)
        UserDefaults.standard.set(true, forKey: "importBannerDone")
        let done = NSAlert()
        done.messageText = "Imported \(summary.tabsAdded) tabs into \(summary.touchedSpaceIDs.count) spaces"
        done.informativeText = (errors + summary.warnings.prefix(5)).joined(separator: "\n")
        done.runModal()
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
    @objc func findNext() { front?.findAgain(backwards: false) }
    @objc func findPrevious() { front?.findAgain(backwards: true) }
    @objc func commandPalette() { front?.openPalette(.command) }
    @objc func toggleSidebar() { front?.toggleSidebar() }
    @objc func addSplitView() { front?.addSplitView() }
    @objc func removeFromSplit() { front?.removeFromSplit() }
    @objc func separateSplit() { front?.separateSplit() }
    @objc func nextPane() { front?.focusPane(by: 1) }
    @objc func previousPane() { front?.focusPane(by: -1) }
    @objc func focusPane(_ sender: NSMenuItem) { front?.focusPane(at: sender.tag) }
    @objc func showLibrary() { front?.openLibrary() }
    @objc func toggleTabsOnTop() {
        let on = !(front?.tabsOnTop ?? false)
        services.forEachController { $0.tabsOnTop = on }
    }
    @objc func toggleReader() { front?.toggleReader() }
    @objc func cycleReaderTheme() { front?.cycleReaderTheme() }
    @objc func reload() { front?.sidebarReload() }
    @objc func zoomIn() { if front?.readerZoom(2) != true { zoom(by: 1.1) } }
    @objc func zoomOut() { if front?.readerZoom(-2) != true { zoom(by: 1 / 1.1) } }
    @objc func zoomReset() { if front?.readerZoom(nil) != true { currentWebView?.pageZoom = 1 } }
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
    @objc func newFolder() { front?.newFolder() }
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

    @objc func addExtension() {
        let alert = NSAlert()
        alert.messageText = "Add an extension"
        alert.informativeText = "Paste a Chrome Web Store link, or open the store and Aegis will offer to add the extension you're viewing."
        let field = NSTextField(string: "")
        field.placeholderString = "https://chromewebstore.google.com/detail/…"
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Open Chrome Web Store")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespaces)) { services.installExtension(from: url) }
        case .alertSecondButtonReturn:
            front?.navigate(to: URL(string: "https://chromewebstore.google.com")!, newTab: true)
        default: break
        }
    }

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
        case #selector(toggleTabsOnTop): item.state = front?.tabsOnTop == true ? .on : .off
        case #selector(toggleSidebar):
            item.title = front?.sidebarHidden == true ? "Show Sidebar" : "Hide Sidebar"
            return front?.tabsOnTop != true
        case #selector(removeFromSplit), #selector(separateSplit), #selector(nextPane), #selector(previousPane), #selector(focusPane(_:)):
            return front?.isInSplit == true
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
