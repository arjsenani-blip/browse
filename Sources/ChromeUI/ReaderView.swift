import AppKit
import WebKit

/// Renders a sanitized article in a separate, script-free, non-persistent web
/// view with a strict CSP. The page's own scripts never reach it.
@MainActor
public final class ReaderView: NSView, WKNavigationDelegate {
    public enum Theme: String, CaseIterable { case light, sepia, dark }
    private let webView: WKWebView
    /// nil follows the system appearance (light or dark) until the reader
    /// picks a theme.
    private var chosenTheme: Theme? { didSet { render(); syncControls() } }
    public var theme: Theme {
        get { chosenTheme ?? (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light) }
        set { chosenTheme = newValue }
    }
    public var fontSize: CGFloat = 20 { didSet { fontSize = min(32, max(14, fontSize)); if fontSize != oldValue { render() } } }
    /// Links clicked in the article open in the real tab, never in this
    /// script-free view.
    public var onOpenLink: ((URL) -> Void)?
    private var article: (title: String, byline: String, site: String, html: String)?
    private let controls = NSVisualEffectView()
    private var themeButtons: [Theme: NSButton] = [:]

    public override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frame)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        buildControls()
    }

    required init?(coder: NSCoder) { fatalError() }

    public func show(title: String, byline: String, site: String, html: String) {
        article = (title, byline, site, html)
        render()
        syncControls()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if chosenTheme == nil { render(); syncControls() }
    }

    // MARK: Floating Aa / theme pill

    private func buildControls() {
        controls.material = .hudWindow
        controls.blendingMode = .withinWindow
        controls.state = .active
        controls.wantsLayer = true
        controls.layer?.cornerRadius = 15
        controls.layer?.cornerCurve = .continuous
        controls.translatesAutoresizingMaskIntoConstraints = false
        func textButton(_ title: String, size: CGFloat, label: String, action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.isBordered = false
            b.font = .systemFont(ofSize: size, weight: .semibold)
            b.contentTintColor = .secondaryLabelColor
            b.setAccessibilityLabel(label)
            b.toolTip = label
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            return b
        }
        let smaller = textButton("A", size: 11, label: "Smaller Text", action: #selector(smaller))
        let larger = textButton("A", size: 15, label: "Larger Text", action: #selector(larger))
        var views: [NSView] = [smaller, larger]
        let divider = NSBox()
        divider.boxType = .separator
        divider.heightAnchor.constraint(equalToConstant: 14).isActive = true
        views.append(divider)
        for t in Theme.allCases {
            let b = NSButton(title: "", target: self, action: #selector(pickTheme(_:)))
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 8
            b.layer?.borderWidth = 1
            b.layer?.backgroundColor = Self.colors(t).bg.cgColor
            b.tag = Theme.allCases.firstIndex(of: t) ?? 0
            b.setAccessibilityLabel("\(t.rawValue.capitalized) Theme")
            b.toolTip = "\(t.rawValue.capitalized) theme (⌥⌘R cycles)"
            b.widthAnchor.constraint(equalToConstant: 16).isActive = true
            b.heightAnchor.constraint(equalToConstant: 16).isActive = true
            themeButtons[t] = b
            views.append(b)
        }
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(stack)
        addSubview(controls)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            controls.heightAnchor.constraint(equalToConstant: 30),
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        controls.setAccessibilityElement(true)
        controls.setAccessibilityRole(.group)
        controls.setAccessibilityLabel("Reader options")
    }

    private func syncControls() {
        let current = theme
        for (t, b) in themeButtons {
            b.layer?.borderColor = (t == current ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            b.layer?.borderWidth = t == current ? 2 : 1
            b.setAccessibilityValue(t == current ? "selected" : nil)
        }
    }

    @objc private func smaller() { fontSize -= 2 }
    @objc private func larger() { fontSize += 2 }
    @objc private func pickTheme(_ sender: NSButton) { theme = Theme.allCases[sender.tag] }

    // MARK: Rendering

    private static func colors(_ t: Theme) -> (bg: NSColor, hexBG: String, fg: String, muted: String) {
        switch t {
        case .light: (NSColor(srgbRed: 0.992, green: 0.992, blue: 0.988, alpha: 1), "#fdfdfc", "#1d1d1f", "#6e6e73")
        case .sepia: (NSColor(srgbRed: 0.965, green: 0.937, blue: 0.886, alpha: 1), "#f6efe2", "#3b3024", "#857561")
        case .dark: (NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1), "#1c1c1e", "#e5e5e7", "#98989d")
        }
    }

    private func render() {
        guard let a = article else { return }
        let c = Self.colors(theme)
        let (bg, fg, muted) = (c.hexBG, c.fg, c.muted)
        let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; media-src https:">
        <style>
          :root { color-scheme: \(theme == .dark ? "dark" : "light"); }
          body { margin: 0; background: \(bg); color: \(fg); font: \(Int(fontSize))px/1.55 "New York", ui-serif, Georgia, serif; -webkit-font-smoothing: antialiased; }
          main { max-width: 34em; margin: 0 auto; padding: 64px 28px 120px; }
          h1 { font: 700 1.6em/1.2 -apple-system, system-ui, sans-serif; margin: 0 0 .4em; letter-spacing: -0.01em; text-wrap: balance; }
          h2, h3, h4 { font-family: -apple-system, system-ui, sans-serif; line-height: 1.25; margin: 1.6em 0 .5em; }
          .meta { font: 0.7em/1.4 -apple-system, system-ui, sans-serif; color: \(muted); margin-bottom: 2.2em; }
          p, li { margin: 0 0 1em; } img, video, figure { max-width: 100%; height: auto; border-radius: 8px; }
          figure { margin: 1.4em 0; }
          /* Tracking pixels and spacer images that survive Readability. */
          img[width="1"], img[height="1"], img[width="0"], img[height="0"] { display: none; }
          figcaption { font-size: .75em; color: \(muted); margin-top: .4em; }
          a { color: inherit; text-decoration-line: underline; text-decoration-thickness: 1px; text-underline-offset: .18em; text-decoration-color: color-mix(in srgb, \(muted) 55%, transparent); }
          a:hover { text-decoration-color: \(muted); }
          table { border-collapse: collapse; font-size: .8em; max-width: 100%; display: block; overflow-x: auto; }
          td, th { padding: .3em .6em; border-bottom: 1px solid rgba(127,127,127,.2); text-align: left; vertical-align: top; }
          pre, code { font: .8em ui-monospace, Menlo, monospace; } pre { overflow-x: auto; padding: 1em; background: rgba(127,127,127,.12); border-radius: 8px; }
          blockquote { margin: 1em 0; padding-left: 1em; border-left: 3px solid \(muted); color: \(muted); }
          hr { border: 0; border-top: 1px solid rgba(127,127,127,.25); margin: 2em 0; }
        </style></head><body><main>
        <h1>\(escape(a.title))</h1>
        <div class="meta">\(escape([a.site, a.byline].filter { !$0.isEmpty }.joined(separator: " · ")))</div>
        \(a.html)
        </main></body></html>
        """
        webView.loadHTMLString(page, baseURL: nil)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // Only our own rendered HTML loads here; a clicked link goes to the tab.
        if action.navigationType == .linkActivated {
            guard let url = action.request.url else { return .cancel }
            if url.scheme == "about" { return .allow }   // in-article #anchors
            if url.scheme == "http" || url.scheme == "https" { onOpenLink?(url) }
            return .cancel
        }
        return action.request.url?.scheme == "about" ? .allow : .cancel
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
