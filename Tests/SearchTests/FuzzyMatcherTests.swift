import Foundation
import Testing
import Search

private let M = Int(FuzzyMatcher.scoreMatch)
private let gapStart = Int(FuzzyMatcher.scoreGapStart)
private let gapExt = Int(FuzzyMatcher.scoreGapExtension)
private let boundary = Int(FuzzyMatcher.bonusBoundary)
private let white = Int(FuzzyMatcher.bonusBoundaryWhite)
private let delim = Int(FuzzyMatcher.bonusBoundaryDelimiter)
private let camel = Int(FuzzyMatcher.bonusCamel123)
private let consec = Int(FuzzyMatcher.bonusConsecutive)
private let nonWord = Int(FuzzyMatcher.bonusNonWord)
private let first = Int(FuzzyMatcher.bonusFirstCharMultiplier)

/// Expected scores and spans from fzf's own `algo_test.go` (case-insensitive cases).
struct FzfCase: Sendable, CustomTestStringConvertible {
    var text: String, pattern: String, start: Int, end: Int, score: Int
    var testDescription: String { "\(pattern) in \(text)" }
}

private let fzfCases: [FzfCase] = [
    .init(text: "fooBarbaz1", pattern: "oBZ", start: 2, end: 9, score: M * 3 + camel + gapStart + gapExt * 3),
    .init(text: "foo bar baz", pattern: "fbb", start: 0, end: 9, score: M * 3 + white * first + white * 2 + 2 * gapStart + 4 * gapExt),
    .init(text: "/AutomatorDocument.icns", pattern: "rdoc", start: 9, end: 13, score: M * 4 + camel + consec * 2),
    .init(text: "/man1/zshcompctl.1", pattern: "zshc", start: 6, end: 10, score: M * 4 + delim * first + delim * 3),
    .init(text: "/.oh-my-zsh/cache", pattern: "zshc", start: 8, end: 13, score: M * 4 + boundary * first + boundary * 2 + gapStart + delim),
    .init(text: "ab0123 456", pattern: "12356", start: 3, end: 10, score: M * 5 + consec * 3 + gapStart + gapExt),
    .init(text: "abc123 456", pattern: "12356", start: 3, end: 10, score: M * 5 + camel * first + camel * 2 + consec + gapStart + gapExt),
    .init(text: "foo/bar/baz", pattern: "fbb", start: 0, end: 9, score: M * 3 + white * first + delim * 2 + 2 * gapStart + 4 * gapExt),
    .init(text: "fooBarBaz", pattern: "fbb", start: 0, end: 7, score: M * 3 + white * first + camel * 2 + 2 * gapStart + 2 * gapExt),
    .init(text: "foo barbaz", pattern: "fbb", start: 0, end: 8, score: M * 3 + white * first + white + gapStart * 2 + gapExt * 3),
    .init(text: "fooBar Baz", pattern: "foob", start: 0, end: 4, score: M * 4 + white * first + white * 3),
    .init(text: "xFoo-Bar Baz", pattern: "foo-b", start: 1, end: 6, score: M * 5 + camel * first + camel * 2 + nonWord + boundary),
]

@Suite struct FuzzyMatcherTests {
    @Test(arguments: fzfCases)
    func matchesFzfV2Scores(_ c: FzfCase) throws {
        let m = try #require(FuzzyMatcher().match(c.pattern, in: c.text))
        #expect(m.score == c.score)
        #expect(m.positions.first == c.start)
        #expect(m.positions.last.map { $0 + 1 } == c.end)
        #expect(m.positions.count == c.pattern.utf8.count)
    }

    @Test(arguments: fzfCases)
    func greedyV1FallbackFindsSameMatches(_ c: FzfCase) throws {
        // fzf runs the same table against V1; V1 is greedy, so only assert it matches and scores sanely.
        let m = try #require(FuzzyMatcher(slabCapacity: 0).match(c.pattern, in: c.text))
        #expect(m.positions.count == c.pattern.utf8.count)
        #expect(m.score > 0)
        #expect(m.score <= c.score)
    }

    @Test func ghRanksGithubAboveGraph() throws {
        let f = FuzzyMatcher()
        let gh = try #require(f.match("gh", in: "github.com"))
        let graph = try #require(f.match("gh", in: "graph"))
        #expect(gh.score > graph.score)
        #expect(gh.positions == [0, 3])
    }

    @Test func caseInsensitiveAndNoMatch() {
        let f = FuzzyMatcher()
        #expect(f.match("GH", in: "github")?.score == f.match("gh", in: "github")?.score)
        #expect(f.match("gh", in: "GITHUB") != nil)
        #expect(f.match("xyz", in: "github") == nil)
        #expect(f.match("githubs", in: "github") == nil)
        #expect(f.match("", in: "github") == FuzzyMatch(score: 0, positions: []))
    }

    @Test func boundaryAndCamelBonuses() throws {
        let f = FuzzyMatcher()
        let boundaryHit = try #require(f.match("nt", in: "new-tab"))
        let midWord = try #require(f.match("nt", in: "xnxtx"))
        #expect(boundaryHit.score > midWord.score)

        let camelHit = try #require(f.match("nt", in: "newTab"))
        let flat = try #require(f.match("nt", in: "newtab"))
        #expect(camelHit.score > flat.score)

        let white = try #require(f.match("t", in: "new tab"))
        let delim = try #require(f.match("t", in: "new/tab"))
        let punct = try #require(f.match("t", in: "new.tab"))
        #expect(white.score > delim.score && delim.score > punct.score)
    }

    @Test func consecutiveBeatsScattered() throws {
        let f = FuzzyMatcher()
        let tight = try #require(f.match("abc", in: "xabcx"))
        let loose = try #require(f.match("abc", in: "xaxbxcx"))
        #expect(tight.score > loose.score)
    }

    @Test func prefersBestAlignmentNotFirst() throws {
        // Greedy would take the first 'r'; V2 finds the camel-case "Read" + "Mode".
        let m = try #require(FuzzyMatcher().match("rm", in: "previous ReaderMode"))
        #expect(m.positions == [9, 15])
    }

    @Test func rangesMergeConsecutivePositions() {
        #expect(FuzzyMatch(score: 0, positions: [0, 1, 2, 5, 7, 8]).ranges == [0..<3, 5..<6, 7..<9])
        let s = "café tab"
        let r = s.indexRanges(utf8: [3..<5, 6..<9])  // é spans bytes 3–4
        #expect(r.map { String(s[$0]) } == ["é", "tab"])
    }

    @Test func multiTermANDsAndUnionsPositions() throws {
        let f = FuzzyMatcher()
        let terms = [FuzzyPattern("tab"), FuzzyPattern("new")]
        let m = try #require(f.matchTerms(terms, in: "New Tab"))
        #expect(m.positions == [0, 1, 2, 4, 5, 6])
        #expect(f.matchTerms([FuzzyPattern("tab"), FuzzyPattern("zzz")], in: "New Tab") == nil)
    }

    @Test func longInputFallsBackToV1() throws {
        let long = String(repeating: "x", count: 60_000) + "github"
        let f = FuzzyMatcher()
        let m = try #require(f.match("github", in: long))
        #expect(m.positions == Array(60_000..<60_006))
    }

    @Test func nonASCIIBytesMatchExactly() throws {
        let f = FuzzyMatcher()
        #expect(f.match("é", in: "café") != nil)
        #expect(f.match("ü", in: "cafe") == nil)
    }

    /// 20k realistic candidates (title + URL) must score in < 10 ms. Asserted only in optimized builds:
    /// run `swift test -c release --filter SearchTests`.
    @Test func performance20kCandidates() {
        var candidates: [String] = []
        let words = ["swift", "github", "docs", "apple", "news", "graph", "kernel", "rust", "maps", "mail", "video", "shop"]
        for i in 0..<20_000 {
            let a = words[i % words.count], b = words[(i / 7) % words.count], c = words[(i / 13) % words.count]
            candidates.append("\(a.capitalized) \(b) — \(c) notes #\(i) https://\(b).\(a).com/\(c)/page-\(i)?ref=\(a)")
        }
        let f = FuzzyMatcher()
        var best = Duration.seconds(1)
        for pattern in ["gh", "gthb", "swift docs", "zq"] {
            let terms = pattern.split(separator: " ").map { FuzzyPattern(String($0)) }
            let clock = ContinuousClock()
            for _ in 0..<3 {
                var hits = 0
                let t = clock.measure {
                    for s in candidates where f.matchTerms(terms, in: s, withPositions: false) != nil { hits += 1 }
                }
                best = min(best, t)
                #expect(hits >= 0)
            }
            print("fuzzy 20k '\(pattern)': \(best)")
            #if !DEBUG
            #expect(best < .milliseconds(10), "\(pattern): \(best)")
            #endif
            best = .seconds(1)
        }
    }
}
