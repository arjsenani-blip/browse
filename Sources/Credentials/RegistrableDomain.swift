import Foundation

/// A tiny registrable-domain ("eTLD+1") heuristic.
///
/// This is deliberately not a full Public Suffix List implementation. It treats the
/// last label as the public suffix, except for a small built-in set of well-known
/// multi-part suffixes (country second-level domains and shared hosting platforms
/// such as `github.io`), where the suffix is the last two (or three) labels.
/// It errs toward *narrower* matching: an unknown multi-part suffix makes two sites
/// on the same shared suffix look like one registrable domain, so callers also
/// require exact-or-parent host relationships (see `HostMatcher`).
public enum RegistrableDomain {
    /// Multi-label public suffixes. Entries are matched against the trailing labels of a host.
    public static let multiPartSuffixes: Set<String> = [
        // Country second-level domains
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk", "ltd.uk", "plc.uk", "nhs.uk", "sch.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.nz", "org.nz", "net.nz", "govt.nz", "ac.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "gr.jp",
        "co.kr", "or.kr", "ne.kr", "go.kr",
        "com.br", "net.br", "org.br", "gov.br",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "com.hk", "org.hk", "net.hk", "edu.hk", "gov.hk",
        "com.tw", "org.tw", "net.tw", "edu.tw",
        "com.sg", "org.sg", "edu.sg", "gov.sg",
        "co.in", "net.in", "org.in", "firm.in", "gen.in", "ind.in", "ac.in", "gov.in",
        "co.za", "org.za", "gov.za", "ac.za",
        "com.mx", "org.mx", "gob.mx",
        "com.ar", "com.tr", "com.ua", "com.pl", "com.my", "com.ph", "com.vn", "com.eg", "com.sa",
        "co.il", "org.il", "ac.il", "co.id", "or.id", "ac.id", "co.th", "in.th", "ac.th",
        "com.co", "com.pe", "com.ve", "com.ng", "co.ke",
        "gv.at", "co.at", "or.at",
        // Shared hosting / platform suffixes (each subdomain is a different owner)
        "github.io", "gitlab.io", "githubusercontent.com", "herokuapp.com", "vercel.app",
        "netlify.app", "pages.dev", "workers.dev", "web.app", "firebaseapp.com",
        "appspot.com", "blogspot.com", "azurewebsites.net", "cloudfront.net",
        "s3.amazonaws.com", "fly.dev", "onrender.com", "glitch.me", "repl.co",
        "ngrok.io", "ngrok-free.app", "surge.sh", "bitbucket.io", "readthedocs.io",
        "wordpress.com", "tumblr.com", "myshopify.com", "carrd.co", "neocities.org",
        "translate.goog", "duckdns.org", "dyndns.org", "no-ip.org",
    ]

    /// Lowercases, trims whitespace and a trailing dot, strips brackets from IPv6 literals.
    public static func normalize(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        return h
    }

    /// True for IPv4/IPv6 literals (which have no registrable domain).
    public static func isIPAddress(_ host: String) -> Bool {
        let h = normalize(host)
        if h.contains(":") { return true } // IPv6
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { p in
            !p.isEmpty && p.count <= 3 && p.allSatisfy(\.isNumber) && (Int(p) ?? 999) <= 255
        }
    }

    /// The public suffix of `host` under this heuristic, or nil for IPs / single labels.
    public static func publicSuffix(of host: String) -> String? {
        let h = normalize(host)
        guard !h.isEmpty, !isIPAddress(h) else { return nil }
        let labels = h.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        // Longest match first (3 labels, e.g. "s3.amazonaws.com"), then 2.
        for n in stride(from: min(3, labels.count), through: 2, by: -1) {
            let candidate = labels.suffix(n).joined(separator: ".")
            if multiPartSuffixes.contains(candidate) { return candidate }
        }
        return labels.last
    }

    /// The registrable domain (eTLD+1), e.g. `login.example.co.uk` → `example.co.uk`.
    /// Returns the normalized host itself for IPs, single-label hosts (`localhost`) and
    /// hosts that *are* a public suffix.
    public static func registrableDomain(of host: String) -> String {
        let h = normalize(host)
        guard let suffix = publicSuffix(of: h), h != suffix else { return h }
        let suffixLabelCount = suffix.split(separator: ".").count
        let labels = h.split(separator: ".")
        guard labels.count > suffixLabelCount else { return h }
        return labels.suffix(suffixLabelCount + 1).joined(separator: ".")
    }
}

/// How a saved credential's host relates to the page host.
public enum HostMatchKind: Int, Sendable, Comparable, Codable {
    /// Same host (treating a leading `www.` as equivalent).
    case exact = 0
    /// The credential was saved for a parent domain of the page host
    /// (saved `example.com`, page `login.example.com`).
    case parentDomain = 1

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum HostMatcher {
    /// Returns how `credentialHost` matches `pageHost`, or nil if it must not be offered.
    /// Never matches across registrable domains, and IP / single-label hosts only match exactly.
    public static func match(credentialHost: String, pageHost: String) -> HostMatchKind? {
        let c = stripWWW(RegistrableDomain.normalize(credentialHost))
        let p = stripWWW(RegistrableDomain.normalize(pageHost))
        guard !c.isEmpty, !p.isEmpty else { return nil }
        if c == p { return .exact }
        if RegistrableDomain.isIPAddress(p) || RegistrableDomain.isIPAddress(c) { return nil }
        let cReg = RegistrableDomain.registrableDomain(of: c)
        let pReg = RegistrableDomain.registrableDomain(of: p)
        guard cReg == pReg else { return nil }
        // The credential host must itself be at least the registrable domain (never a bare suffix).
        guard RegistrableDomain.publicSuffix(of: c) != c else { return nil }
        if p.hasSuffix("." + c) { return .parentDomain }
        return nil
    }

    static func stripWWW(_ h: String) -> String {
        // Only strip when what remains is still a registrable domain or deeper.
        guard h.hasPrefix("www.") else { return h }
        let rest = String(h.dropFirst(4))
        if RegistrableDomain.publicSuffix(of: rest) == rest || !rest.contains(".") { return h }
        return rest
    }
}
