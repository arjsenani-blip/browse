import Foundation
import Testing
import Persistence

private let base = Date(timeIntervalSince1970: 1_790_000_000)
private func day(_ n: Double) -> Date { base.addingTimeInterval(n * 86_400) }
private func u(_ s: String) -> URL { URL(string: s)! }

@Suite struct DatabaseTests {
    @Test func bindAndQueryRoundTrip() throws {
        let db = try Database(path: ":memory:")
        try db.execute("CREATE TABLE t(a INT, b REAL, c TEXT, d BLOB)")
        try db.run("INSERT INTO t VALUES (?, ?, ?, ?)", [.int(7), .double(1.5), .text("hé'llo"), .blob(Data([1, 2, 3]))])
        try db.run("INSERT INTO t VALUES (?, ?, ?, ?)", [nil, nil, nil, nil])
        let rows = try db.query("SELECT a, b, c, d FROM t ORDER BY rowid") { r in
            (r.isNull(0) ? nil : r.int(0), r.double(1), r.string(2), r.data(3))
        }
        #expect(rows.count == 2)
        #expect(rows[0].0 == 7 && rows[0].1 == 1.5 && rows[0].2 == "hé'llo" && rows[0].3 == Data([1, 2, 3]))
        #expect(rows[1].0 == nil && rows[1].2 == nil)
    }

    @Test func transactionRollsBackOnThrow() throws {
        struct Boom: Error {}
        let db = try Database(path: ":memory:")
        try db.execute("CREATE TABLE t(a INT)")
        #expect(throws: Boom.self) {
            try db.transaction {
                try db.run("INSERT INTO t VALUES (1)")
                throw Boom()
            }
        }
        // Nested: inner savepoint rolls back, outer commits.
        try db.transaction {
            try db.run("INSERT INTO t VALUES (2)")
            try? db.transaction {
                try db.run("INSERT INTO t VALUES (3)")
                throw Boom()
            }
        }
        let values = try db.query("SELECT a FROM t") { $0.int(0) }
        #expect(values == [2])
    }

    @Test func badSQLThrows() throws {
        let db = try Database(path: ":memory:")
        #expect(throws: DatabaseError.self) { try db.run("SELEKT 1") }
    }

    @Test func fileDatabaseUsesWAL() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try Database(url: dir.appendingPathComponent("h.sqlite"))
        let mode = try db.queryOne("PRAGMA journal_mode") { $0.string(0) }
        #expect(mode == "wal")
    }

    @Test func keyProviderSeamRefusesToWritePlaintext() {
        struct Key: DatabaseKeyProvider { func databaseKey() throws -> Data? { Data([1]) } }
        struct NoKey: DatabaseKeyProvider { func databaseKey() throws -> Data? { nil } }
        #expect(throws: DatabaseError.self) { try Database(path: ":memory:", keyProvider: Key()) }
        #expect((try? Database(path: ":memory:", keyProvider: NoKey())) != nil)
    }
}

@Suite struct FrecencyTests {
    @Test func halfLifeIsThirtyDays() {
        let v = [Frecency.SampledVisit(date: day(0), kind: .link)]
        let fresh = Frecency.score(visits: v, visitCount: 1, now: day(0))
        let old = Frecency.score(visits: v, visitCount: 1, now: day(30))
        #expect(abs(fresh - 50) < 1e-9)
        #expect(abs(old - 25) < 1e-6)
    }

    @Test func bucketsAndInterestingUpgrade() {
        #expect(Frecency.weight(.init(date: base, kind: .typed)) == 100)
        #expect(Frecency.weight(.init(date: base, kind: .bookmark)) == 70)
        #expect(Frecency.weight(.init(date: base, kind: .link)) == 50)
        #expect(Frecency.weight(.init(date: base, kind: .redirect)) == 20)
        #expect(Frecency.weight(.init(date: base, kind: .reload)) == 20)
        #expect(Frecency.weight(.init(date: base, kind: .link, viewMs: 90_000)) == 70)
        #expect(Frecency.weight(.init(date: base, kind: .typed, keypresses: 100)) == 100)
    }

    @Test func samplesLastTenTimesCount() {
        let visits = (0..<15).map { Frecency.SampledVisit(date: day(Double(-$0)), kind: $0 < 10 ? .typed : .redirect) }
        let s = Frecency.score(visits: visits, visitCount: 15, now: day(0))
        // Only the 10 typed visits are sampled.
        let expected = (0..<10).reduce(0.0) { $0 + 100 * exp(-Frecency.lambda * Double($1)) } / 10 * 15
        #expect(abs(s - expected) < 1e-6)
    }

    @Test func storedValueRoundTripsAndIsStatic() {
        let score = 420.0
        let stored = Frecency.storedValue(score: score, now: day(0))
        #expect(abs(Frecency.currentScore(storedValue: stored, now: day(0)) - score) < 1e-6)
        #expect(abs(Frecency.currentScore(storedValue: stored, now: day(30)) - score / 2) < 1e-6)
        #expect(Frecency.storedValue(score: 0, now: day(0)) == 0)
        #expect(Frecency.currentScore(storedValue: 0, now: day(0)) == 0)
    }
}

@Suite struct HistoryStoreTests {
    final class Clock: @unchecked Sendable {
        var now = day(0)
    }

    func makeStore(_ clock: Clock = Clock()) throws -> HistoryStore {
        try HistoryStore(url: URL(string: ":memory:")!, now: { clock.now })
    }

    @Test func recordVisitUpdatesCounters() async throws {
        let store = try makeStore()
        let url = u("https://github.com/apple/swift")
        try await store.recordVisit(url: url, title: "Swift", kind: .typed, at: day(0))
        try await store.recordVisit(url: url, title: nil, kind: .link, at: day(0).addingTimeInterval(60))
        try await store.recordVisit(url: url, title: nil, kind: .redirect, at: day(0).addingTimeInterval(120))
        let hit = try #require(try await store.hit(for: url))
        #expect(hit.title == "Swift")           // nil title keeps the old one
        #expect(hit.host == "github.com")
        #expect(hit.visitCount == 2)            // redirect not counted
        #expect(hit.typedCount == 1)
        #expect(hit.lastVisit == day(0).addingTimeInterval(120))
        #expect(hit.frecency > 0)
    }

    @Test func frecencyOrdering() async throws {
        let clock = Clock()
        let store = try makeStore(clock)
        // Frequent typed visits beat a single link visit; recent beats old.
        for i in 0..<5 {
            try await store.recordVisit(url: u("https://often.com/"), title: "Often", kind: .typed, at: day(Double(-i)))
        }
        try await store.recordVisit(url: u("https://once.com/"), title: "Once", kind: .link, at: day(0))
        try await store.recordVisit(url: u("https://old.com/"), title: "Old", kind: .link, at: day(-120))
        let top = try await store.topSites(limit: 10).map(\.host)
        #expect(top == ["often.com", "once.com", "old.com"])
        // Stored value stays sortable as time passes.
        clock.now = day(60)
        let later = try await store.topSites(limit: 10)
        #expect(later.map(\.host) == top)
        #expect(later[1].frecency < 50 / 3.9)  // once.com: 50 decayed two half-lives ≈ 12.5
    }

    @Test func linkVsTypedSameRecency() async throws {
        let store = try makeStore()
        try await store.recordVisit(url: u("https://typed.com/"), title: nil, kind: .typed, at: day(0))
        try await store.recordVisit(url: u("https://linked.com/"), title: nil, kind: .link, at: day(0))
        #expect(try await store.topSites(limit: 2).map(\.host) == ["typed.com", "linked.com"])
    }

    @Test func ftsLongQueryMatchesSubstringsInTitleAndURL() async throws {
        let store = try makeStore()
        try await store.recordVisit(url: u("https://github.com/apple/swift"), title: "apple/swift: The Swift Programming Language", kind: .typed, at: day(0))
        try await store.recordVisit(url: u("https://news.ycombinator.com/"), title: "Hacker News", kind: .link, at: day(0))
        try await store.recordVisit(url: u("https://example.com/graphql"), title: "GraphQL docs", kind: .link, at: day(0))

        #expect(try await store.search("program", limit: 10).map(\.host) == ["github.com"])   // mid-word title
        #expect(try await store.search("ycombi", limit: 10).map(\.host) == ["news.ycombinator.com"]) // url
        #expect(try await store.search("HACKER", limit: 10).map(\.host) == ["news.ycombinator.com"]) // case-insensitive
        #expect(try await store.search("swift lang", limit: 10).map(\.host) == ["github.com"])      // AND of terms
        #expect(try await store.search("zzzz", limit: 10).isEmpty)
    }

    @Test func ftsRemovesDiacriticsWhenSupported() async throws {
        let store = try makeStore()
        try await store.recordVisit(url: u("https://cafe.example/"), title: "Café Crème", kind: .link, at: day(0))
        if store.ftsRemovesDiacritics {
            #expect(try await store.search("creme", limit: 5).count == 1)
        }
        #expect(try await store.search("Crème", limit: 5).count == 1)
    }

    @Test func shortQueryUsesPrefixOnHostAndTitleWords() async throws {
        let store = try makeStore()
        try await store.recordVisit(url: u("https://www.github.com/"), title: "GitHub", kind: .typed, at: day(0))
        try await store.recordVisit(url: u("https://graph.org/"), title: "Graph", kind: .link, at: day(0))
        try await store.recordVisit(url: u("https://example.com/"), title: "Big Help", kind: .link, at: day(0))
        try await store.recordVisit(url: u("https://ahoy.com/"), title: "Ahoy", kind: .link, at: day(0))

        let gi = try await store.search("gi", limit: 10).map(\.host)
        #expect(gi == ["www.github.com"])                  // www. ignored; "ahoy"/"big" are not prefixes
        let g = try await store.search("g", limit: 10).map(\.host)
        #expect(g == ["www.github.com", "graph.org"])      // ordered by frecency (typed first)
        #expect(try await store.search("he", limit: 10).map(\.host) == ["example.com"]) // title word prefix
        #expect(try await store.search("%", limit: 10).isEmpty)                        // LIKE wildcard escaped
    }

    @Test func emptyQueryReturnsTopSites() async throws {
        let store = try makeStore()
        try await store.recordVisit(url: u("https://a.com/"), title: "A", kind: .typed, at: day(0))
        #expect(try await store.search("  ", limit: 5).count == 1)
    }

    @Test func titleUpdatesReindexFTS() async throws {
        let store = try makeStore()
        let url = u("https://x.com/page")
        try await store.recordVisit(url: url, title: "Loading", kind: .link, at: day(0))
        try await store.updateTitle(url: url, title: "Quarterly Report")
        #expect(try await store.search("quarter", limit: 5).count == 1)
        #expect(try await store.search("loading", limit: 5).isEmpty)
    }

    @Test func adaptiveHistory() async throws {
        let store = try makeStore()
        let gh = u("https://github.com/")
        try await store.recordVisit(url: gh, title: "GitHub", kind: .typed, at: day(0))
        try await store.recordInputChoice(input: "Gi", url: gh)
        try await store.recordInputChoice(input: "gi ", url: gh)
        let m = try await store.inputMatches(prefix: "g")
        #expect(m.count == 1)
        #expect(m[0].input == "gi")
        #expect(abs(m[0].useCount - 1.9) < 1e-9)  // 1, then 1·0.9 + 1

        // Search surfaces adaptiveUse: prefix match vs exact (×2).
        let hits = try await store.search("git", limit: 5)
        #expect(hits.first?.adaptiveUse == 0)     // "gi" does not start with "git"
        let exact = try await store.search("gi", limit: 5)
        #expect(abs((exact.first?.adaptiveUse ?? 0) - 3.8) < 1e-9)
        let prefix = try await store.search("g", limit: 5)
        #expect(abs((prefix.first?.adaptiveUse ?? 0) - 1.9) < 1e-9)
    }

    @Test func adaptiveDecayDropsWeakRows() async throws {
        let store = try makeStore()
        let a = u("https://a.com/"), b = u("https://b.com/")
        try await store.recordInputChoice(input: "a", url: a)
        for _ in 0..<5 { try await store.recordInputChoice(input: "b", url: b) }
        for _ in 0..<90 { try await store.decayInputHistory() }   // 0.975^90 ≈ 0.1025
        var rows = try await store.inputMatches(prefix: "")
        #expect(rows.count == 2)
        try await store.decayInputHistory()                         // a drops below 0.1
        rows = try await store.inputMatches(prefix: "")
        #expect(rows.map(\.input) == ["b"])
    }

    @Test func deleteAndClear() async throws {
        let store = try makeStore()
        let a = u("https://a.com/"), b = u("https://b.com/"), c = u("https://c.com/")
        try await store.recordVisit(url: a, title: "Alpha", kind: .link, at: day(-10))
        try await store.recordVisit(url: b, title: "Bravo", kind: .link, at: day(-10))
        try await store.recordVisit(url: b, title: nil, kind: .typed, at: day(-1))
        try await store.recordVisit(url: c, title: "Charlie", kind: .link, at: day(-1))
        try await store.recordInputChoice(input: "al", url: a)

        try await store.delete(url: a)
        #expect(try await store.hit(for: a) == nil)
        #expect(try await store.inputMatches(prefix: "al").isEmpty)   // cascade
        #expect(try await store.search("alpha", limit: 5).isEmpty)    // FTS trigger

        try await store.clear(since: day(-2))
        #expect(try await store.hit(for: c) == nil)
        let bHit = try #require(try await store.hit(for: b))
        #expect(bHit.visitCount == 1 && bHit.typedCount == 0)
        #expect(bHit.lastVisit == day(-10))

        try await store.clear(since: .distantPast)
        #expect(try await store.topSites(limit: 10).isEmpty)
    }

    @Test func recentAndQuickIndexGating() async throws {
        let store = try makeStore()
        try await store.recordVisit(url: u("https://old-link.com/"), title: nil, kind: .link, at: day(-10))
        try await store.recordVisit(url: u("https://old-typed.com/"), title: nil, kind: .typed, at: day(-10))
        try await store.recordVisit(url: u("https://new.com/"), title: nil, kind: .link, at: day(-1))
        #expect(try await store.recent(limit: 1).map(\.host) == ["new.com"])
        let quick = Set(try await store.quickIndexCandidates().map(\.host))
        #expect(quick == ["old-typed.com", "new.com"])
    }

    @Test func persistsAcrossReopen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.sqlite")
        do {
            let s = try HistoryStore(url: file)
            try await s.recordVisit(url: u("https://persist.dev/"), title: "Persisted", kind: .typed, at: Date())
        }
        let s2 = try HistoryStore(url: file)
        #expect(try await s2.search("persist", limit: 5).count == 1)
    }

    @Test func engagementLiftsBucket() async throws {
        let store = try makeStore()
        let url = u("https://read.com/")
        try await store.recordVisit(url: url, title: nil, kind: .link, at: day(0))
        let before = try #require(try await store.hit(for: url)).frecency
        try await store.recordEngagement(url: url, viewMs: 120_000, keypresses: 0)
        let after = try #require(try await store.hit(for: url)).frecency
        #expect(abs(before - 50) < 1e-6 && abs(after - 70) < 1e-6)
    }
}
