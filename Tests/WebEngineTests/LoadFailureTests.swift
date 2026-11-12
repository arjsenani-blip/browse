import Foundation
import Testing
@testable import WebEngine

@Suite struct LoadFailureTests {
    func err(_ domain: String, _ code: Int) -> NSError { NSError(domain: domain, code: code) }

    @Test func cancellationsAndPolicyStopsShowNothing() {
        #expect(LoadFailure.action(for: err(NSURLErrorDomain, NSURLErrorCancelled)) == nil)
        #expect(LoadFailure.action(for: err("WebKitErrorDomain", 102)) == nil)
    }

    @Test func quickTransientFailuresRetryOnce() {
        for code in [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost, NSURLErrorBadURL] {
            #expect(LoadFailure.action(for: err(NSURLErrorDomain, code), after: 0.5) == .retry)
        }
        #expect(LoadFailure.action(for: err(kCFErrorDomainCFNetwork as String, 310), after: 1) == .retry)
    }

    @Test func slowOrPermanentFailuresShowThePage() {
        #expect(LoadFailure.action(for: err(NSURLErrorDomain, NSURLErrorTimedOut), after: 15) == .showPage)
        #expect(LoadFailure.action(for: err(NSURLErrorDomain, NSURLErrorNotConnectedToInternet)) == .showPage)
        #expect(LoadFailure.action(for: err(NSURLErrorDomain, NSURLErrorServerCertificateUntrusted)) == .showPage)
    }

    @Test func pageEscapesTheAddress() {
        let url = URL(string: "https://example.com/?q=%3Cscript%3E\"x")!
        let html = LoadFailure.page(for: err(NSURLErrorDomain, NSURLErrorTimedOut), url: url)
        #expect(!html.contains("<script>"))
        #expect(html.contains("Try Again"))
    }
}
