import Foundation
@testable import ContentBlocking

/// Parses a converted JSON list into dictionaries.
func parseRules(_ json: String) throws -> [[String: Any]] {
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
    guard let rules = object as? [[String: Any]] else { throw CocoaError(.coderReadCorrupt) }
    return rules
}

func allRules(_ result: ConversionResult) throws -> [[String: Any]] {
    try result.lists.flatMap(parseRules)
}

func trigger(_ rule: [String: Any]) -> [String: Any] { rule["trigger"] as? [String: Any] ?? [:] }
func action(_ rule: [String: Any]) -> [String: Any] { rule["action"] as? [String: Any] ?? [:] }
func actionType(_ rule: [String: Any]) -> String { action(rule)["type"] as? String ?? "" }
func urlFilter(_ rule: [String: Any]) -> String { trigger(rule)["url-filter"] as? String ?? "" }

/// Returns a description of the first rule using keys/values WebKit doesn't support, or nil.
func invalidKeyProblem(_ rules: [[String: Any]]) -> String? {
    for rule in rules {
        guard Set(rule.keys) == ["trigger", "action"] else { return "top-level keys \(rule.keys)" }
        let t = trigger(rule), a = action(rule)
        if let bad = Set(t.keys).subtracting(ContentRule.allowedTriggerKeys).first { return "trigger key \(bad)" }
        if let bad = Set(a.keys).subtracting(ContentRule.allowedActionKeys).first { return "action key \(bad)" }
        guard let type = a["type"] as? String, ContentRule.allowedActionTypes.contains(type) else { return "action type \(a)" }
        if type == "css-display-none" && a["selector"] == nil { return "css rule without selector" }
        guard let filter = t["url-filter"] as? String, !filter.isEmpty else { return "missing url-filter" }
        if filter.utf8.contains(where: { $0 >= 0x80 }) { return "non-ASCII url-filter \(filter)" }
        if t["if-domain"] != nil && t["unless-domain"] != nil { return "both if-domain and unless-domain" }
        if let types = t["resource-type"] as? [String] {
            if types.isEmpty { return "empty resource-type" }
            if let bad = Set(types).subtracting(ContentRule.appleResourceTypes).first { return "resource type \(bad)" }
        }
        if let lt = t["load-type"] as? [String], !Set(lt).isSubset(of: ["first-party", "third-party"]) { return "load-type \(lt)" }
        if let lc = t["load-context"] as? [String], !Set(lc).isSubset(of: ["top-frame", "child-frame"]) { return "load-context \(lc)" }
        for key in ["if-domain", "unless-domain"] {
            if let domains = t[key] as? [String] {
                if domains.isEmpty { return "empty \(key)" }
                for d in domains where d != d.lowercased() || d.utf8.contains(where: { $0 >= 0x80 }) { return "\(key) \(d)" }
            }
        }
    }
    return nil
}

/// Matches a WebKit url-filter against a URL using ICU (the WebKit subset is valid ICU regex).
func filterMatches(_ filter: String, _ url: String, caseSensitive: Bool = false) -> Bool {
    guard let re = try? NSRegularExpression(pattern: filter, options: caseSensitive ? [] : [.caseInsensitive]) else {
        return false
    }
    return re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
}

func urlFilter(for pattern: String) -> String? {
    if case .filter(let f) = PatternTranslator.translate(pattern) { return f }
    return nil
}

func bundledList(_ name: String) -> String? {
    guard let dir = FilterListManager.bundledDirectory else { return nil }
    return try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
}
