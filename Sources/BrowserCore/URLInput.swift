import Foundation

/// Turns what the user typed into a URL to load: a URL, a bare host, or a search.
public enum URLInput {
    public static func resolve(_ raw: String, searchTemplate: String = "https://duckduckgo.com/?q=%s") -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about", "data"].contains(scheme) {
            return url
        }
        if looksLikeHost(text), let url = URL(string: "https://" + text) {
            return url
        }
        let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? text
        return URL(string: searchTemplate.replacingOccurrences(of: "%s", with: query))
    }

    /// "example.com", "localhost:3000", "10.0.0.1/path" — no spaces, a dot or a port, a plausible TLD.
    static func looksLikeHost(_ text: String) -> Bool {
        guard !text.contains(" ") else { return false }
        let hostPart = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        if hostPart.hasPrefix("localhost") { return true }
        let noPort = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let labels = noPort.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last else { return false }
        if labels.allSatisfy({ Int($0) != nil }) { return labels.count == 4 }
        return tld.count >= 2 && tld.allSatisfy(\.isLetter)
    }
}
