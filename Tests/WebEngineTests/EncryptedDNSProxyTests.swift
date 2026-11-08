import Foundation
import Network
import Testing
import WebKit
@testable import WebEngine

// MARK: - Parser (offline)

@Suite struct ProxyRequestParsingTests {
    @Test func parsesConnect() throws {
        let req = try ProxyRequest.parse(head: Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nProxy-Authorization: Basic abc".utf8))
        #expect(req.kind == .tunnel)
        #expect(req.host == "example.com")
        #expect(req.port == 443)
        #expect(req.proxyAuthorization == "Basic abc")
    }

    @Test func parsesIPv6Connect() throws {
        let req = try ProxyRequest.parse(head: Data("CONNECT [2606:4700::1]:8443 HTTP/1.1".utf8))
        #expect(req.host == "2606:4700::1")
        #expect(req.port == 8443)
    }

    @Test func rewritesAbsoluteFormToOriginForm() throws {
        let head = "GET http://neverssl.com/a/b?q=1#frag HTTP/1.1\r\nHost: neverssl.com\r\nProxy-Connection: keep-alive\r\nProxy-Authorization: Basic x\r\nAccept: */*"
        let req = try ProxyRequest.parse(head: Data(head.utf8))
        #expect(req.host == "neverssl.com")
        #expect(req.port == 80)
        guard case .forward(let out) = req.kind else { Issue.record("not forward"); return }
        let text = String(decoding: out, as: UTF8.self)
        #expect(text.hasPrefix("GET /a/b?q=1 HTTP/1.1\r\n"))
        #expect(text.contains("Host: neverssl.com\r\n"))
        #expect(text.contains("Accept: */*\r\n"))
        #expect(!text.lowercased().contains("proxy-"))
        #expect(text.hasSuffix("Connection: close\r\n\r\n"))
    }

    @Test func absoluteFormWithPortAndNoPath() throws {
        let req = try ProxyRequest.parse(head: Data("POST http://example.com:8080 HTTP/1.1".utf8))
        #expect(req.port == 8080)
        guard case .forward(let out) = req.kind else { Issue.record("not forward"); return }
        #expect(String(decoding: out, as: UTF8.self).hasPrefix("POST / HTTP/1.1\r\nHost: example.com:8080\r\n"))
    }

    @Test(arguments: [
        "hello world",
        "GARBAGE",
        "CONNECT example.com HTTP/1.1",          // no port
        "CONNECT example.com:0 HTTP/1.1",
        "CONNECT example.com:99999 HTTP/1.1",
        "CONNECT exa mple.com:443 HTTP/1.1",
        "CONNECT ex\u{0}ample.com:443 HTTP/1.1",
        "GET http://example.com/ SPDY/3",
    ])
    func rejectsMalformed(head: String) {
        #expect(throws: ProxyRequest.ParseError.self) { try ProxyRequest.parse(head: Data(head.utf8)) }
    }

    @Test(arguments: ["GET / HTTP/1.1", "GET https://example.com/ HTTP/1.1", "GET ftp://x/ HTTP/1.1"])
    func rejectsNonProxyTargets(head: String) {
        #expect(throws: ProxyRequest.ParseError.unsupported) { try ProxyRequest.parse(head: Data(head.utf8)) }
    }

    @Test func loopbackCheck() {
        #expect(ProxyEngine.isLoopback(.hostPort(host: "127.0.0.1", port: 1)))
        #expect(ProxyEngine.isLoopback(.hostPort(host: "::1", port: 1)))
        #expect(!ProxyEngine.isLoopback(.hostPort(host: "192.168.1.2", port: 1)))
    }
}

// MARK: - Live (needs network)

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct EncryptedDNSProxyTests {
    private func session(with proxy: EncryptedDNSProxy) throws -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // Same nw_proxy_config path WebKit uses, including the credential.
        config.proxyConfigurations = [try #require(proxy.proxyConfiguration)]
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }

    private func status(_ session: URLSession, _ url: String) async throws -> Int {
        let (_, response) = try await session.data(from: URL(string: url)!)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    @Test func fetchesThroughProxyWithCredentials() async throws {
        let proxy = EncryptedDNSProxy(resolver: .quad9)
        defer { proxy.stop() }
        let port = try await proxy.start()
        #expect(port > 0)
        let reports = ReportBox()
        proxy.engine.setEstablishmentReportHandler { reports.append($0) }
        let session = try session(with: proxy)
        #expect(try await status(session, "https://example.com/") == 200)
        // Plain http:// (absolute-form forwarding). neverssl.com was too flaky
        // from the dev network even without the proxy, so use example.com.
        #expect(try await status(session, "http://example.com/") == 200)
        try await Task.sleep(for: .milliseconds(200))
        #expect(reports.all.count >= 2, "requests should have gone through the proxy")
    }

    @Test func fetchesViaConnectionProxyDictionary() async throws {
        // The legacy dictionary carries no credential, so this proxy runs unauthenticated.
        let proxy = EncryptedDNSProxy(resolver: .cloudflare, requiresAuthentication: false)
        defer { proxy.stop() }
        let port = Int(try await proxy.start())
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
        ]
        let session = URLSession(configuration: config)
        #expect(try await status(session, "https://example.com/") == 200)
        // Plain http:// (absolute-form forwarding). neverssl.com was too flaky
        // from the dev network even without the proxy, so use example.com.
        #expect(try await status(session, "http://example.com/") == 200)
    }

    @Test func resolverSwitchesAtRuntime() async throws {
        let proxy = EncryptedDNSProxy(resolver: .quad9)
        defer { proxy.stop() }
        try await proxy.start()
        proxy.resolver = .mullvad
        #expect(try await status(try session(with: proxy), "https://example.com/") == 200)
        proxy.resolver = .off
        #expect(try await status(try session(with: proxy), "https://example.com/") == 200)
    }

    @Test func garbageGets400() async throws {
        let proxy = EncryptedDNSProxy()
        defer { proxy.stop() }
        let port = try await proxy.start()
        let reply = try await RawClient.exchange(port: port, send: "HELLO there\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 400"))
    }

    @Test func originFormGets400() async throws {
        let proxy = EncryptedDNSProxy(requiresAuthentication: false)
        defer { proxy.stop() }
        let port = try await proxy.start()
        let reply = try await RawClient.exchange(port: port, send: "GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 400"))
    }

    @Test func oversizedHeaderRejected() async throws {
        let proxy = EncryptedDNSProxy(requiresAuthentication: false)
        defer { proxy.stop() }
        let port = try await proxy.start()
        let big = "CONNECT example.com:443 HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: 20_000) + "\r\n\r\n"
        let reply = try await RawClient.exchange(port: port, send: big)
        #expect(reply.hasPrefix("HTTP/1.1 431"))
    }

    @Test func missingCredentialGets407() async throws {
        let proxy = EncryptedDNSProxy()
        defer { proxy.stop() }
        let port = try await proxy.start()
        let reply = try await RawClient.exchange(port: port, send: "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 407"))
        #expect(reply.contains("Proxy-Authenticate: Basic"))
    }

    @Test func unknownHostFailsCleanly() async throws {
        let proxy = EncryptedDNSProxy(requiresAuthentication: false)
        defer { proxy.stop() }
        let port = try await proxy.start()
        let started = Date()
        let reply = try await RawClient.exchange(port: port, send: "CONNECT no-such-host.invalid:443 HTTP/1.1\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 502"))
        #expect(Date().timeIntervalSince(started) < 15)

        // And through URLSession: an error, not a hang.
        let session = try session(with: proxy)
        await #expect(throws: (any Error).self) { _ = try await session.data(from: URL(string: "https://no-such-host.invalid/")!) }
    }

    @Test func proxyConfigurationNilUntilStarted() async throws {
        let proxy = EncryptedDNSProxy()
        #expect(proxy.proxyConfiguration == nil)
        try await proxy.start()
        #expect(proxy.proxyConfiguration != nil)
        proxy.stop()
        #expect(proxy.proxyConfiguration == nil)
    }

    /// Evidence that the outbound connection resolved over DoH: the
    /// establishment report's resolution step should say `.https`.
    @Test func upstreamResolutionUsesHTTPS() async throws {
        let proxy = EncryptedDNSProxy(resolver: .quad9)
        defer { proxy.stop() }
        try await proxy.start()
        let reports = ReportBox()
        proxy.engine.setEstablishmentReportHandler { reports.append($0) }
        // A host unlikely to be in any cache, so the report shows a real query.
        _ = try await status(try session(with: proxy), "https://www.wikipedia.org/")
        try await Task.sleep(for: .milliseconds(500))
        let all = reports.all
        let resolutions = all.flatMap(\.resolutions)
        for r in resolutions {
            print("[DoH evidence] source=\(r.source) dnsProtocol=\(r.dnsProtocol) duration=\(r.duration) endpoints=\(r.endpointCount)")
        }
        #expect(!resolutions.isEmpty)
        #expect(resolutions.allSatisfy { $0.dnsProtocol == .https || $0.source != .query })
        #expect(resolutions.contains { $0.dnsProtocol == .https })
    }
}

extension EncryptedDNSProxyTests {
    /// Control: with `.off` the same report should show cleartext DNS.
    @Test func offUsesSystemResolver() async throws {
        let proxy = EncryptedDNSProxy(resolver: .off)
        defer { proxy.stop() }
        try await proxy.start()
        let reports = ReportBox()
        proxy.engine.setEstablishmentReportHandler { reports.append($0) }
        _ = try await status(try session(with: proxy), "https://www.mozilla.org/")
        try await Task.sleep(for: .milliseconds(500))
        for r in reports.all.flatMap(\.resolutions) {
            print("[DoH control .off] source=\(r.source) dnsProtocol=\(r.dnsProtocol)")
        }
        #expect(!reports.all.isEmpty)
        #expect(!reports.all.flatMap(\.resolutions).contains { $0.dnsProtocol == .https })
    }
}

final class ReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [NWConnection.EstablishmentReport] = []
    func append(_ r: NWConnection.EstablishmentReport) { lock.withLock { items.append(r) } }
    var all: [NWConnection.EstablishmentReport] { lock.withLock { items } }
}

/// Sends raw bytes to the proxy and returns everything it replies before closing.
enum RawClient {
    static func exchange(port: UInt16, send text: String) async throws -> String {
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "raw-client")
        let box = ReplyBox()
        return try await withCheckedThrowingContinuation { cont in
            box.cont = cont
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: Data(text.utf8), completion: .idempotent)
                    receive(conn, box)
                case .failed(let e), .waiting(let e): box.finish(.failure(e)); conn.cancel()
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 20) { box.finish(.success(box.text)); conn.cancel() }
        }
    }

    private static func receive(_ conn: NWConnection, _ box: ReplyBox) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            if let data { box.data.append(data) }
            if done || error != nil { box.finish(.success(box.text)); conn.cancel() } else { receive(conn, box) }
        }
    }

    // Accessed only on the client's serial queue.
    final class ReplyBox: @unchecked Sendable {
        var data = Data()
        var cont: CheckedContinuation<String, Error>?
        var text: String { String(decoding: data, as: UTF8.self) }
        func finish(_ r: Result<String, Error>) { cont?.resume(with: r); cont = nil }
    }
}


extension EncryptedDNSProxyTests {
    /// The real consumer: WKWebsiteDataStore.proxyConfigurations with the
    /// per-launch credential (auth required) loads a page, and the upstream
    /// resolution is DoH.
    @Test func webKitUsesProxyCredentialAndDoH() async throws {
        let proxy = EncryptedDNSProxy(resolver: .quad9)
        defer { proxy.stop() }
        try await proxy.start()
        let reports = ReportBox()
        proxy.engine.setEstablishmentReportHandler { reports.append($0) }
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [try #require(proxy.proxyConfiguration)]
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600), configuration: config)
        final class D: NSObject, WKNavigationDelegate {
            var done: CheckedContinuation<String, Never>?
            func webView(_ w: WKWebView, didFinish n: WKNavigation!) { done?.resume(returning: "finished \(w.title ?? "")"); done = nil }
            func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { done?.resume(returning: "failed \(e)"); done = nil }
            func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { done?.resume(returning: "failed \(e)"); done = nil }
        }
        let d = D()
        view.navigationDelegate = d
        let result = await withCheckedContinuation { c in d.done = c; view.load(URLRequest(url: URL(string: "https://example.com/")!)) }
        try await Task.sleep(for: .milliseconds(300))
        print("[WebKit] \(result); proxied=\(reports.all.count) dns=\(reports.all.flatMap(\.resolutions).map { "\($0.dnsProtocol)" })")
        #expect(result.hasPrefix("finished"))
        #expect(!reports.all.isEmpty, "WebKit should connect through the proxy with its credential")
        #expect(reports.all.flatMap(\.resolutions).contains { $0.dnsProtocol == .https })
    }
}
