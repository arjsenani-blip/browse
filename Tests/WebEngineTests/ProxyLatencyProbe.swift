import Foundation
import Testing
@testable import WebEngine

/// Manual probe (VANE_PROBE=1): connection latency direct vs through the DoH proxy per resolver.
@MainActor @Suite struct ProxyLatencyProbe {
    static let hosts = ["www.nytimes.com", "www.reddit.com", "news.ycombinator.com", "www.bbc.co.uk", "github.com",
                        "www.theverge.com", "stackoverflow.com", "www.apple.com"]

    func timeAll(_ config: URLSessionConfiguration) async -> [Double] {
        let s = URLSession(configuration: config)
        var out: [Double] = []
        for h in Self.hosts {
            var req = URLRequest(url: URL(string: "https://\(h)/robots.txt")!)
            req.timeoutInterval = 20
            let t = Date()
            _ = try? await s.data(for: req)
            out.append(Date().timeIntervalSince(t) * 1000)
        }
        s.invalidateAndCancel()
        return out
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VANE_PROBE"] == "1"))
    func probe() async throws {
        let direct = URLSessionConfiguration.ephemeral
        print("PROBE direct    ", (await timeAll(direct)).map { Int($0) })
        for r in [EncryptedDNSProxy.Resolver.quad9, .cloudflare, .mullvad, .off] {
            let proxy = EncryptedDNSProxy(resolver: r)
            _ = try await proxy.start()
            let c = URLSessionConfiguration.ephemeral
            c.proxyConfigurations = [try #require(proxy.proxyConfiguration)]
            print("PROBE \(r.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))", (await timeAll(c)).map { Int($0) })
            proxy.stop()
        }
    }
}
