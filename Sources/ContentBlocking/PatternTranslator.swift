import Foundation

/// Converts Adblock Plus URL patterns into the regex subset accepted by WebKit's `url-filter`.
///
/// WebKit supports: `.`, character classes `[...]` / `[^...]` with ranges, `*` `+` `?` on a single
/// atom or a group, groups `(...)`, `^` only at the start and `$` only at the end, and backslash
/// escapes. No alternation, no `{n,m}`, no `\d`/`\b`/lookarounds, ASCII only.
public enum PatternTranslator {
    /// `||` → scheme + optional subdomains.
    public static let hostAnchorPrefix = "^[^:]+://+([^:/]+\\.)?"
    /// ABP `^`: any character except a letter, digit, `_`, `-`, `.`, `%`. WebKit normalizes URLs
    /// so a host is always followed by `/`, so `||example.com^` still matches `https://example.com`.
    public static let separatorClass = "[^-a-zA-Z0-9_.%]"

    public enum Translation: Equatable, Sendable {
        case filter(String)
        case skip(SkipReason)
    }

    /// Translate an ABP network pattern (without `@@` and `$options`).
    public static func translate(_ pattern: String) -> Translation {
        // Regex filter: /.../
        if pattern.count > 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
            return translateRegex(String(pattern.dropFirst().dropLast()))
        }

        var bytes = Array(pattern.utf8)
        var out = ""
        out.reserveCapacity(bytes.count + 24)

        var hostAnchored = false
        var startAnchored = false
        var endAnchored = false

        if bytes.count >= 2, bytes[0] == UInt8(ascii: "|"), bytes[1] == UInt8(ascii: "|") {
            hostAnchored = true
            bytes.removeFirst(2)
        } else if bytes.first == UInt8(ascii: "|") {
            startAnchored = true
            bytes.removeFirst()
        }
        if bytes.last == UInt8(ascii: "|") {
            endAnchored = true
            bytes.removeLast()
        }

        if hostAnchored {
            out += hostAnchorPrefix
        } else if startAnchored {
            out += "^"
        }

        var inHost = hostAnchored
        for b in bytes {
            if b >= 0x80 { return .skip(.nonASCII) }
            if b < 0x20 { return .skip(.malformed) }
            switch b {
            case UInt8(ascii: "*"):
                if !out.hasSuffix(".*") { out += ".*" }
                inHost = false
            case UInt8(ascii: "^"):
                out += separatorClass
                inHost = false
            case UInt8(ascii: "."), UInt8(ascii: "+"), UInt8(ascii: "?"), UInt8(ascii: "("),
                 UInt8(ascii: ")"), UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"),
                 UInt8(ascii: "}"), UInt8(ascii: "$"), UInt8(ascii: "\\"), UInt8(ascii: "|"):
                if b == UInt8(ascii: "?") { inHost = false }
                out += "\\"
                out.unicodeScalars.append(Unicode.Scalar(b))
            case UInt8(ascii: "/"), UInt8(ascii: ":"):
                inHost = false
                out.unicodeScalars.append(Unicode.Scalar(b))
            default:
                var c = b
                if inHost, c >= UInt8(ascii: "A"), c <= UInt8(ascii: "Z") { c += 32 }
                out.unicodeScalars.append(Unicode.Scalar(c))
            }
        }

        // Trim redundant wildcards; url-filter is a search, not a full match.
        if !hostAnchored && !startAnchored {
            while out.hasPrefix(".*") { out.removeFirst(2) }
        }
        if out.hasSuffix(".*") && !out.hasSuffix("\\.*") {
            out.removeLast(2)
            endAnchored = false
        }
        if endAnchored { out += "$" }
        if out.isEmpty || out == "^" { return .filter(".*") }
        return .filter(out)
    }

    /// Accept a JavaScript-style regex if it only uses features WebKit supports; rewrite `\d`/`\w`.
    static func translateRegex(_ source: String) -> Translation {
        let s = Array(source.utf8)
        var out = ""
        var i = 0
        var inClass = false
        var classStart = false
        while i < s.count {
            let b = s[i]
            if b >= 0x80 { return .skip(.nonASCII) }
            if b == UInt8(ascii: "\\") {
                guard i + 1 < s.count else { return .skip(.regexUnsupported) }
                let n = s[i + 1]
                switch n {
                case UInt8(ascii: "d"): out += inClass ? "0-9" : "[0-9]"
                case UInt8(ascii: "w"): out += inClass ? "A-Za-z0-9_" : "[A-Za-z0-9_]"
                case UInt8(ascii: "/"): out += "/"
                case UInt8(ascii: "."), UInt8(ascii: "?"), UInt8(ascii: "+"), UInt8(ascii: "*"),
                     UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "["), UInt8(ascii: "]"),
                     UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "\\"), UInt8(ascii: "^"),
                     UInt8(ascii: "$"), UInt8(ascii: "|"), UInt8(ascii: "-"), UInt8(ascii: "="),
                     UInt8(ascii: "&"), UInt8(ascii: ":"), UInt8(ascii: "_"), UInt8(ascii: "%"),
                     UInt8(ascii: "#"), UInt8(ascii: "@"), UInt8(ascii: ","), UInt8(ascii: ";"),
                     UInt8(ascii: "!"), UInt8(ascii: "~"), UInt8(ascii: "'"), UInt8(ascii: "\""):
                    out += "\\"
                    out.unicodeScalars.append(Unicode.Scalar(n))
                default:
                    // \b \s \S \D \W \B backreferences, \u escapes, etc.
                    return .skip(.regexUnsupported)
                }
                i += 2
                classStart = false
                continue
            }
            if inClass {
                if b == UInt8(ascii: "]") && !classStart { inClass = false }
                if b == UInt8(ascii: "[") { return .skip(.regexUnsupported) }
                classStart = false
                out.unicodeScalars.append(Unicode.Scalar(b))
                i += 1
                continue
            }
            switch b {
            case UInt8(ascii: "|"), UInt8(ascii: "{"), UInt8(ascii: "}"):
                return .skip(.regexUnsupported)
            case UInt8(ascii: "("):
                if i + 1 < s.count, s[i + 1] == UInt8(ascii: "?") { return .skip(.regexUnsupported) }
            case UInt8(ascii: "["):
                inClass = true
                classStart = true
                out += "["
                i += 1
                if i < s.count, s[i] == UInt8(ascii: "^") { out += "^"; i += 1 }
                continue
            case UInt8(ascii: "^"):
                if i != 0 { return .skip(.regexUnsupported) }
            case UInt8(ascii: "$"):
                if i != s.count - 1 { return .skip(.regexUnsupported) }
            case UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "?"):
                // Lazy / possessive quantifiers.
                if i + 1 < s.count, [UInt8(ascii: "?"), UInt8(ascii: "+")].contains(s[i + 1]) {
                    return .skip(.regexUnsupported)
                }
                if i == 0 { return .skip(.regexUnsupported) }
            default:
                break
            }
            out.unicodeScalars.append(Unicode.Scalar(b))
            i += 1
        }
        if inClass || out.isEmpty { return .skip(.regexUnsupported) }
        return .filter(out)
    }
}
