import Foundation

/// Where a typed query that isn't an address goes. Chosen in Settings →
/// Search & Tabs; stored in UserDefaults under `searchEngine`.
public enum SearchEngine: String, CaseIterable, Sendable, Identifiable {
    case google, duckDuckGo, startpage, brave, ecosia, kagi, bing

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

    /// OpenSearch suggestion endpoint (`["query", ["suggestion", …]]`); nil when the engine has none
    /// that works without an account.
    public var suggestTemplate: String? {
        switch self {
        case .google: "https://suggestqueries.google.com/complete/search?client=firefox&q=%s"
        case .duckDuckGo: "https://duckduckgo.com/ac/?q=%s&type=list"
        case .brave: "https://search.brave.com/api/suggest?q=%s"
        case .ecosia: "https://ac.ecosia.org/autocomplete?q=%s&type=list"
        case .bing: "https://api.bing.com/osjson.aspx?query=%s"
        case .startpage, .kagi: nil
        }
    }

    public var host: String { URL(string: template.replacingOccurrences(of: "%s", with: ""))?.host() ?? "" }

    public static let defaultsKey = "searchEngine"

    public static var current: SearchEngine {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(SearchEngine.init(rawValue:)) ?? .google }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    public static let suggestionsKey = "searchSuggestions"

    /// Whether the palette asks the engine for suggestions as you type. On unless turned off in
    /// Settings; never used in private windows.
    public static var suggestionsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: suggestionsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: suggestionsKey) }
    }
}
