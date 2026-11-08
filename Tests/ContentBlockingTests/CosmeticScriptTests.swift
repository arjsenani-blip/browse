import Foundation
import Testing
@testable import ContentBlocking

@Suite struct CosmeticScriptTests {
    let index: CosmeticIndex = FilterListConverter.convert("""
        ##.generic
        a.com,~sub.a.com##.mixed
        b.com##.covered
        good.com#@#.generic
        @@||nogeneric.com^$generichide
        @@||off.com^$elemhide
        off.com##.never
        """).cosmetic

    @Test func supplementModeOnlyReturnsUncoveredSelectors() throws {
        #expect(index.selectors(for: "a.com") == [".mixed"])
        #expect(index.selectors(for: "b.com").isEmpty)
        let js = try #require(CosmeticScript.source(for: "www.a.com", index: index))
        #expect(js.contains(#".mixed{display:none!important}\n"#))
        #expect(js.contains("createElement('style')"))
        #expect(CosmeticScript.source(for: "unrelated.com", index: index) == nil)
    }

    @Test func fullModeIncludesGenericAndRespectsExceptions() {
        #expect(Set(index.selectors(for: "b.com", mode: .full)) == [".covered", ".generic"])
        #expect(index.selectors(for: "good.com", mode: .full).isEmpty)
        #expect(index.selectors(for: "nogeneric.com", mode: .full).isEmpty)
        #expect(index.selectors(for: "off.com", mode: .full).isEmpty)
    }

    @Test func scriptEscapesCSS() throws {
        var idx = CosmeticIndex()
        idx.byDomain["q.com"] = [.init(selector: #"a[href*="x\"y"]"#, excludes: [], coveredByContentRules: false)]
        let js = try #require(CosmeticScript.source(for: "q.com", index: idx))
        #expect(js.contains(#"a[href*=\"x\\\"y\"]"#))
    }
}
