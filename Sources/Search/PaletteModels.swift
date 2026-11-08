import Foundation
import BrowserCore
import Persistence

/// An open tab or a bookmark/favorite as seen by the palette.
public struct PaletteItem: Sendable, Hashable {
    public var id: TabID
    public var title: String
    public var url: URL?
    public init(id: TabID, title: String, url: URL?) {
        self.id = id
        self.title = title
        self.url = url
    }
}

/// A palette action ("verb-first", with aliases).
public struct PaletteCommand: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var aliases: [String]
    /// Display string, e.g. "⌘⇧T".
    public var shortcut: String?
    /// SF Symbol name.
    public var icon: String
    public init(id: String, title: String, aliases: [String] = [], shortcut: String? = nil, icon: String = "command") {
        self.id = id
        self.title = title
        self.aliases = aliases
        self.shortcut = shortcut
        self.icon = icon
    }
}

public enum PaletteSection: String, Sendable, CaseIterable, Hashable {
    case switchToTab, bookmarks, history, actions, search

    public var label: String {
        switch self {
        case .switchToTab: "Switch to Tab"
        case .bookmarks: "Bookmarks"
        case .history: "History"
        case .actions: "Actions"
        case .search: "Search"
        }
    }
}

public enum PaletteAction: Sendable, Hashable {
    case switchToTab(TabID)
    case open(URL)
    case command(String)
    /// "Go to …": the typed text resolved as a URL.
    case goTo(URL)
    /// "Search the web for …": the query and the search-engine URL.
    case search(String, URL?)
}

/// What the palette restricts itself to, from the input prefix.
public enum PaletteScope: Sendable, Hashable {
    case all
    /// `>`
    case commands
    /// `@tabs `
    case tabs
    /// `@history `
    case history
    /// `@bookmarks `
    case bookmarks
}

public struct PaletteResult: Sendable, Hashable, Identifiable {
    /// Stable within a query (for list diffing): e.g. "tab:<uuid>", "url:<url>", "cmd:<id>", "search".
    public var id: String
    public var section: PaletteSection
    public var title: String
    public var subtitle: String?
    public var url: URL?
    public var tabID: TabID?
    public var commandID: String?
    /// SF Symbol name.
    public var icon: String?
    public var shortcut: String?
    /// Matched UTF-8 byte ranges in `title` / `subtitle`; convert with `String.indexRanges(utf8:)`.
    public var titleMatches: [Range<Int>]
    public var subtitleMatches: [Range<Int>]
    public var score: Double
    /// Only on the first result: the full text the field should show, with the typed text as its
    /// prefix (in the user's casing). The UI selects the part after the caret.
    public var inlineCompletion: String?
    public var action: PaletteAction
}

/// One keystroke's input plus the in-memory sources.
public struct PaletteQuery: Sendable {
    public var text: String
    public var tabs: [PaletteItem]
    public var bookmarks: [PaletteItem]
    public var commands: [PaletteCommand]
    /// True when the edit that produced `text` removed characters (Backspace, Delete, cut).
    public var lastEditWasDeletion: Bool
    /// False when the caret is not at the end of the field; disables inline completion.
    public var caretAtEnd: Bool

    public init(text: String, tabs: [PaletteItem] = [], bookmarks: [PaletteItem] = [], commands: [PaletteCommand] = [],
                lastEditWasDeletion: Bool = false, caretAtEnd: Bool = true) {
        self.text = text
        self.tabs = tabs
        self.bookmarks = bookmarks
        self.commands = commands
        self.lastEditWasDeletion = lastEditWasDeletion
        self.caretAtEnd = caretAtEnd
    }

    /// Scope and the remaining query text.
    public var parsed: (scope: PaletteScope, query: String) {
        let t = text.drop { $0 == " " }
        if t.hasPrefix(">") { return (.commands, String(t.dropFirst()).trimmingCharacters(in: .whitespaces)) }
        let lower = t.lowercased()
        for (prefix, scope) in [("@tabs ", PaletteScope.tabs), ("@history ", .history), ("@bookmarks ", .bookmarks)]
        where lower.hasPrefix(prefix) {
            return (scope, String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
        }
        return (.all, text.trimmingCharacters(in: .whitespaces))
    }
}

/// An immutable, precomputed slice of history for the synchronous pass.
public struct HistorySnapshot: Sendable {
    public struct Entry: Sendable {
        public var hit: HistoryHit
        public var urlString: String
        /// URL without scheme, leading "www." and trailing "/".
        public var display: String
        /// Lowercased host without "www.".
        public var host: String
        public var title: String
    }

    public let entries: [Entry]
    public let inputs: [InputMatch]
    let index: [String: Int]

    public static let empty = HistorySnapshot(hits: [], inputs: [])

    /// `hits` should be ordered by frecency (as `HistoryStore.quickIndexCandidates` returns them).
    public init(hits: [HistoryHit], inputs: [InputMatch]) {
        var entries: [Entry] = []
        entries.reserveCapacity(hits.count)
        var index: [String: Int] = [:]
        for h in hits {
            let s = h.url.absoluteString
            guard index[s] == nil else { continue }
            index[s] = entries.count
            entries.append(Entry(hit: h, urlString: s, display: URLText.display(h.url), host: URLText.host(h.url),
                                 title: h.title ?? ""))
        }
        self.entries = entries
        self.inputs = inputs
        self.index = index
    }

    public func entry(for url: URL?) -> Entry? {
        guard let url, let i = index[url.absoluteString] else { return nil }
        return entries[i]
    }

    /// Adaptive weights for `query` (lowercased): url string → max use, doubled on an exact input match.
    func adaptive(for query: String) -> [String: Double] {
        guard !query.isEmpty else { return [:] }
        var out: [String: Double] = [:]
        for i in inputs where i.input.hasPrefix(query) {
            let w = i.useCount * (i.input == query ? 2 : 1)
            let k = i.url.absoluteString
            out[k] = max(out[k] ?? 0, w)
        }
        return out
    }
}

enum URLText {
    static func host(_ url: URL) -> String {
        var h = url.host()?.lowercased() ?? ""
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    static func display(_ url: URL) -> String {
        var s = url.absoluteString
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if s.lowercased().hasPrefix("www.") { s.removeFirst(4) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
