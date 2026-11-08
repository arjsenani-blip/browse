import Foundation

/// Why a source filter was not converted into a WebKit content rule.
public enum SkipReason: String, Sendable, Hashable, CaseIterable, Codable {
    /// `/regex/` filter using constructs WebKit's regex subset can't express (alternation, `{n}`, `\b`, lookarounds...).
    case regexUnsupported = "regex-unsupported"
    /// `$redirect`, `$redirect-rule`, `$rewrite`.
    case redirect
    /// `$removeparam` / `$queryprune`.
    case removeparam
    /// `$csp`, `$permissions`.
    case csp
    /// `$replace`, `$urltransform`.
    case replace
    /// `##+js(...)`, `#$#` snippets, `#%#` scripts.
    case scriptlet
    /// `#?#`, `:has-text`, `:upward`, `:xpath`, `:style()`, `:remove()`...
    case proceduralCosmetic = "procedural-cosmetic"
    /// `##^` HTML filtering.
    case htmlFilter = "html-filter"
    /// Any other option WebKit can't express (`$denyallow`, `$header`, `$method`, `$to`, `$genericblock`...).
    case unsupportedOption = "unsupported-option"
    /// Only resource types WebKit doesn't have (e.g. `$webrtc`), or a negation that leaves nothing.
    case unsupportedResourceType = "unsupported-resource-type"
    /// Non-ASCII characters in a URL pattern or domain (would need punycode / percent-encoding).
    case nonASCII = "non-ascii"
    /// Disabled by a matching `$badfilter` rule (or is the `$badfilter` rule itself).
    case badfilter
    /// Cosmetic selector that looks malformed.
    case invalidSelector = "invalid-selector"
    /// Only entity domains like `google.*`, which WebKit can't match.
    case entityDomain = "entity-domain"
    /// `$document` / `$elemhide` / `$generichide` exception whose pattern isn't a plain `||domain^`.
    case unsupportedException = "unsupported-exception"
    /// A rule that would block every request (empty pattern and no constraint).
    case tooBroad = "too-broad"
    /// Unparseable line.
    case malformed
}

/// One WebKit content-blocker rule (trigger + action), serialized to Apple's JSON format.
struct ContentRule: Sendable, Hashable {
    enum Action: String, Sendable, Hashable {
        case block
        case cssDisplayNone = "css-display-none"
        case ignorePreviousRules = "ignore-previous-rules"
    }

    var action: Action
    var selector: String? = nil
    var urlFilter: String
    var caseSensitive = false
    var resourceTypes: [String]? = nil
    var loadTypes: [String]? = nil
    var ifDomain: [String]? = nil
    var unlessDomain: [String]? = nil
    var loadContext: [String]? = nil

    /// Keys this converter may emit; a subset of what WebKit accepts.
    static let allowedTriggerKeys: Set<String> = [
        "url-filter", "url-filter-is-case-sensitive", "resource-type", "load-type",
        "if-domain", "unless-domain", "load-context", "if-top-url", "unless-top-url",
        "top-url-filter-is-case-sensitive", "if-frame-url", "unless-frame-url",
    ]
    static let allowedActionKeys: Set<String> = ["type", "selector"]
    static let allowedActionTypes: Set<String> = [
        "block", "block-cookies", "css-display-none", "ignore-previous-rules", "make-https", "notify", "redirect", "modify-headers",
    ]
    /// Apple's resource-type vocabulary.
    static let appleResourceTypes: Set<String> = [
        "document", "image", "style-sheet", "script", "font", "raw", "svg-document",
        "media", "popup", "ping", "fetch", "websocket", "other",
    ]

    func appendJSON(to out: inout String) {
        out += "{\"trigger\":{\"url-filter\":"
        appendJSONString(urlFilter, to: &out)
        if caseSensitive { out += ",\"url-filter-is-case-sensitive\":true" }
        if let resourceTypes { out += ",\"resource-type\":"; appendJSONArray(resourceTypes, to: &out) }
        if let loadTypes { out += ",\"load-type\":"; appendJSONArray(loadTypes, to: &out) }
        if let ifDomain { out += ",\"if-domain\":"; appendJSONArray(ifDomain, to: &out) }
        if let unlessDomain { out += ",\"unless-domain\":"; appendJSONArray(unlessDomain, to: &out) }
        if let loadContext { out += ",\"load-context\":"; appendJSONArray(loadContext, to: &out) }
        out += "},\"action\":{\"type\":\""
        out += action.rawValue
        out += "\""
        if let selector { out += ",\"selector\":"; appendJSONString(selector, to: &out) }
        out += "}}"
    }

    var json: String {
        var s = ""
        appendJSON(to: &s)
        return s
    }
}

func appendJSONArray(_ values: [String], to out: inout String) {
    out += "["
    for (i, v) in values.enumerated() {
        if i > 0 { out += "," }
        appendJSONString(v, to: &out)
    }
    out += "]"
}

func appendJSONString(_ s: String, to out: inout String) {
    out += "\""
    var needsEscape = false
    for b in s.utf8 where b == 0x22 || b == 0x5C || b < 0x20 {
        needsEscape = true
        break
    }
    if !needsEscape {
        out += s
    } else {
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
    }
    out += "\""
}

/// Serializes rules into a JSON array string.
func encodeRuleList(_ rules: [ContentRule]) -> String {
    var out = "["
    out.reserveCapacity(rules.count * 120)
    for (i, rule) in rules.enumerated() {
        if i > 0 { out += ",\n" }
        rule.appendJSON(to: &out)
    }
    out += "]"
    return out
}
