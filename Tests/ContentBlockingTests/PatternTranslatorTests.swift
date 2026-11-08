import Foundation
import Testing
@testable import ContentBlocking

@Suite struct PatternTranslatorTests {
    @Test func hostAnchorWithSeparator() throws {
        let f = try #require(urlFilter(for: "||example.com^"))
        #expect(f == #"^[^:]+://+([^:/]+\.)?example\.com[^-a-zA-Z0-9_.%]"#)
        #expect(filterMatches(f, "https://example.com/"))
        #expect(filterMatches(f, "https://ads.example.com/x.js"))
        #expect(filterMatches(f, "http://example.com:8080/"))
        #expect(!filterMatches(f, "https://notexample.com/"))
        #expect(!filterMatches(f, "https://example.community/"))
        #expect(!filterMatches(f, "https://other.com/?u=https://example.com/"))
    }

    @Test func hostIsLowercased() {
        #expect(urlFilter(for: "||ExAmple.COM/Path") == #"^[^:]+://+([^:/]+\.)?example\.com/Path"#)
    }

    @Test func startAndEndAnchors() throws {
        let f = try #require(urlFilter(for: "|https://ads."))
        #expect(f == #"^https://ads\."#)
        #expect(filterMatches(f, "https://ads.example.com/"))
        #expect(!filterMatches(f, "https://x.com/https://ads."))
        let g = try #require(urlFilter(for: ".swf|"))
        #expect(g == #"\.swf$"#)
        #expect(filterMatches(g, "https://x.com/a.swf"))
        #expect(!filterMatches(g, "https://x.com/a.swf?x"))
    }

    @Test func wildcardsAndSpecials() throws {
        let f = try #require(urlFilter(for: "/ads/*/banner?.gif+(x)"))
        #expect(f == #"/ads/.*/banner\?\.gif\+\(x\)"#)
        #expect(filterMatches(f, "https://x.com/ads/123/banner?.gif+(x)"))
        #expect(urlFilter(for: "*/adserver/*") == "/adserver/")
        #expect(urlFilter(for: "a**b") == "a.*b")
        #expect(urlFilter(for: "") == ".*")
        #expect(urlFilter(for: "*") == ".*")
    }

    @Test func midSeparator() throws {
        let f = try #require(urlFilter(for: "&ad_type=^"))
        #expect(filterMatches(f, "https://x.com/?a=1&ad_type=&b"))
        #expect(!filterMatches(f, "https://x.com/?a=1&ad_type=banner"))
    }

    @Test func nonASCIIIsSkipped() {
        #expect(PatternTranslator.translate("||例え.jp^") == .skip(.nonASCII))
    }

    @Test func regexSubset() {
        #expect(PatternTranslator.translate(#"/^https?:\/\/ads\.[a-z]+\.com\//"#) == .filter(#"^https?://ads\.[a-z]+\.com/"#))
        #expect(PatternTranslator.translate(#"/banner\d+\.gif/"#) == .filter(#"banner[0-9]+\.gif"#))
        #expect(PatternTranslator.translate(#"/ad[\w-]+/"#) == .filter(#"ad[A-Za-z0-9_-]+"#))
        #expect(PatternTranslator.translate("/(ads|banners)/") == .skip(.regexUnsupported))
        #expect(PatternTranslator.translate("/a{2,3}/") == .skip(.regexUnsupported))
        #expect(PatternTranslator.translate(#"/\bads\b/"#) == .skip(.regexUnsupported))
        #expect(PatternTranslator.translate("/(?!x)ads/") == .skip(.regexUnsupported))
        #expect(PatternTranslator.translate("/a.*?b/") == .skip(.regexUnsupported))
    }
}
