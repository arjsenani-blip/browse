import Foundation
import BrowserCore

/// Fetches query suggestions from the search engine's OpenSearch endpoint. Cookieless, uncached
/// session; only the typed text is sent. Results are cached per query for the session.
public final class SearchSuggester: Sendable {
    private let session: URLSession
    private let cache = SuggestionCache()
    /// Template with `%s`, read per request so a Settings change applies at once.
    private let template: @Sendable () -> String?

    public init(template: @escaping @Sendable () -> String? = { SearchEngine.current.suggestTemplate }) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 2
        session = URLSession(configuration: config)
        self.template = template
    }

    public func suggestions(for raw: String) async -> [String] {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 200, !OmniboxRanker.looksLikeURL(text),
              let template = template() else { return [] }
        let key = template + "\u{0}" + text.lowercased()
        if let hit = await cache.get(key) { return hit }
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))
        guard let q = text.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: template.replacingOccurrences(of: "%s", with: q)) else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let list = Self.parse(data, encoding: response.textEncodingName)
        await cache.set(key, list)
        return list
    }

    /// `["query", ["a", "b", …], …]`. Google answers in the charset it names, not always UTF-8.
    static func parse(_ data: Data, encoding: String?) -> [String] {
        var bytes = data
        if let name = encoding?.lowercased(), name != "utf-8", name != "utf8" {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId,
               let s = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))),
               let utf8 = s.data(using: .utf8) {
                bytes = utf8
            }
        }
        guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [Any], root.count >= 2,
              let list = root[1] as? [Any] else { return [] }
        return list.compactMap { $0 as? String }
    }
}

private actor SuggestionCache {
    private var store: [String: [String]] = [:]
    func get(_ key: String) -> [String]? { store[key] }
    func set(_ key: String, _ value: [String]) {
        if store.count > 500 { store.removeAll() }
        store[key] = value
    }
}
