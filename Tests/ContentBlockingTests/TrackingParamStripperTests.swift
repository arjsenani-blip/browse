import Foundation
import Testing
@testable import ContentBlocking

@Suite struct TrackingParamStripperTests {
    @Test func stripsGlobalParams() {
        let url = URL(string: "https://example.com/a?id=5&utm_source=x&UTM_Medium=y&fbclid=abc&gclid=1#frag")!
        #expect(TrackingParamStripper.clean(url)?.absoluteString == "https://example.com/a?id=5#frag")
    }

    @Test func removesEmptyQuery() {
        let url = URL(string: "https://example.com/?utm_campaign=z&mc_eid=1")!
        #expect(TrackingParamStripper.clean(url)?.absoluteString == "https://example.com/")
    }

    @Test func unchangedReturnsNil() {
        #expect(TrackingParamStripper.clean(URL(string: "https://example.com/?q=utm_source")!) == nil)
        #expect(TrackingParamStripper.clean(URL(string: "https://example.com/")!) == nil)
        #expect(TrackingParamStripper.clean(URL(string: "mailto:a@b.com?utm_source=x")!) == nil)
    }

    @Test func preservesEncoding() {
        let url = URL(string: "https://example.com/s?q=a%20b%26c&msclkid=9")!
        #expect(TrackingParamStripper.clean(url)?.absoluteString == "https://example.com/s?q=a%20b%26c")
    }

    @Test func siteSpecific() {
        let amazon = URL(string: "https://www.amazon.co.uk/dp/B000?pd_rd_r=1&pf_rd_p=2&_encoding=UTF8&psc=1")!
        #expect(TrackingParamStripper.clean(amazon)?.absoluteString == "https://www.amazon.co.uk/dp/B000?psc=1")
        let yt = URL(string: "https://youtu.be/abc?si=XYZ&t=10")!
        #expect(TrackingParamStripper.clean(yt)?.absoluteString == "https://youtu.be/abc?t=10")
        // Site-specific params aren't stripped elsewhere.
        #expect(TrackingParamStripper.clean(URL(string: "https://example.com/?si=1&pd_rd_r=2")!) == nil)
    }
}
