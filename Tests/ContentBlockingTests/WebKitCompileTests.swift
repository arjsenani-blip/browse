import Foundation
import Testing
import WebKit
@testable import ContentBlocking

@MainActor
@Suite(.serialized) struct WebKitCompileTests {
    func temporaryStore() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aegis-cb-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func compilesSmallListAndCaches() async throws {
        let text = """
        ||doubleclick.net^
        ||cdn.example^$script,image,xmlhttprequest,websocket,ping,popup,other,font,media,stylesheet,third-party
        ||frames.example^$subdocument
        /banner\\d+\\.gif/
        &ad_type=^
        /ads.js$domain=a.com|~sub.a.com
        /ads.js$domain=~b.com
        @@||doubleclick.net/ok^
        @@||trusted.example^$document
        ||crit.example^$important
        /AdX.$match-case
        ##.ad-banner
        ##[id^="div-gpt-ad"]
        example.com##.sidebar-ad
        ~shop.com##.tile-ad
        good.com#@#.ad-banner
        @@||site.com^$generichide
        """
        let result = FilterListConverter.convert(text)
        #expect(result.totalSkipped == 0, "\(result.skipped)")
        let url = temporaryStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let compiler = ContentRuleCompiler(storeURL: url)
        let lists = await compiler.compile(result)
        #expect(compiler.lastError == nil, "\(String(describing: compiler.lastError))")
        #expect(lists.count == result.lists.count)
        #expect(lists.map(\.identifier) == result.lists.map(ContentRuleCompiler.identifier(for:)))

        // Cached lookup on a fresh compiler instance.
        let cached = await ContentRuleCompiler(storeURL: url).lookUpCached(result.lists)
        #expect(cached?.count == result.lists.count)
    }

    @Test func keepsLastGoodOnFailure() async throws {
        let url = temporaryStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let compiler = ContentRuleCompiler(storeURL: url)
        let good = FilterListConverter.convert("||ads.example^").lists
        let first = await compiler.compile(good)
        #expect(first.count == 1)

        let bad = [#"[{"trigger":{"url-filter":"(a|b)"},"action":{"type":"block"}}]"#]
        let second = await compiler.compile(bad)
        #expect(compiler.lastError != nil)
        #expect(second.map(\.identifier) == first.map(\.identifier))
    }

    @Test func prunesStaleLists() async throws {
        let url = temporaryStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let compiler = ContentRuleCompiler(storeURL: url)
        let a = FilterListConverter.convert("||a.example^").lists
        let b = FilterListConverter.convert("||b.example^").lists
        await compiler.compile(a)
        await compiler.compile(b)
        #expect(await compiler.lookUpCached(a) == nil)
        #expect(await compiler.lookUpCached(b)?.count == 1)
    }

    /// Compiles the real EasyList + EasyPrivacy output with WebKit (the real validator of the regex subset).
    @Test func compilesFullEasyList() async throws {
        guard let easylist = bundledList("easylist.txt"), let easyprivacy = bundledList("easyprivacy.txt") else { return }
        let result = FilterListConverter.convert(easylist + "\n" + easyprivacy)
        let url = temporaryStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let compiler = ContentRuleCompiler(storeURL: url)
        let clock = ContinuousClock()
        let start = clock.now
        for json in result.lists {
            do {
                _ = try await compiler.compileOne(json)
            } catch {
                Issue.record("WebKit rejected a list (\(json.count) bytes): \(error)")
            }
        }
        print("[ContentBlocking] WebKit cold compile of \(result.lists.count) lists / \(result.ruleCount) rules took \(clock.now - start)")
        let warmStart = clock.now
        let cached = await compiler.lookUpCached(result.lists)
        print("[ContentBlocking] warm lookup took \(clock.now - warmStart)")
        #expect(cached?.count == result.lists.count)
    }
}
