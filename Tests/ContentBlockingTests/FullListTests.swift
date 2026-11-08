import Foundation
import Testing
@testable import ContentBlocking

@Suite struct FullListTests {
    @Test func convertsEasyListAndEasyPrivacy() throws {
        let easylist = try #require(bundledList("easylist.txt"), "run scripts/update-filters.sh")
        let easyprivacy = try #require(bundledList("easyprivacy.txt"), "run scripts/update-filters.sh")
        let text = easylist + "\n" + easyprivacy

        let clock = ContinuousClock()
        var result: ConversionResult?
        let duration = clock.measure { result = FilterListConverter.convert(text) }
        let r = try #require(result)

        let skipped = r.skipped.sorted { $0.value > $1.value }.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: ", ")
        print("""
        [ContentBlocking] EasyList+EasyPrivacy: \(r.convertedFilterCount) filters -> \(r.ruleCount) rules \
        (network \(r.networkRuleCount), cosmetic \(r.cosmeticRuleCount)) in \(r.lists.count) lists, \
        skipped \(r.totalSkipped) [\(skipped)], script-only cosmetic domains \(r.cosmeticCSSByDomain.count), \
        took \(duration)
        """)

        #expect(r.ruleCount > 20_000)
        #expect(r.lists.count >= 2)
        for json in r.lists {
            let rules = try parseRules(json)
            #expect(rules.count <= FilterListConverter.maxRulesPerList)
            #expect(invalidKeyProblem(rules) == nil, "\(invalidKeyProblem(rules) ?? "")")
        }
        #if DEBUG
        #expect(duration < .seconds(30))
        #else
        #expect(duration < .seconds(5))
        #endif
    }
}
