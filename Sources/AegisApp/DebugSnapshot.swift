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
        let delay = args.firstIndex(of: "--delay").flatMap { Double(args[$0 + 1]) } ?? 6
        if let j = args.firstIndex(of: "--open"), j + 1 < args.count {
            for raw in args[(j + 1)...].prefix { !$0.hasPrefix("--") } {
                if let url = URL(string: raw) { services.frontController?.navigate(to: url, newTab: true, typed: false) }
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
            if args.contains("--reader") { services.frontController?.toggleReader() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
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

    private static func allWebViews(in view: NSView) -> [WKWebView] {
        (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(allWebViews)
    }
}
