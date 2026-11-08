import AppKit
import WebKit

/// Renders a sanitized article in a separate, script-free, non-persistent web
/// view with a strict CSP. The page's own scripts never reach it.
@MainActor
public final class ReaderView: NSView {
    public enum Theme: String, CaseIterable { case light, sepia, dark }
    private let webView: WKWebView
    public var theme: Theme = .light { didSet { render() } }
    public var fontSize: CGFloat = 20 { didSet { render() } }
    private var article: (title: String, byline: String, site: String, html: String)?

    public override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frame)
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    public func show(title: String, byline: String, site: String, html: String) {
        article = (title, byline, site, html)
        render()
    }

    private func render() {
        guard let a = article else { return }
        let (bg, fg, muted): (String, String, String) = switch theme {
        case .light: ("#fdfdfc", "#1d1d1f", "#6e6e73")
        case .sepia: ("#f6efe2", "#3b3024", "#857561")
        case .dark: ("#1c1c1e", "#e5e5e7", "#98989d")
        }
        let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; media-src https:">
        <style>
          :root { color-scheme: \(theme == .dark ? "dark" : "light"); }
          body { margin: 0; background: \(bg); color: \(fg); font: \(Int(fontSize))px/1.55 "New York", ui-serif, Georgia, serif; -webkit-font-smoothing: antialiased; }
          main { max-width: 34em; margin: 0 auto; padding: 56px 28px 120px; }
          h1 { font: 700 1.6em/1.2 -apple-system, system-ui, sans-serif; margin: 0 0 .4em; letter-spacing: -0.01em; }
          .meta { font: 0.7em/1.4 -apple-system, system-ui, sans-serif; color: \(muted); margin-bottom: 2.2em; }
          p, li { margin: 0 0 1em; } img, video, figure { max-width: 100%; height: auto; border-radius: 8px; }
          figcaption { font-size: .75em; color: \(muted); } a { color: inherit; text-decoration-color: \(muted); }
          pre, code { font: .8em ui-monospace, Menlo, monospace; } pre { overflow-x: auto; padding: 1em; background: rgba(127,127,127,.12); border-radius: 8px; }
          blockquote { margin: 1em 0; padding-left: 1em; border-left: 3px solid \(muted); color: \(muted); }
        </style></head><body><main>
        <h1>\(escape(a.title))</h1>
        <div class="meta">\(escape([a.site, a.byline].filter { !$0.isEmpty }.joined(separator: " · ")))</div>
        \(a.html)
        </main></body></html>
        """
        webView.loadHTMLString(page, baseURL: nil)
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
