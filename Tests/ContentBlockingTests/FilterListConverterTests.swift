import Foundation
import Testing
@testable import ContentBlocking

@Suite struct FilterListConverterTests {
    @Test func basicBlockRule() throws {
        let result = FilterListConverter.convert("||tracker.example^")
        let rules = try allRules(result)
        #expect(rules.count == 1)
        #expect(actionType(rules[0]) == "block")
        #expect(trigger(rules[0])["resource-type"] == nil) // host-anchored: all types
        #expect(result.convertedFilterCount == 1)
    }

    @Test func commentsAndHeadersIgnored() {
        let result = FilterListConverter.convert("[Adblock Plus 2.0]\n! comment\n\n   \n")
        #expect(result.lists.isEmpty)
        #expect(result.totalSkipped == 0)
    }

    @Test func exceptionsComeAfterBlocksAndImportantLast() throws {
        let text = """
        @@||ads.example.com/ok.js
        ||ads.example.com^
        ||critical.example^$important
        /banner/*
        """
        let rules = try parseRules(FilterListConverter.convert(text).lists[0])
        let types = rules.map(actionType)
        let firstIgnore = try #require(types.firstIndex(of: "ignore-previous-rules"))
        let lastBlockBeforeIgnore = types[..<firstIgnore].allSatisfy { $0 == "block" }
        #expect(lastBlockBeforeIgnore)
        #expect(types.last == "block")
        #expect(urlFilter(rules.last!).contains("critical"))
        #expect(urlFilter(rules[firstIgnore]).contains("ok\\.js"))
    }

    @Test func thirdPartyAndResourceTypes() throws {
        let rules = try allRules(FilterListConverter.convert("||cdn.example^$script,image,xmlhttprequest,third-party"))
        #expect(rules.count == 1)
        let t = trigger(rules[0])
        #expect(t["load-type"] as? [String] == ["third-party"])
        #expect(t["resource-type"] as? [String] == ["script", "image", "fetch"])

        let first = try allRules(FilterListConverter.convert("||cdn.example^$~third-party,stylesheet"))
        #expect(trigger(first[0])["load-type"] as? [String] == ["first-party"])
        #expect(trigger(first[0])["resource-type"] as? [String] == ["style-sheet"])
    }

    @Test func subdocumentUsesChildFrameContext() throws {
        let rules = try allRules(FilterListConverter.convert("||frames.example^$subdocument,script"))
        #expect(rules.count == 2)
        #expect(trigger(rules[0])["resource-type"] as? [String] == ["script"])
        #expect(trigger(rules[1])["resource-type"] as? [String] == ["document"])
        #expect(trigger(rules[1])["load-context"] as? [String] == ["child-frame"])
    }

    @Test func negatedTypes() throws {
        let rules = try allRules(FilterListConverter.convert("||x.example^$~script,~image,~subdocument"))
        let types = try #require(trigger(rules[0])["resource-type"] as? [String])
        #expect(!types.contains("script") && !types.contains("image") && !types.contains("document"))
        #expect(types.contains("style-sheet"))
    }

    @Test func genericPatternWithoutTypesSkipsTopDocument() throws {
        let rules = try allRules(FilterListConverter.convert("/adframe/"))
        #expect(rules.count == 2)
        #expect(!(trigger(rules[0])["resource-type"] as? [String] ?? []).contains("document"))
        #expect(trigger(rules[1])["load-context"] as? [String] == ["child-frame"])
    }

    @Test func domainOptions() throws {
        let inc = try allRules(FilterListConverter.convert("/ads.js$domain=A.com|b.org"))
        #expect(trigger(inc[0])["if-domain"] as? [String] == ["*a.com", "*b.org"])

        let exc = try allRules(FilterListConverter.convert("/ads.js$script,domain=~a.com|~b.org"))
        #expect(trigger(exc[0])["unless-domain"] as? [String] == ["*a.com", "*b.org"])
        #expect(trigger(exc[0])["if-domain"] == nil)

        // Mixed: block with if-domain + ignore twin for the excluded subdomain.
        let mixed = try allRules(FilterListConverter.convert("/ads.js$script,domain=a.com|~sub.a.com|~unrelated.net"))
        #expect(mixed.count == 2)
        #expect(actionType(mixed[0]) == "block")
        #expect(trigger(mixed[0])["if-domain"] as? [String] == ["*a.com"])
        #expect(actionType(mixed[1]) == "ignore-previous-rules")
        #expect(trigger(mixed[1])["if-domain"] as? [String] == ["*sub.a.com"])
    }

    @Test func entityDomainsSkipped() {
        let result = FilterListConverter.convert("/ads.js$domain=google.*")
        #expect(result.skipped[.entityDomain] == 1)
        #expect(result.lists.isEmpty)
    }

    @Test func importantAndMatchCase() throws {
        let rules = try allRules(FilterListConverter.convert("/AdBanner.$match-case"))
        #expect(trigger(rules[0])["url-filter-is-case-sensitive"] as? Bool == true)
    }

    @Test func documentExceptionAllowlistsSite() throws {
        let result = FilterListConverter.convert("||ads.example^\n##.ad\n@@||trusted.example^$document")
        let rules = try allRules(result)
        let ignores = rules.filter { actionType($0) == "ignore-previous-rules" }
        // One in the network list, one in the cosmetic list.
        #expect(ignores.count == 2)
        for rule in ignores {
            #expect(urlFilter(rule) == ".*")
            #expect(trigger(rule)["if-domain"] as? [String] == ["*trusted.example"])
        }
        #expect(result.cosmetic.elemHideDomains == ["trusted.example"])
    }

    @Test func unsupportedOptionsAreCounted() {
        let text = """
        ||a.example^$redirect=noopjs
        ||b.example^$removeparam=utm_source
        ||c.example^$csp=script-src 'none'
        ||d.example^$replace=/a/b/
        ||e.example^$denyallow=x.com
        example.com##+js(set-constant, x, 1)
        example.com##.ad:has-text(Sponsored)
        example.com#?#.ad:-abp-has(.x)
        example.com##^script:has-text(ad)
        example.com#$#abort-on-property-read x
        ||f.example^$webrtc
        /(a|b)/
        """
        let result = FilterListConverter.convert(text)
        #expect(result.skipped[.redirect] == 1)
        #expect(result.skipped[.removeparam] == 1)
        #expect(result.skipped[.csp] == 1)
        #expect(result.skipped[.replace] == 1)
        #expect(result.skipped[.unsupportedOption] == 1)
        #expect(result.skipped[.scriptlet] == 2)
        #expect(result.skipped[.proceduralCosmetic] == 2)
        #expect(result.skipped[.htmlFilter] == 1)
        #expect(result.skipped[.unsupportedResourceType] == 1)
        #expect(result.skipped[.regexUnsupported] == 1)
        #expect(result.lists.isEmpty)
    }

    @Test func badfilterDisablesRule() {
        let result = FilterListConverter.convert("||ads.example^$script\n||ads.example^$script,badfilter\n||other.example^")
        #expect(result.skipped[.badfilter] == 2)
        #expect(result.networkRuleCount == 1)
    }

    @Test func tooBroadRulesSkipped() {
        let result = FilterListConverter.convert("$popup,third-party\n*$script")
        #expect(result.skipped[.tooBroad] == 2)
    }

    // MARK: Cosmetic

    @Test func genericCosmeticsAreBatched() throws {
        let text = (0..<600).map { "##.ad-\($0)" }.joined(separator: "\n")
        let result = FilterListConverter.convert(text)
        let rules = try allRules(result)
        #expect(rules.count == 3) // 250 + 250 + 100
        #expect(rules.allSatisfy { actionType($0) == "css-display-none" && trigger($0)["if-domain"] == nil })
        #expect((action(rules[0])["selector"] as? String)?.hasPrefix(".ad-0, .ad-1, ") == true)
    }

    @Test func domainCosmeticsAndExceptions() throws {
        let text = """
        ##.banner
        ##.promo
        example.com,Example.org##.sidebar-ad
        news.com##.x
        ~shop.com##.tile-ad
        #@#.promo
        good.com#@#.banner
        a.com,~sub.a.com##.mixed
        sub.news.com#@#.x
        """
        let result = FilterListConverter.convert(text)
        let rules = try allRules(result)
        let selectors = rules.compactMap { action($0)["selector"] as? String }
        #expect(!selectors.contains { $0.contains(".promo") }) // global exception removes it

        let banner = try #require(rules.first { (action($0)["selector"] as? String) == ".banner" })
        #expect(trigger(banner)["unless-domain"] as? [String] == ["*good.com"])

        let tile = try #require(rules.first { (action($0)["selector"] as? String) == ".tile-ad" })
        #expect(trigger(tile)["unless-domain"] as? [String] == ["*shop.com"])

        let sidebar = try #require(rules.first { (action($0)["selector"] as? String) == ".sidebar-ad" })
        #expect(trigger(sidebar)["if-domain"] as? [String] == ["*example.com", "*example.org"])

        // Mixed include/exclude goes to the script index, not content rules.
        #expect(!selectors.contains(".mixed"))
        #expect(result.cosmetic.selectors(for: "www.a.com") == [".mixed"])
        #expect(result.cosmetic.selectors(for: "sub.a.com").isEmpty)
        // news.com##.x with sub.news.com#@#.x -> excluded subdomain -> script index.
        #expect(result.cosmetic.selectors(for: "news.com") == [".x"])
        #expect(result.cosmetic.selectors(for: "sub.news.com").isEmpty)
        #expect(result.cosmeticCSSByDomain["a.com"] == ".mixed{display:none!important}\n")
    }

    @Test func generichideOrdering() throws {
        let text = """
        ##.generic
        site.com##.specific
        @@||site.com^$generichide
        @@||off.com^$elemhide
        """
        let result = FilterListConverter.convert(text)
        #expect(result.lists.count == 1)
        let rules = try parseRules(result.lists[0])
        let order = rules.map { (action($0)["selector"] as? String) ?? ("ignore:" + ((trigger($0)["if-domain"] as? [String])?.first ?? "")) }
        #expect(order == [".generic", "ignore:*site.com", ".specific", "ignore:*off.com"])
    }

    @Test func invalidSelectorsSkipped() {
        let result = FilterListConverter.convert("##.a[href\n##.b{color:red}\n##div)")
        #expect(result.skipped[.invalidSelector] == 3)
    }

    @Test func networkPatternWithHashIsNotCosmetic() throws {
        let result = FilterListConverter.convert("||example.com/#ad")
        #expect(result.networkRuleCount == 1)
    }

    // MARK: Splitting

    @Test func splitsAtCapAndRepeatsExceptions() throws {
        var lines = (0..<1000).map { "||host\($0).example^" }
        lines.append("@@||host1.example/ok^")
        lines.append("@@||host2.example/ok^")
        let result = FilterListConverter.convert(lines.joined(separator: "\n"), maxRulesPerList: 300)
        #expect(result.lists.count == 4) // 298 blocks + 2 exceptions per list
        for json in result.lists {
            let rules = try parseRules(json)
            #expect(rules.count <= 300)
            #expect(rules.suffix(2).allSatisfy { actionType($0) == "ignore-previous-rules" })
            #expect(rules.dropLast(2).allSatisfy { actionType($0) == "block" })
        }
        #expect(result.networkRuleCount == 1000 + 4 * 2)
    }

    @Test func splitKeepsPairedRulesTogether() throws {
        let lines = (0..<50).map { "/ad\($0).js$script,domain=a.com|~sub.a.com" }
        let result = FilterListConverter.convert(lines.joined(separator: "\n"), maxRulesPerList: 7)
        for json in result.lists {
            let rules = try parseRules(json)
            #expect(rules.count % 2 == 0)
            #expect(actionType(rules.first!) == "block")
        }
    }

    @Test func starterListIsClean() throws {
        let text = try #require(bundledList("starter.txt"))
        let result = FilterListConverter.convert(text)
        #expect(result.totalSkipped == 0, "skipped: \(result.skipped)")
        #expect(result.networkRuleCount > 200)
        let rules = try allRules(result)
        #expect(invalidKeyProblem(rules) == nil)
        // Never block main sites.
        let blocks = rules.filter { actionType($0) == "block" && trigger($0)["if-domain"] == nil }.map(urlFilter)
        for url in ["https://www.google.com/", "https://www.facebook.com/", "https://www.youtube.com/",
                    "https://twitter.com/home", "https://www.amazon.com/", "https://www.linkedin.com/feed/"] {
            #expect(!blocks.contains { filterMatches($0, url) }, "blocks \(url)")
        }
        #expect(blocks.contains { filterMatches($0, "https://securepubads.g.doubleclick.net/tag/js/gpt.js") })
        #expect(blocks.contains { filterMatches($0, "https://www.google-analytics.com/analytics.js") })
    }
}
