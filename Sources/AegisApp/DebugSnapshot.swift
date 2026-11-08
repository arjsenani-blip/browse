import AppKit
import WebKit

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
        if let k = args.firstIndex(of: "--space2-open"), k + 1 < args.count, let url = URL(string: args[k + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay / 2) {
                services.frontController?.newSpace()
                services.frontController?.navigate(to: url, newTab: true, typed: false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let k = args.firstIndex(of: "--palette") {
                services.frontController?.openPalette(.command)
                let q = k + 1 < args.count ? args[k + 1] : ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    services.frontController?.debugSetPaletteQuery(q)
                }
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
