import Foundation

/// A history row returned by queries. `frecency` is the *live* score at query time
/// (see `Frecency` for the stored form).
public struct HistoryHit: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var url: URL
    public var title: String?
    public var host: String
    public var frecency: Double
    public var visitCount: Int
    public var typedCount: Int
    public var lastVisit: Date
    /// Adaptive-history weight for the query that produced this hit: the max `use_count` over
    /// stored inputs that start with the query, doubled when the input equals the query exactly.
    /// 0 for non-search queries.
    public var adaptiveUse: Double

    public init(id: Int64, url: URL, title: String?, host: String, frecency: Double, visitCount: Int,
                typedCount: Int, lastVisit: Date, adaptiveUse: Double = 0) {
        self.id = id
        self.url = url
        self.title = title
        self.host = host
        self.frecency = frecency
        self.visitCount = visitCount
        self.typedCount = typedCount
        self.lastVisit = lastVisit
        self.adaptiveUse = adaptiveUse
    }
}

/// One adaptive-history pair: what the user typed and the URL they then picked.
public struct InputMatch: Sendable, Hashable {
    public var input: String
    public var url: URL
    public var title: String?
    public var host: String
    public var useCount: Double
    public var typedCount: Int

    public init(input: String, url: URL, title: String? = nil, host: String = "", useCount: Double, typedCount: Int = 0) {
        self.input = input
        self.url = url
        self.title = title
        self.host = host
        self.useCount = useCount
        self.typedCount = typedCount
    }
}

/// Browsing history: visits, frecency, adaptive input history and FTS5 trigram search.
public actor HistoryStore {
    private let db: Database
    private let now: @Sendable () -> Date
    /// Whether the FTS table was created with `remove_diacritics` (needs SQLite ≥ 3.45).
    public nonisolated let ftsRemovesDiacritics: Bool

    public static let memoryPath = ":memory:"

    /// - Parameter url: a file URL, or `URL(string: ":memory:")` for an in-memory store.
    public init(url: URL, keyProvider: (any DatabaseKeyProvider)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        let path = (url.absoluteString == Self.memoryPath || url.lastPathComponent == Self.memoryPath)
            ? Self.memoryPath : url.path
        try self.init(path: path, keyProvider: keyProvider, now: now)
    }

    public init(path: String, keyProvider: (any DatabaseKeyProvider)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        let db = try Database(path: path, keyProvider: keyProvider)
        self.ftsRemovesDiacritics = try Self.migrate(db)
        self.db = db
        self.now = now
    }

    /// Convenience for tests and private windows.
    public static func inMemory(now: @escaping @Sendable () -> Date = { Date() }) throws -> HistoryStore {
        try HistoryStore(path: memoryPath, now: now)
    }

    // MARK: Schema

    private static func migrate(_ db: Database) throws -> Bool {
        try db.execute("""
        CREATE TABLE IF NOT EXISTS urls(
          id INTEGER PRIMARY KEY, url TEXT NOT NULL UNIQUE, host TEXT NOT NULL DEFAULT '', title TEXT,
          visit_count INT NOT NULL DEFAULT 0, typed_count INT NOT NULL DEFAULT 0,
          last_visit INT NOT NULL DEFAULT 0, frecency REAL NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS visits(
          id INTEGER PRIMARY KEY, url_id INT NOT NULL REFERENCES urls(id) ON DELETE CASCADE,
          ts INT NOT NULL, kind INT NOT NULL, view_ms INT NOT NULL DEFAULT 0, keypresses INT NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS input_history(
          input TEXT NOT NULL, url_id INT NOT NULL REFERENCES urls(id) ON DELETE CASCADE,
          use_count REAL NOT NULL, PRIMARY KEY(input, url_id));
        CREATE INDEX IF NOT EXISTS urls_frecency ON urls(frecency DESC);
        CREATE INDEX IF NOT EXISTS urls_last_visit ON urls(last_visit DESC);
        CREATE INDEX IF NOT EXISTS visits_url_ts ON visits(url_id, ts DESC);
        CREATE INDEX IF NOT EXISTS visits_ts ON visits(ts);
        CREATE INDEX IF NOT EXISTS input_history_url ON input_history(url_id);
        """)
        let exists = try db.queryOne("SELECT sql FROM sqlite_master WHERE name='urls_fts'") { $0.string(0) ?? "" }
        var diacritics: Bool
        if let exists {
            diacritics = exists.contains("remove_diacritics")
        } else {
            let base = "CREATE VIRTUAL TABLE urls_fts USING fts5(title, url, host, content='urls', content_rowid='id', tokenize="
            do {
                try db.execute(base + "'trigram remove_diacritics 1')")
                diacritics = true
            } catch {
                try db.execute(base + "'trigram')")
                diacritics = false
            }
        }
        try db.execute("""
        CREATE TRIGGER IF NOT EXISTS urls_ai AFTER INSERT ON urls BEGIN
          INSERT INTO urls_fts(rowid, title, url, host) VALUES (new.id, new.title, new.url, new.host);
        END;
        CREATE TRIGGER IF NOT EXISTS urls_ad AFTER DELETE ON urls BEGIN
          INSERT INTO urls_fts(urls_fts, rowid, title, url, host) VALUES ('delete', old.id, old.title, old.url, old.host);
        END;
        CREATE TRIGGER IF NOT EXISTS urls_au AFTER UPDATE OF title, url, host ON urls
        WHEN old.title IS NOT new.title OR old.url IS NOT new.url OR old.host IS NOT new.host BEGIN
          INSERT INTO urls_fts(urls_fts, rowid, title, url, host) VALUES ('delete', old.id, old.title, old.url, old.host);
          INSERT INTO urls_fts(rowid, title, url, host) VALUES (new.id, new.title, new.url, new.host);
        END;
        """)
        return diacritics
    }

    // MARK: Writes

    /// Records a visit, bumps counters and recomputes the URL's frecency.
    /// Redirect visits are logged but do not increment `visit_count`.
    public func recordVisit(url: URL, title: String?, kind: VisitKind, at date: Date) throws {
        try db.transaction {
            let id = try upsertURL(url, title: title)
            try db.run("INSERT INTO visits(url_id, ts, kind) VALUES (?, ?, ?)",
                       [.int(id), .int(Self.ms(date)), .int(Int64(kind.rawValue))])
            try db.run("""
                UPDATE urls SET visit_count = visit_count + ?, typed_count = typed_count + ?,
                  last_visit = MAX(last_visit, ?) WHERE id = ?
                """, [.int(kind == .redirect ? 0 : 1), .int(kind == .typed ? 1 : 0), .int(Self.ms(date)), .int(id)])
            try recompute(id: id, at: max(date, now()))
        }
    }

    /// Marks the most recent visit of `url` as engaged (view time / keypresses); may lift its bucket.
    public func recordEngagement(url: URL, viewMs: Int, keypresses: Int) throws {
        guard let id = try urlID(url) else { return }
        try db.transaction {
            try db.run("""
                UPDATE visits SET view_ms = MAX(view_ms, ?), keypresses = MAX(keypresses, ?)
                WHERE id = (SELECT id FROM visits WHERE url_id = ? ORDER BY ts DESC LIMIT 1)
                """, [.int(Int64(viewMs)), .int(Int64(keypresses)), .int(id)])
            try recompute(id: id, at: now())
        }
    }

    public func updateTitle(url: URL, title: String) throws {
        try db.run("UPDATE urls SET title = ? WHERE url = ?", [.text(title), .text(url.absoluteString)])
    }

    /// Adaptive history: the user typed `input` and picked `url`. `use = use·0.9 + 1`.
    public func recordInputChoice(input: String, url: URL) throws {
        let key = Self.normalize(input)
        guard !key.isEmpty else { return }
        try db.transaction {
            let id = try upsertURL(url, title: nil)
            try db.run("""
                INSERT INTO input_history(input, url_id, use_count) VALUES (?, ?, 1)
                ON CONFLICT(input, url_id) DO UPDATE SET use_count = use_count * 0.9 + 1
                """, [.text(key), .int(id)])
        }
    }

    /// Daily decay of adaptive history: ×0.975, rows under 0.1 dropped.
    public func decayInputHistory() throws {
        try db.transaction {
            try db.run("UPDATE input_history SET use_count = use_count * 0.975")
            try db.run("DELETE FROM input_history WHERE use_count < 0.1")
        }
    }

    /// Recomputes every stored frecency (call at idle; scores are static between visits otherwise).
    public func recomputeAllFrecencies() throws {
        let ids = try db.query("SELECT id FROM urls") { $0.int64(0) }
        let t = now()
        try db.transaction { for id in ids { try recompute(id: id, at: t) } }
    }

    public func delete(url: URL) throws {
        try db.run("DELETE FROM urls WHERE url = ?", [.text(url.absoluteString)])
    }

    /// Removes every visit at or after `since`; URLs left without visits are removed, the rest recounted.
    /// `clear(since: .distantPast)` wipes history.
    public func clear(since: Date) throws {
        let cutoff = Self.ms(since)
        try db.transaction {
            let affected = try db.query("SELECT DISTINCT url_id FROM visits WHERE ts >= ?", [.int(cutoff)]) { $0.int64(0) }
            try db.run("DELETE FROM visits WHERE ts >= ?", [.int(cutoff)])
            try db.run("DELETE FROM urls WHERE last_visit >= ? AND id NOT IN (SELECT url_id FROM visits)", [.int(cutoff)])
            for id in affected {
                try db.run("""
                    UPDATE urls SET
                      visit_count = (SELECT COUNT(*) FROM visits WHERE url_id = ?1 AND kind != 5),
                      typed_count = (SELECT COUNT(*) FROM visits WHERE url_id = ?1 AND kind = 1),
                      last_visit = COALESCE((SELECT MAX(ts) FROM visits WHERE url_id = ?1), 0)
                    WHERE id = ?1
                    """, [.int(id)])
                try recompute(id: id, at: now())
            }
        }
    }

    // MARK: Reads

    /// FTS5 trigram search for terms of ≥ 3 characters, prefix `LIKE` on host/title words otherwise.
    /// Ordered by frecency.
    public func search(_ query: String, limit: Int = 20) throws -> [HistoryHit] {
        let q = Self.normalize(query)
        guard !q.isEmpty else { return try topSites(limit: limit) }
        let terms = q.split(whereSeparator: \.isWhitespace).map(String.init)
        let long = terms.filter { $0.count >= 3 }
        let short = terms.filter { $0.count < 3 }

        var bindings: [SQLValue] = [.text(q), .text(Self.likeEscape(q) + "%")]
        var sql = """
            SELECT \(Self.columns), COALESCE(a.use, 0)
            FROM urls u
            """
        if !long.isEmpty {
            sql += " JOIN urls_fts f ON f.rowid = u.id"
        }
        sql += """
             LEFT JOIN (SELECT url_id, MAX(CASE WHEN input = ? THEN use_count * 2 ELSE use_count END) AS use
                        FROM input_history WHERE input LIKE ? ESCAPE '\\' GROUP BY url_id) a ON a.url_id = u.id
            WHERE u.visit_count > 0
            """
        if !long.isEmpty {
            sql += " AND urls_fts MATCH ?"
            bindings.append(.text(long.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " ")))
            // Short terms alongside long ones: plain substring filters.
            for t in short {
                sql += " AND (u.title LIKE ? ESCAPE '\\' OR u.url LIKE ? ESCAPE '\\')"
                let p = "%" + Self.likeEscape(t) + "%"
                bindings += [.text(p), .text(p)]
            }
        } else {
            for t in short {
                let e = Self.likeEscape(t)
                sql += " AND (u.host LIKE ? ESCAPE '\\' OR u.host LIKE ? ESCAPE '\\' OR u.title LIKE ? ESCAPE '\\' OR u.title LIKE ? ESCAPE '\\')"
                bindings += [.text(e + "%"), .text("www." + e + "%"), .text(e + "%"), .text("% " + e + "%")]
            }
        }
        sql += " ORDER BY u.frecency DESC LIMIT ?"
        bindings.append(.int(Int64(limit)))
        let t = now()
        return try db.query(sql, bindings) { Self.hit($0, now: t, adaptiveColumn: 8) }
    }

    /// Highest-frecency URLs.
    public func topSites(limit: Int = 12) throws -> [HistoryHit] {
        let t = now()
        return try db.query("SELECT \(Self.columns) FROM urls u WHERE u.visit_count > 0 ORDER BY u.frecency DESC LIMIT ?",
                            [.int(Int64(limit))]) { Self.hit($0, now: t, adaptiveColumn: nil) }
    }

    /// Most recently visited URLs.
    public func recent(limit: Int = 50) throws -> [HistoryHit] {
        let t = now()
        return try db.query("SELECT \(Self.columns) FROM urls u WHERE u.visit_count > 0 ORDER BY u.last_visit DESC LIMIT ?",
                            [.int(Int64(limit))]) { Self.hit($0, now: t, adaptiveColumn: nil) }
    }

    /// Candidates for the in-memory quick index (Chromium HQP gating: typed, ≥ 4 visits, or visited
    /// in the last 72 h), by frecency.
    public func quickIndexCandidates(limit: Int = 20_000) throws -> [HistoryHit] {
        let t = now()
        let since = Self.ms(t.addingTimeInterval(-72 * 3600))
        return try db.query("""
            SELECT \(Self.columns) FROM urls u
            WHERE u.visit_count > 0 AND (u.typed_count > 0 OR u.visit_count >= 4 OR u.last_visit >= ?)
            ORDER BY u.frecency DESC LIMIT ?
            """, [.int(since), .int(Int64(limit))]) { Self.hit($0, now: t, adaptiveColumn: nil) }
    }

    /// Adaptive-history pairs whose input starts with `prefix` (all pairs for ""), strongest first.
    public func inputMatches(prefix: String) throws -> [InputMatch] {
        let p = Self.likeEscape(Self.normalize(prefix)) + "%"
        return try db.query("""
            SELECT i.input, u.url, u.title, u.host, i.use_count, u.typed_count
            FROM input_history i JOIN urls u ON u.id = i.url_id
            WHERE i.input LIKE ? ESCAPE '\\' ORDER BY i.use_count DESC
            """, [.text(p)]) { row in
            InputMatch(input: row.string(0) ?? "", url: URL(string: row.string(1) ?? "") ?? URL(string: "about:blank")!,
                       title: row.string(2), host: row.string(3) ?? "", useCount: row.double(4), typedCount: row.int(5))
        }
    }

    /// Single-URL lookup.
    public func hit(for url: URL) throws -> HistoryHit? {
        let t = now()
        return try db.queryOne("SELECT \(Self.columns) FROM urls u WHERE u.url = ?", [.text(url.absoluteString)]) {
            Self.hit($0, now: t, adaptiveColumn: nil)
        }
    }

    // MARK: Internals

    private static let columns = "u.id, u.url, u.title, u.host, u.frecency, u.visit_count, u.typed_count, u.last_visit"

    private static func hit(_ row: Row, now: Date, adaptiveColumn: Int32?) -> HistoryHit {
        HistoryHit(
            id: row.int64(0),
            url: URL(string: row.string(1) ?? "") ?? URL(string: "about:blank")!,
            title: row.string(2),
            host: row.string(3) ?? "",
            frecency: Frecency.currentScore(storedValue: row.double(4), now: now),
            visitCount: row.int(5),
            typedCount: row.int(6),
            lastVisit: Date(timeIntervalSince1970: Double(row.int64(7)) / 1000),
            adaptiveUse: adaptiveColumn.map { row.double($0) } ?? 0
        )
    }

    private func urlID(_ url: URL) throws -> Int64? {
        try db.queryOne("SELECT id FROM urls WHERE url = ?", [.text(url.absoluteString)]) { $0.int64(0) }
    }

    private func upsertURL(_ url: URL, title: String?) throws -> Int64 {
        let host = url.host()?.lowercased() ?? ""
        let title = title.flatMap { $0.isEmpty ? nil : $0 }
        guard let id = try db.queryOne("""
            INSERT INTO urls(url, host, title) VALUES (?, ?, ?)
            ON CONFLICT(url) DO UPDATE SET title = COALESCE(excluded.title, urls.title)
            RETURNING id
            """, [.text(url.absoluteString), .text(host), .optionalText(title)], { $0.int64(0) }) else {
            throw DatabaseError(code: 0, message: "upsert returned no id", sql: nil)
        }
        return id
    }

    private func recompute(id: Int64, at t: Date) throws {
        let visits = try db.query("""
            SELECT ts, kind, view_ms, keypresses FROM visits WHERE url_id = ? ORDER BY ts DESC LIMIT ?
            """, [.int(id), .int(Int64(Frecency.sampleSize))]) { row in
            Frecency.SampledVisit(date: Date(timeIntervalSince1970: Double(row.int64(0)) / 1000),
                                  kind: VisitKind(rawValue: row.int(1)) ?? .link,
                                  viewMs: row.int(2), keypresses: row.int(3))
        }
        let count = try db.queryOne("SELECT visit_count FROM urls WHERE id = ?", [.int(id)]) { $0.int(0) } ?? 0
        let score = Frecency.score(visits: visits, visitCount: count, now: t)
        try db.run("UPDATE urls SET frecency = ? WHERE id = ?", [.double(Frecency.storedValue(score: score, now: t)), .int(id)])
    }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func likeEscape(_ s: String) -> String {
        var out = ""
        for c in s {
            if c == "%" || c == "_" || c == "\\" { out.append("\\") }
            out.append(c)
        }
        return out
    }
}
