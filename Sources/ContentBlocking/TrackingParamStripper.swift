import Foundation

/// Removes well-known tracking query parameters from navigation URLs.
///
/// Use in `decidePolicyFor navigationAction`: if `clean(_:)` returns a URL, cancel and load it instead.
/// Conservative by design: only parameters whose sole purpose is click/campaign attribution.
public enum TrackingParamStripper {
    /// Parameters removed on every site.
    public static let globalParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "gclsrc", "msclkid", "mc_eid", "mc_cid",
        "igshid", "yclid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking",
        "vero_id", "vero_conv", "oly_anon_id", "oly_enc_id", "ref_src", "s_cid", "twclid", "ttclid",
        "li_fat_id", "mkt_tok", "_gl", "srsltid", "epik", "rb_clickid", "wickedid", "irclickid",
        "ml_subscriber", "ml_subscriber_hash", "_openstat", "cmpid", "sc_cid", "zanpid",
    ]

    /// Parameter-name prefixes removed on every site.
    public static let globalPrefixes = ["utm_", "pk_campaign", "pk_kwd", "pk_source", "pk_medium", "pk_content", "mtm_"]

    /// Site-specific parameters, keyed by registrable-domain label (e.g. "amazon" matches amazon.com, amazon.co.uk).
    public static let siteParameters: [String: Set<String>] = [
        "amazon": ["pd_rd_r", "pd_rd_w", "pd_rd_wg", "pd_rd_p", "pd_rd_i", "pf_rd_r", "pf_rd_p", "pf_rd_s",
                   "pf_rd_t", "pf_rd_i", "pf_rd_m", "_encoding", "content-id", "ref_"],
        "youtube": ["si", "feature", "pp"],
        "youtu": ["si", "feature"],
        "spotify": ["si"],
        "instagram": ["igsh"],
        "reddit": ["share_id", "rdt"],
        "linkedin": ["trackingid", "refid", "lipi", "midtoken", "midsig", "trk", "trkemail"],
        "twitter": ["ref_url"],
        "x": ["ref_url"],
        "tiktok": ["is_from_webapp", "sender_device", "sender_web_id", "_r", "_t"],
        "bing": ["cvid", "form"],
    ]

    /// Domain labels a host's site rules are looked up under (`www.amazon.co.uk` → amazon, co, uk, www).
    static func siteLabels(for host: String) -> [String] {
        host.lowercased().split(separator: ".").map(String.init)
    }

    /// Whether `name` (case-insensitive) is a tracking parameter for `host`.
    public static func isTrackingParameter(_ name: String, host: String?) -> Bool {
        let lower = name.lowercased()
        if globalParameters.contains(lower) { return true }
        if globalPrefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        guard let host else { return false }
        let labels = siteLabels(for: host)
        // Only treat the second-level (or third for ccTLD pairs) label as the site name.
        for label in labels.dropLast() {
            if let params = siteParameters[label], params.contains(lower) { return true }
        }
        return false
    }

    /// The URL without tracking parameters, or `nil` if nothing was removed (or not http/https).
    public static func clean(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems, !items.isEmpty
        else { return nil }
        let host = components.host
        let kept = items.filter { item in
            let name = item.name.removingPercentEncoding ?? item.name
            return !isTrackingParameter(name, host: host)
        }
        guard kept.count != items.count else { return nil }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url
    }
}
