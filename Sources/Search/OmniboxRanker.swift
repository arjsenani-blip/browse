import Foundation
import BrowserCore
import Persistence

/// Scores and groups palette candidates from every source.
///
/// `score = fuzzy × (1 + log1p(frecency)) + adaptiveBoost + sourceBoost`, where a host-prefix match
/// doubles the fuzzy term and adds `hostPrefixBoost`, so it beats a title-only match of similar
/// standing. Sections are ordered by their best score (the first row is the top hit); the search
/// section ("Go to …", "Search the web for …") comes last, or first when the input looks like a URL
/// and nothing matches it by host prefix.
public struct OmniboxRanker: Sendable {
    public var sourceBoostTab: Double = 60
    public var sourceBoostBookmark: Double = 40
    public var sourceBoostHistory: Double = 20
    public var sourceBoostCommand: Double = 0
    public var hostPrefixBoost: Double = 100
    /// Per unit of adaptive `use` (which converges to 10; ×2 on exact input).
    public var adaptiveWeight: Double = 100
    /// Rows per section when unscoped.
    public var sectionLimit = 3
    /// Rows when scoped (`>`, `@tabs `, …).
    public var scopedLimit = 50
    /// History rows shown for an empty query.
    public var emptyQueryTopSites = 6
    /// The Settings choice unless a caller (tests) pins one.
    public var searchTemplate: String {
        get { pinnedSearchTemplate ?? SearchEngine.current.template }
        set { pinnedSearchTemplate = newValue }
    }
    private var pinnedSearchTemplate: String?

    public init() {}

    // MARK: Candidates

    private struct Candidate {
        var section: PaletteSection
        var id: String
        var title: String
        var subtitle: String?
        var url: URL?
        var tabID: TabID?
        var commandID: String?
        var icon: String?
        var shortcut: String?
        var score: Double
        var action: PaletteAction
        var hostPrefix: Bool
        var display: String
        var host: String
        var typedCount: Int
    }

    /// Ranks everything. `extraHits` are FTS results from the async pass, merged into the snapshot.
    public func rank(_ query: PaletteQuery, snapshot: HistorySnapshot, extraHits: [HistoryHit] = []) -> [PaletteResult] {
        let (scope, text) = query.parsed
        let q = text.lowercased()
        let terms = q.split(whereSeparator: \.isWhitespace).map { FuzzyPattern(String($0)) }
        let matcher = FuzzyMatcher()
        let adaptive = snapshot.adaptive(for: q)
        let qHasSpace = q.contains(where: \.isWhitespace)
        let qHasSlash = q.contains("/")

        let limit = scope == .all ? sectionLimit : scopedLimit
        // Per-section bounded lists, sorted by score (desc, stable on ties).
        var bySection: [PaletteSection: [Candidate]] = [:]
        var anyHostPrefix = false
        var seenURLs = Set<String>()

        func admits(_ section: PaletteSection, _ score: Double) -> Bool {
            guard let list = bySection[section], list.count >= limit else { return true }
            return score > list[list.count - 1].score
        }
        func add(_ c: Candidate) {
            if c.hostPrefix { anyHostPrefix = true }
            guard admits(c.section, c.score) else { return }
            var list = bySection[c.section] ?? []
            let i = list.firstIndex { $0.score < c.score } ?? list.count
            list.insert(c, at: i)
            if list.count > limit { list.removeLast() }
            bySection[c.section] = list
        }

        func fuzzy(_ a: String, _ b: String) -> Int? {
            if terms.isEmpty { return 0 }
            let x = a.isEmpty ? nil : matcher.matchTerms(terms, in: a, withPositions: false)?.score
            let y = b.isEmpty ? nil : matcher.matchTerms(terms, in: b, withPositions: false)?.score
            switch (x, y) {
            case let (x?, y?): return max(x, y)
            case let (x?, nil): return x
            case let (nil, y?): return y
            default: return nil
            }
        }
        func fuzzy(_ strings: [String]) -> Int? {
            if terms.isEmpty { return 0 }
            return strings.compactMap { $0.isEmpty ? nil : matcher.matchTerms(terms, in: $0, withPositions: false)?.score }.max()
        }

        func isHostPrefix(host: String, display: String) -> Bool {
            !q.isEmpty && !qHasSpace && (host.hasPrefix(q) || (qHasSlash && display.lowercased().hasPrefix(q)))
        }

        func webScore(fuzzy f: Int, url: URL?, display: String, host: String, frecency: Double,
                      adaptiveUse: Double, boost: Double) -> (Double, Bool) {
            let hp = url != nil && isHostPrefix(host: host, display: display)
            var fuzzyPart = Double(f) * (1 + log1p(max(0, frecency)))
            if hp { fuzzyPart = fuzzyPart * 2 + hostPrefixBoost }
            return (fuzzyPart + adaptiveUse * adaptiveWeight + boost, hp)
        }

        // Open tabs.
        if scope == .all || scope == .tabs {
            for (i, t) in query.tabs.enumerated() {
                let display = t.url.map(URLText.display) ?? ""
                let host = t.url.map(URLText.host) ?? ""
                guard let f = fuzzy(t.title, display) else { continue }
                let e = snapshot.entry(for: t.url)
                let key = t.url?.absoluteString ?? ""
                var (s, hp) = webScore(fuzzy: f, url: t.url, display: display, host: host,
                                       frecency: e?.hit.frecency ?? 0, adaptiveUse: adaptive[key] ?? 0, boost: sourceBoostTab)
                if terms.isEmpty { s = Double(query.tabs.count - i) } // keep caller's order
                if !key.isEmpty { seenURLs.insert(key) }
                add(Candidate(section: .switchToTab, id: "tab:\(t.id)", title: t.title.isEmpty ? display : t.title,
                                            subtitle: display.isEmpty ? nil : display, url: t.url, tabID: t.id, commandID: nil,
                                            icon: "rectangle.on.rectangle", shortcut: nil, score: s, action: .switchToTab(t.id),
                                            hostPrefix: hp, display: display, host: host, typedCount: e?.hit.typedCount ?? 0))
            }
        }

        // Bookmarks / favorites.
        if (scope == .all && !terms.isEmpty) || scope == .bookmarks {
            for b in query.bookmarks {
                guard let url = b.url else { continue }
                let key = url.absoluteString
                if seenURLs.contains(key) { continue }
                let display = URLText.display(url), host = URLText.host(url)
                guard let f = fuzzy(b.title, display) else { continue }
                let e = snapshot.entry(for: url)
                let (s, hp) = webScore(fuzzy: f, url: url, display: display, host: host, frecency: e?.hit.frecency ?? 0,
                                       adaptiveUse: adaptive[key] ?? 0, boost: sourceBoostBookmark)
                seenURLs.insert(key)
                add(Candidate(section: .bookmarks, id: "url:\(key)", title: b.title.isEmpty ? display : b.title,
                                            subtitle: display, url: url, tabID: b.id, commandID: nil, icon: "star",
                                            shortcut: nil, score: s, action: .open(url), hostPrefix: hp, display: display,
                                            host: host, typedCount: e?.hit.typedCount ?? 0))
            }
        }

        // History: FTS hits first (they carry adaptiveUse from SQL), then the cached slice.
        if scope == .all || scope == .history {
            func addHistory(_ hit: HistoryHit, key: String, display: String, host: String, title: String, fallbackFuzzy: Int?) {
                guard let f = fuzzy(title, display) ?? fallbackFuzzy else { return }
                guard seenURLs.insert(key).inserted else { return }
                let a = max(adaptive[key] ?? 0, hit.adaptiveUse)
                let (s, hp) = webScore(fuzzy: f, url: hit.url, display: display, host: host, frecency: hit.frecency,
                                       adaptiveUse: a, boost: sourceBoostHistory)
                if hp { anyHostPrefix = true }
                guard admits(.history, s) else { return }
                add(Candidate(section: .history, id: "url:\(key)", title: title.isEmpty ? display : title,
                                            subtitle: display, url: hit.url, tabID: nil, commandID: nil, icon: "clock",
                                            shortcut: nil, score: s, action: .open(hit.url), hostPrefix: hp, display: display,
                                            host: host, typedCount: hit.typedCount))
            }
            if terms.isEmpty {
                for e in snapshot.entries.prefix(scope == .history ? scopedLimit : emptyQueryTopSites) {
                    addHistory(e.hit, key: e.urlString, display: e.display, host: e.host, title: e.title, fallbackFuzzy: nil)
                }
            } else {
                for h in extraHits {
                    addHistory(h, key: h.url.absoluteString, display: URLText.display(h.url), host: URLText.host(h.url), title: h.title ?? "",
                               fallbackFuzzy: q.count * 8)
                }
                for e in snapshot.entries {
                    addHistory(e.hit, key: e.urlString, display: e.display, host: e.host, title: e.title, fallbackFuzzy: nil)
                }
            }
        }

        // Commands.
        if (scope == .all && !terms.isEmpty) || scope == .commands {
            for (i, c) in query.commands.enumerated() {
                guard let f = fuzzy([c.title] + c.aliases) else { continue }
                let s = terms.isEmpty ? Double(query.commands.count - i) : Double(f) + sourceBoostCommand
                add(Candidate(section: .actions, id: "cmd:\(c.id)", title: c.title, subtitle: nil, url: nil,
                                            tabID: nil, commandID: c.id, icon: c.icon, shortcut: c.shortcut, score: s,
                                            action: .command(c.id), hostPrefix: false, display: "", host: "", typedCount: 0))
            }
        }

        // Order sections by their best row.
        var groups: [[Candidate]] = Array(bySection.values)
        groups.sort { ($0.first?.score ?? 0) > ($1.first?.score ?? 0) }

        var results: [PaletteResult] = []
        for g in groups {
            for c in g { results.append(makeResult(c, terms: terms, matcher: matcher)) }
        }

        // Inline completion on the top hit.
        if let top = groups.first?.first,
           let completion = inlineCompletion(for: top, typed: text, query: q, snapshot: snapshot,
                                             lastEditWasDeletion: query.lastEditWasDeletion, caretAtEnd: query.caretAtEnd) {
            results[0].inlineCompletion = completion
        }

        // Search rows (unscoped, non-empty input only).
        if scope == .all && !text.isEmpty {
            var search: [PaletteResult] = []
            if Self.looksLikeURL(text), let url = URLInput.resolve(text) {
                search.append(PaletteResult(id: "goto", section: .search, title: "Go to \(text)", subtitle: url.absoluteString,
                                            url: url, tabID: nil, commandID: nil, icon: "globe", shortcut: nil,
                                            titleMatches: [], subtitleMatches: [], score: 0, inlineCompletion: nil,
                                            action: .goTo(url)))
            }
            let searchURL = searchURL(for: text)
            search.append(PaletteResult(id: "search", section: .search, title: "Search the web for \u{201C}\(text)\u{201D}",
                                        subtitle: nil, url: searchURL, tabID: nil, commandID: nil, icon: "magnifyingglass",
                                        shortcut: nil, titleMatches: [], subtitleMatches: [], score: 0,
                                        inlineCompletion: nil, action: .search(text, searchURL)))
            let urlLike = Self.looksLikeURL(text)
            if urlLike && !anyHostPrefix {
                // Typed a URL nothing knows: "Go to" is the default action.
                if !results.isEmpty { results[0].inlineCompletion = nil }
                results = search + results
            } else {
                results += search
            }
        }
        return results
    }

    private func makeResult(_ c: Candidate, terms: [FuzzyPattern], matcher: FuzzyMatcher) -> PaletteResult {
        var titleMatches: [Range<Int>] = []
        var subtitleMatches: [Range<Int>] = []
        if !terms.isEmpty {
            if let m = matcher.matchTerms(terms, in: c.title) { titleMatches = m.ranges }
            if let sub = c.subtitle, let m = matcher.matchTerms(terms, in: sub) { subtitleMatches = m.ranges }
        }
        return PaletteResult(id: c.id, section: c.section, title: c.title, subtitle: c.subtitle, url: c.url, tabID: c.tabID,
                             commandID: c.commandID, icon: c.icon, shortcut: c.shortcut, titleMatches: titleMatches,
                             subtitleMatches: subtitleMatches, score: c.score, inlineCompletion: nil, action: c.action)
    }

    /// Rules (research doc): top result only; typed text is a prefix of the host (ignoring "www.") or
    /// an adaptive key for that URL; typed_count ≥ 1; never after a deletion or with the caret not at the end.
    private func inlineCompletion(for top: Candidate, typed: String, query q: String, snapshot: HistorySnapshot,
                                  lastEditWasDeletion: Bool, caretAtEnd: Bool) -> String? {
        guard !lastEditWasDeletion, caretAtEnd, !q.isEmpty, !q.contains(where: \.isWhitespace),
              let url = top.url, top.typedCount >= 1 else { return nil }
        let display = top.display.lowercased()
        var completion: String?
        if !q.contains("/"), top.host.hasPrefix(q) {
            completion = top.host
        } else if display.hasPrefix(q) {
            let key = url.absoluteString
            let adaptiveKey = snapshot.inputs.contains { $0.url.absoluteString == key && $0.input.hasPrefix(q) }
            if top.host.hasPrefix(q) || q.hasPrefix(top.host) || adaptiveKey { completion = display }
        }
        guard let completion, completion.count > typed.count else { return nil }
        return typed + completion.dropFirst(typed.count)
    }

    /// The search-engine URL for `text`, even when `text` looks like a URL.
    public func searchURL(for text: String) -> URL? {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))
        let q = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        return URL(string: searchTemplate.replacingOccurrences(of: "%s", with: q))
    }

    // MARK: URL detection

    /// True for "https://…", "about:…", "example.com", "localhost:3000", "10.0.0.1/path".
    public static func looksLikeURL(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains(" ") else { return false }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about"].contains(scheme), text.contains(":") {
            if scheme == "about" || text.contains("://") { return true }
        }
        let hostPart = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        if hostPart.lowercased().hasPrefix("localhost") { return true }
        let noPort = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let labels = noPort.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), let tld = labels.last else { return false }
        if labels.allSatisfy({ Int($0) != nil }) { return labels.count == 4 }
        return tld.count >= 2 && tld.allSatisfy(\.isLetter)
    }
}
