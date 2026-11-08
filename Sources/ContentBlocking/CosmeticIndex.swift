import Foundation

/// Per-domain element-hiding data produced by the converter, used by `CosmeticScript` to
/// inject CSS for what content rules can't express (and for an optional script-only mode).
public struct CosmeticIndex: Sendable, Codable, Equatable {
    public struct Entry: Sendable, Codable, Equatable, Hashable {
        public var selector: String
        /// Subdomains (of the key domain) where this selector must not apply.
        public var excludes: [String]
        /// `true` when a WebKit content rule already hides this selector.
        public var coveredByContentRules: Bool
    }

    /// How much CSS `selectors(for:mode:)` returns.
    public enum Mode: Sendable {
        /// Only selectors that content rules couldn't express (the normal mode).
        case supplement
        /// Everything that applies to the host, including generic selectors (no content rules).
        case full
    }

    /// Domain-specific selectors keyed by the (lowercased) domain they apply to.
    public var byDomain: [String: [Entry]] = [:]
    /// Generic selectors (applied everywhere unless a domain has an exception or `$generichide`).
    public var genericSelectors: [String] = []
    /// Generic selector → domains where an `example.com#@#selector` exception disables it.
    public var genericExceptions: [String: [String]] = [:]
    /// Domains with `@@||domain^$generichide`.
    public var genericHideDomains: Set<String> = []
    /// Domains with `@@||domain^$elemhide` or `$document` (no cosmetic filtering at all).
    public var elemHideDomains: Set<String> = []

    public init() {}

    /// Suffixes of `host` from most to least specific: `a.b.com` → `a.b.com`, `b.com`, `com`.
    static func suffixes(of host: String) -> [String] {
        var host = host.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        var result = [host]
        var rest = Substring(host)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            if !rest.isEmpty { result.append(String(rest)) }
        }
        return result
    }

    /// The selectors to hide on `host`.
    public func selectors(for host: String, mode: Mode = .supplement) -> [String] {
        let suffixes = Self.suffixes(of: host)
        if suffixes.contains(where: elemHideDomains.contains) { return [] }
        let suffixSet = Set(suffixes)
        var seen = Set<String>()
        var result: [String] = []
        for domain in suffixes {
            guard let entries = byDomain[domain] else { continue }
            for entry in entries {
                if mode == .supplement && entry.coveredByContentRules { continue }
                if entry.excludes.contains(where: suffixSet.contains) { continue }
                if seen.insert(entry.selector).inserted { result.append(entry.selector) }
            }
        }
        if mode == .full && !suffixes.contains(where: genericHideDomains.contains) {
            for selector in genericSelectors where seen.insert(selector).inserted {
                result.append(selector)
            }
            for (selector, domains) in genericExceptions where !domains.contains(where: suffixSet.contains) {
                if seen.insert(selector).inserted { result.append(selector) }
            }
        }
        return result
    }

    /// Domain → CSS for selectors that content rules don't cover.
    public var cosmeticCSSByDomain: [String: String] {
        var out: [String: String] = [:]
        for (domain, entries) in byDomain {
            let selectors = entries.filter { !$0.coveredByContentRules }.map(\.selector)
            if !selectors.isEmpty { out[domain] = CosmeticScript.css(for: selectors) }
        }
        return out
    }
}
