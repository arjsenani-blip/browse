import AppKit
import WebKit
import BrowserCore

/// Development aid: `Aegis --snapshot out.png [--open URL] [--palette query]`
/// renders the front window (chrome via cacheDisplay, the page via
/// WKWebView.takeSnapshot composited into its frame) and quits. Needs no
/// screen-recording permission. Not reachable from the UI.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(services: AppServices) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("--no-fingerprint") { services.privacy.fingerprintProtection = false; services.applyPrivacy() }
        if args.contains("--no-blocking") { services.privacy.blockContent = false; services.applyPrivacy() }
        if args.contains("--fingerprint") { services.privacy.fingerprintProtection = true; services.applyPrivacy() }
        if args.contains("--fullscreen") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { services.frontController?.window?.toggleFullScreen(nil) }
        }
        let delay = args.firstIndex(of: "--delay").flatMap { Double(args[$0 + 1]) } ?? 6
        if let j = args.firstIndex(of: "--open"), j + 1 < args.count {
            for raw in args[(j + 1)...].prefix(while: { !$0.hasPrefix("--") }) {
                if let url = URL(string: raw) { services.frontController?.navigate(to: url, newTab: true, typed: false) }
            }
        }
        if let k = args.firstIndex(of: "--install-extension"), k + 1 < args.count, let url = URL(string: args[k + 1]) {
            services.installExtension(from: url)
        }
        if args.contains("--list-extensions") {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay - 0.5) {
                for r in services.extensions.extensions {
                    print("EXT \(r.name) \(r.version) enabled=\(r.enabled) loaded=\(services.extensions.context(for: r.id)?.isLoaded ?? false) errors=\(services.extensions.errors(for: r.id))")
                }
                fflush(stdout)
            }
        }
        if args.contains("--private-test") {
            // Private window isolation check (QA finding R2).
            let normal = services.frontController
            services.newPrivateWindow()
            let priv = services.frontController
            priv?.navigate(to: URL(string: "https://example.org/?secret-private-url")!, newTab: true, typed: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                let pid = priv?.spaceID
                let leaked = normal?.visibleSpaces.contains { $0.id == pid } ?? false
                print("PRIVTEST normal window sees private space: \(leaked)")
                print("PRIVTEST private window sees: \(priv?.visibleSpaces.map(\.name) ?? [])")
                if let id = priv?.windowSpace.selected { priv?.closeTab(id) }
                print("PRIVTEST closed-list has private tab: \(services.store.closed.contains { $0.url?.query?.contains("secret") == true })")
                print("PRIVTEST snapshot includes private: \(services.store.snapshot().spaces.contains { $0.id == pid })")
                priv?.window?.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    print("PRIVTEST after close, private space exists: \(services.store.spaces.contains { $0.id == pid }) spaces=\(services.store.spaces.map(\.name))")
                    fflush(stdout)
                }
            }
        }
        if let k = args.firstIndex(of: "--space2-open"), k + 1 < args.count, let url = URL(string: args[k + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay / 2) {
                services.frontController?.newSpace()
                services.frontController?.navigate(to: url, newTab: true, typed: false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let k = args.firstIndex(of: "--palette") {
                services.frontController?.openPalette(args.contains("--newtab") ? .newTab : .command)
                let q = k + 1 < args.count ? args[k + 1] : ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    services.frontController?.debugSetPaletteQuery(q)
                }
            }
            if args.contains("--demo-spaces"), let c = services.frontController {
                // Three themed spaces, favorites and pinned tabs, for design review.
                let names = ["Work", "Study"]
                for (i, n) in names.enumerated() where services.store.spaces.count < 3 {
                    let sp = services.store.addSpace(name: n, accentHue: 0.6, newProfile: false)
                    services.store.setTheme(SpaceTheme.presets[[2, 4][i]].theme, for: sp.id)
                    services.store.openTab(URL(string: "https://example.com"), select: true, in: sp.id)
                }
                let space = c.windowSpace
                for u in ["https://github.com", "https://www.youtube.com", "https://news.ycombinator.com", "https://en.wikipedia.org", "https://www.apple.com"] {
                    let id = services.store.openTab(URL(string: u), select: false, in: space.id)
                    services.store.move(id, to: .favorite)
                }
                let p = services.store.openTab(URL(string: "https://developer.apple.com"), select: false, in: space.id)
                services.store.move(p, to: .pinned)
                c.refresh()
            }
            if args.contains("--demo-folders"), let c = services.frontController {
                let sid = c.windowSpace.id
                let closed = services.store.newFolder(in: sid, name: "Reading list")
                let open = services.store.newFolder(in: sid, name: "Project Aegis")
                for u in ["https://github.com", "https://developer.apple.com/documentation/webkit"] {
                    services.store.moveTab(services.store.openTab(URL(string: u), select: false, in: sid), toFolder: open)
                }
                services.store.moveTab(services.store.openTab(URL(string: "https://en.wikipedia.org/wiki/Arc_(web_browser)"), select: false, in: sid), toFolder: closed)
                services.store.updateFolder(closed) { $0.isExpanded = false }
                c.refresh()
            }
            if args.contains("--organize"), let c = services.frontController {
                let all = services.store.currentSpace.today
                if all.count >= 4 {
                    services.store.move(all[all.count - 1], to: .favorite)
                    services.store.move(all[all.count - 2], to: .favorite)
                    services.store.move(all[all.count - 3], to: .pinned)
                }
                c.refresh()
            }
            if args.contains("--then-select-first") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if let first = services.store.currentSpace.today.last { services.frontController?.select(first) }
                }
            }
            if args.contains("--click-extension"), let c = services.frontController, let first = services.extensions.extensions.first {
                NSApp.activate(ignoringOtherApps: true)
                c.window?.makeKeyAndOrderFront(nil)
                let tab = c.store.currentSpace.selected.flatMap { c.runtime.tab($0) }.map { services.extensionTab($0) }
                services.extensions.performAction(for: first.id, tab: tab)
            }
            if args.contains("--swipe-benchmark"), let c = services.frontController {
                // Make sure there are three themed spaces with a tab each.
                let presets = SpaceTheme.presets
                while services.store.spaces.count < 3 {
                    let sp = services.store.addSpace(name: "Bench \(services.store.spaces.count + 1)", accentHue: 0.6, newProfile: false)
                    services.store.setTheme(presets[services.store.spaces.count % presets.count].theme, for: sp.id)
                    services.store.openTab(URL(string: "https://example.com"), select: true, in: sp.id)
                }
                services.store.currentSpaceID = services.store.spaces[0].id
                c.refresh()
                print("SWIPEBENCH setup: spaces \(services.store.spaces.count), visible \(c.visibleSpaces.count)"); fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let bench = SwipeBenchmark(controller: c) { }
                    objc_setAssociatedObject(c, "bench", bench, .OBJC_ASSOCIATION_RETAIN)
                    bench.run()
                }
            }
            if args.contains("--stress"), let c = services.frontController {
                // Crash hunt: rapid opens, closes, space switches, folder churn,
                // a private window and deleting the current space mid-animation.
                Task { @MainActor in
                    for i in 0..<40 {
                        switch i % 8 {
                        case 0: c.navigate(to: URL(string: "https://example.com/?s=\(i)")!, newTab: true)
                        case 1: c.switchSpace(1)
                        case 2: c.closeCurrentTab()
                        case 3: c.newFolder(); if let f = c.windowSpace.folders.first, let t = c.windowSpace.today.first { services.store.moveTab(t, toFolder: f.id) }
                        case 4: c.switchSpace(-1); c.cycleTab(1)
                        case 5: if let f = c.windowSpace.folders.first { services.store.deleteFolder(f.id, closeTabs: false) }
                        case 6: c.reopenClosedTab(); c.toggleReader()
                        default: c.sidebarClearToday()
                        }
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                    services.newPrivateWindow()
                    services.frontController?.navigate(to: URL(string: "https://example.org")!, newTab: true)
                    try? await Task.sleep(for: .milliseconds(200))
                    services.frontController?.window?.close()
                    let extra = services.store.addSpace(name: "Doomed", accentHue: 0.1, newProfile: true)
                    services.store.openTab(URL(string: "https://example.net"), in: extra.id)
                    c.sidebarSwitchSpace(c.visibleSpaces.firstIndex { $0.id == extra.id } ?? 0)
                    c.deleteSpace(extra.id, confirm: false)
                    c.switchSpace(1)
                    print("STRESS done spaces=\(services.store.spaces.count) tabs=\(services.store.tabs.count) live=\(services.runtime.liveCount) current-visible=\(c.visibleSpaces.contains { $0.id == services.store.currentSpaceID })")
                    fflush(stdout)
                }
            }
            if args.contains("--playall") {
                for space in services.store.spaces { for id in space.allTabs { services.runtime.tab(id)?.togglePlayback() } }
            }
            if args.contains("--library") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { services.frontController?.openLibrary(tab: args.contains("--media") ? .media : .downloads) }
            }
            if args.contains("--reader") { services.frontController?.toggleReader() }
            if let e = args.firstIndex(of: "--eval"), e + 1 < args.count,
               let c = services.frontController, let id = c.store.selectedTab?.id, let web = c.runtime.tab(id)?.webView {
                Task {
                    let r = try? await web.callAsyncJavaScript(args[e + 1], arguments: [:], in: nil, contentWorld: .page)
                    print("EVAL \(r.map { "\($0)" } ?? "nil")"); fflush(stdout)
                }
            }
            if args.contains("--memory") {
                Task {
                    print("MEM before: live=\(services.runtime.liveCount) app=\(footprintMB()) MB")
                    for id in services.store.currentSpace.allTabs where id != services.store.currentSpace.selected {
                        await services.runtime.sleep(id)
                    }
                    try? await Task.sleep(for: .seconds(3))
                    print("MEM after sleep: live=\(services.runtime.liveCount) app=\(footprintMB()) MB")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (args.firstIndex(of: "--settle").flatMap { Double(args[$0 + 1]) } ?? (args.contains("--memory") ? 12 : 1.5))) {
                Task {
                    if args.contains("--resources") { await printResources(services: services) }
                    await capture(services: services, to: out)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    static func capture(services: AppServices, to url: URL) async {
        guard let window = services.frontController?.window, let content = window.contentView else { return }
        let bounds = content.bounds
        print("OVERLAYS at \(Date().timeIntervalSince1970) \(content.subviews.map { "\(type(of: $0)) \($0.frame.integral)" })"); fflush(stdout)
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        content.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        // Web content is drawn out of process; paint its snapshot under the chrome.
        let composed = NSImage(size: bounds.size)
        composed.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        for web in allWebViews(in: content) where !web.isHidden && web.window != nil {
            let config = WKSnapshotConfiguration()
            if let snap = try? await web.takeSnapshot(configuration: config) {
                let frame = web.convert(web.bounds, to: content)
                snap.draw(in: frame)
            }
        }
        image.draw(in: bounds)
        composed.unlockFocus()
        print("WINDOWS \(NSApp.windows.map { "\($0.className) visible=\($0.isVisible) \($0.frame.integral)" })"); fflush(stdout)
        // Popovers live in their own windows; save each beside the main image.
        for (n, w) in NSApp.windows.enumerated() where w.isVisible && w !== window && w.className.contains("Popover") {
            if let v = w.contentView, let web = allWebViews(in: v).first,
               let img = try? await web.takeSnapshot(configuration: WKSnapshotConfiguration()),
               let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff) {
                try? bmp.representation(using: .png, properties: [:])?.write(to: url.deletingPathExtension().appendingPathExtension("popover\(n).png"))
            } else if let v = w.contentView, let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: r)
                try? r.representation(using: .png, properties: [:])?.write(to: url.deletingPathExtension().appendingPathExtension("popover\(n).png"))
            }
        }
        if let tiff = composed.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff), let png = bmp.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }

    /// Prints every third-party host the current page loaded resources from.
    static func printResources(services: AppServices) async {
        guard let c = services.frontController, let id = c.store.selectedTab?.id, let web = c.runtime.tab(id)?.webView else { return }
        let js = "JSON.stringify([...new Set(performance.getEntriesByType('resource').map(e => { try { return new URL(e.name).hostname } catch (_) { return '' } }))])"
        let result = try? await web.evaluateJavaScript(js)
        print("RESOURCE_HOSTS \(web.url?.host() ?? "") \(result as? String ?? "[]")")
        let globals = try? await web.evaluateJavaScript("JSON.stringify({gtm: !!window.google_tag_manager, googletag: typeof window.googletag === 'object' && !!window.googletag.pubads, fbq: typeof window.fbq, apstag: typeof window.apstag})")
        print("AD_GLOBALS \(globals as? String ?? "?")")
        let ruleLists = services.blocking.ruleLists.count
        print("RULE_LISTS \(ruleLists) RULES \(services.blocking.ruleCount)")
    }

    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    private static func allWebViews(in view: NSView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(allWebViews)
    }
}
