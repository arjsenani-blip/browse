import Foundation

/// Where a typed query that isn't an address goes. Chosen in Settings →
/// Search & Tabs; stored in UserDefaults under `searchEngine`.
public enum SearchEngine: String, CaseIterable, Sendable, Identifiable {
    case duckDuckGo, startpage, brave, ecosia, kagi, google, bing

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .duckDuckGo: "DuckDuckGo"
        case .startpage: "Startpage"
        case .brave: "Brave Search"
        case .ecosia: "Ecosia"
        case .kagi: "Kagi"
        case .google: "Google"
        case .bing: "Bing"
        }
    }

    /// `%s` is replaced by the percent-encoded query.
    public var template: String {
        switch self {
        case .duckDuckGo: "https://duckduckgo.com/?q=%s"
        case .startpage: "https://www.startpage.com/do/search?q=%s"
        case .brave: "https://search.brave.com/search?q=%s"
        case .ecosia: "https://www.ecosia.org/search?q=%s"
        case .kagi: "https://kagi.com/search?q=%s"
        case .google: "https://www.google.com/search?q=%s"
        case .bing: "https://www.bing.com/search?q=%s"
        }
    }

    public var host: String { URL(string: template.replacingOccurrences(of: "%s", with: ""))?.host() ?? "" }

    public static let defaultsKey = "searchEngine"

    public static var current: SearchEngine {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(SearchEngine.init(rawValue:)) ?? .duckDuckGo }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}
