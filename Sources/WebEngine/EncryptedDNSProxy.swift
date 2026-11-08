import Foundation
import Network
import Security
import os

/// DNS-over-HTTPS for web content via a loopback HTTP proxy.
///
/// WKWebView does its networking in WebKit's out-of-process Network process and
/// ignores app-level `NWParameters.PrivacyContext` settings, so the app can't make
/// WebKit resolve names over DoH directly. Instead, this runs a small HTTP proxy
/// on `127.0.0.1` and each `WKWebsiteDataStore` points at it through
/// `proxyConfigurations = [proxy.proxyConfiguration!]`. WebKit then asks the proxy
/// to `CONNECT host:443` (or sends absolute-form `GET http://…` for plain HTTP),
/// so hostnames reach the proxy unresolved. The proxy opens the outbound TCP
/// connection with a privacy context that requires encrypted name resolution,
/// and the chosen DoH server is the fallback resolver.
///
/// Security:
/// - The listener binds to 127.0.0.1 only and drops peers that aren't loopback.
/// - Each launch generates a random username and password. They go into the
///   `ProxyConfiguration` through `applyCredential(username:password:)`, and the
///   proxy requires a matching `Proxy-Authorization: Basic …` header. That stops
///   other local processes from using the proxy as an open relay. Pass
///   `requiresAuthentication: false` to rely on loopback-only binding instead.
///
/// Limitations:
/// - Under a proxy WebKit can't use HTTP/3 (QUIC is UDP and CONNECT carries only
///   TCP), so it falls back to HTTP/2 or HTTP/1.1 over TCP.
/// - WebRTC media and ICE traffic (UDP) doesn't go through the proxy. Disable
///   WebRTC or restrict ICE candidates if that matters.
/// - If the system already has an encrypted resolver (an MDM or user DNS
///   settings profile), Network.framework uses that one instead of the fallback
///   resolver configured here. Resolution is still encrypted.
/// - `.off` keeps the proxy running but resolves through the system resolver,
///   which is usually cleartext port-53 DNS. The caller can remove the
///   proxy configuration from the data stores instead.
/// - Hosts given as IP literals (`CONNECT 1.2.3.4:443`) need no resolution.
@MainActor
public final class EncryptedDNSProxy {
    /// Which DoH server resolves hostnames for proxied connections.
    public enum Resolver: String, Sendable, CaseIterable, Codable {
        case quad9
        case cloudflare
        case mullvad
        /// No encrypted DNS: outbound connections use the system resolver.
        case off

        public var displayName: String {
            switch self {
            case .quad9: "Quad9"
            case .cloudflare: "Cloudflare"
            case .mullvad: "Mullvad"
            case .off: "Off (system DNS)"
            }
        }

        /// The RFC 8484 endpoint, or nil for `.off`.
        public var dohURL: URL? {
            switch self {
            case .quad9: URL(string: "https://dns.quad9.net/dns-query")
            case .cloudflare: URL(string: "https://cloudflare-dns.com/dns-query")
            case .mullvad: URL(string: "https://dns.mullvad.net/dns-query")
            case .off: nil
            }
        }

        /// Bootstrap addresses so reaching the DoH server never needs cleartext DNS.
        var serverAddresses: [String] {
            switch self {
            case .quad9: ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"]
            case .cloudflare: ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"]
            case .mullvad: ["194.242.2.2", "2a07:e340::2"]
            case .off: []
            }
        }

        var resolverConfiguration: NWParameters.PrivacyContext.ResolverConfiguration? {
            guard let url = dohURL else { return nil }
            let addresses = serverAddresses.map { NWEndpoint.hostPort(host: NWEndpoint.Host($0), port: 443) }
            return .https(url, serverAddresses: addresses)
        }
    }

    public enum ProxyError: Error, Sendable {
        case listenerFailed(String)
        case alreadyStopped
    }

    /// New outbound connections use the current resolver. Open tunnels keep the
    /// connection they already have.
    public var resolver: Resolver {
        didSet { if resolver != oldValue { engine.setResolver(resolver) } }
    }

    /// The bound port while running, otherwise nil.
    public private(set) var port: UInt16?

    public var isRunning: Bool { port != nil }

    /// A configuration for `WKWebsiteDataStore.proxyConfigurations`, or nil when
    /// the proxy isn't running. Set it before the data store's first load.
    public var proxyConfiguration: ProxyConfiguration? {
        guard let port, let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        var config = ProxyConfiguration(
            httpCONNECTProxy: .hostPort(host: .ipv4(.loopback), port: nwPort),
            tlsOptions: nil
        )
        // A dead proxy must not fail over to a direct connection with cleartext DNS.
        config.allowFailover = false
        if let credential { config.applyCredential(username: credential.username, password: credential.password) }
        return config
    }

    let engine: ProxyEngine
    private let credential: ProxyCredential?

    public init(resolver: Resolver = .quad9, requiresAuthentication: Bool = true) {
        self.resolver = resolver
        let credential = requiresAuthentication ? ProxyCredential.random() : nil
        self.credential = credential
        engine = ProxyEngine(resolver: resolver, expectedAuthorization: credential?.headerValue)
    }

    deinit { engine.stop() }

    /// Binds a listener on 127.0.0.1 at a random port and returns that port.
    /// Calling it again while running returns the current port.
    @discardableResult
    public func start() async throws -> UInt16 {
        if let port { return port }
        let bound = try await engine.start()
        port = bound
        return bound
    }

    /// Stops the listener and closes every open tunnel.
    public func stop() {
        engine.stop()
        port = nil
    }
}

// MARK: - Credentials

struct ProxyCredential: Sendable {
    let username: String
    let password: String

    var headerValue: String { "Basic " + Data("\(username):\(password)".utf8).base64EncodedString() }

    static func random() -> ProxyCredential {
        ProxyCredential(username: "aegis-" + randomToken(byteCount: 8), password: randomToken(byteCount: 32))
    }

    private static func randomToken(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Engine

/// Listener and session bookkeeping. All mutable state is confined to `queue`.
final class ProxyEngine: @unchecked Sendable {
    static let maxHeaderBytes = 16 * 1024
    static let connectTimeout: DispatchTimeInterval = .seconds(15)
    static let headerTimeout: DispatchTimeInterval = .seconds(15)
    static let idleTimeout: TimeInterval = 300
    static let maxSessions = 1024

    let queue = DispatchQueue(label: "aegis.dns-proxy")
    let log = Logger(subsystem: "app.aegis.browser", category: "EncryptedDNSProxy")
    let expectedAuthorization: String?

    // queue-confined
    private var listener: NWListener?
    private var resolver: EncryptedDNSProxy.Resolver
    private var privacyContext: NWParameters.PrivacyContext?
    private var sessions: [ObjectIdentifier: ProxySession] = [:]
    private(set) var listenPort: UInt16 = 0
    private var startContinuation: CheckedContinuation<UInt16, Error>?

    /// Diagnostics hook, called on `queue` when an outbound connection becomes ready.
    var establishmentReportHandler: (@Sendable (NWConnection.EstablishmentReport) -> Void)?

    init(resolver: EncryptedDNSProxy.Resolver, expectedAuthorization: String?) {
        self.resolver = resolver
        self.expectedAuthorization = expectedAuthorization
        privacyContext = Self.makePrivacyContext(for: resolver)
    }

    static func makePrivacyContext(for resolver: EncryptedDNSProxy.Resolver) -> NWParameters.PrivacyContext? {
        guard let fallback = resolver.resolverConfiguration else { return nil }
        // Each proxy gets its own context, so each profile gets its own DNS cache.
        let context = NWParameters.PrivacyContext(description: "Aegis encrypted DNS (\(resolver.rawValue))")
        context.requireEncryptedNameResolution(true, fallbackResolver: fallback)
        context.disableLogging()
        return context
    }

    func setResolver(_ resolver: EncryptedDNSProxy.Resolver) {
        queue.async {
            self.resolver = resolver
            self.privacyContext = Self.makePrivacyContext(for: resolver)
        }
    }

    func setEstablishmentReportHandler(_ handler: (@Sendable (NWConnection.EstablishmentReport) -> Void)?) {
        queue.sync { establishmentReportHandler = handler }
    }

    /// Fresh outbound parameters for one upstream connection.
    func outboundParameters() -> NWParameters {
        dispatchPrecondition(condition: .onQueue(queue))
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 15
        let params = NWParameters(tls: nil, tcp: tcp)
        if let privacyContext { params.setPrivacyContext(privacyContext) }
        return params
    }

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = false
        let listener: NWListener
        do { listener = try NWListener(using: params) } catch {
            throw EncryptedDNSProxy.ProxyError.listenerFailed(String(describing: error))
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(throwing: EncryptedDNSProxy.ProxyError.alreadyStopped); return }
                self.startContinuation = cont
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self, listener] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        let port = listener.port?.rawValue ?? 0
                        self.listenPort = port
                        self.finishStart(.success(port))
                    case .failed(let error):
                        self.log.error("Proxy listener failed: \(String(describing: error), privacy: .public)")
                        listener.cancel()
                        self.finishStart(.failure(EncryptedDNSProxy.ProxyError.listenerFailed(String(describing: error))))
                    case .cancelled:
                        if self.listener === listener { self.listener = nil }
                        self.finishStart(.failure(EncryptedDNSProxy.ProxyError.alreadyStopped))
                    default:
                        break
                    }
                }
                listener.start(queue: self.queue)
            }
        }
    }

    private func finishStart(_ result: Result<UInt16, Error>) {
        guard let cont = startContinuation else { return }
        startContinuation = nil
        cont.resume(with: result)
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.finishStart(.failure(EncryptedDNSProxy.ProxyError.alreadyStopped))
            self.listenPort = 0
            let open = Array(self.sessions.values)
            self.sessions.removeAll()
            open.forEach { $0.close() }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint), sessions.count < Self.maxSessions else {
            connection.cancel()
            return
        }
        let session = ProxySession(client: connection, engine: self)
        sessions[ObjectIdentifier(session)] = session
        session.start()
    }

    func sessionDidClose(_ session: ProxySession) {
        sessions[ObjectIdentifier(session)] = nil
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address):
            if address.isLoopback { return true }
            // IPv4-mapped loopback (::ffff:127.0.0.1).
            return address.asIPv4?.isLoopback ?? false
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }
}

// MARK: - Request parsing

/// A parsed proxy request head. Pure, so it's unit-testable.
struct ProxyRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// `CONNECT host:port`
        case tunnel
        /// Absolute-form `http://` request, already rewritten to origin-form.
        case forward(head: Data)
    }

    var kind: Kind
    var host: String
    var port: UInt16
    var proxyAuthorization: String?

    enum ParseError: Error, Equatable { case malformed, unsupported }

    private static let methodChars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~")

    /// Parses a request head (the bytes before the blank line, without it).
    static func parse(head: Data) throws(ParseError) -> ProxyRequest {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else {
            throw .malformed
        }
        var lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { throw .malformed }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              !parts[0].isEmpty, parts[0].allSatisfy({ methodChars.contains($0) }),
              parts[2].hasPrefix("HTTP/1.")
        else { throw .malformed }
        let method = String(parts[0])
        let target = String(parts[1])
        let version = String(parts[2])

        var headers: [(name: String, value: String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw .malformed }
            let name = String(line[..<colon])
            guard !name.contains(" "), !name.contains("\t") else { throw .malformed }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        let auth = headers.first { $0.name.caseInsensitiveCompare("Proxy-Authorization") == .orderedSame }?.value

        if method == "CONNECT" {
            guard let (host, port) = parseAuthority(target, defaultPort: nil) else { throw .malformed }
            return ProxyRequest(kind: .tunnel, host: host, port: port, proxyAuthorization: auth)
        }

        // Absolute-form, http only. https:// URLs always arrive as CONNECT.
        guard target.lowercased().hasPrefix("http://") else { throw .unsupported }
        let afterScheme = target.dropFirst("http://".count)
        let authorityEnd = afterScheme.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? afterScheme.endIndex
        var authority = String(afterScheme[..<authorityEnd])
        if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
        guard let (host, port) = parseAuthority(authority, defaultPort: 80) else { throw .malformed }
        var path = String(afterScheme[authorityEnd...])
        if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
        if path.isEmpty || path.hasPrefix("?") { path = "/" + path }

        // Rewrite: origin-form target, drop hop-by-hop proxy headers, force one
        // request per upstream connection so a keep-alive client can't send its
        // next request (maybe for another host) down this tunnel.
        var out = "\(method) \(path) \(version)\r\n"
        var sawHost = false
        for (name, value) in headers {
            let lower = name.lowercased()
            if lower == "proxy-authorization" || lower == "proxy-connection" || lower == "connection" || lower == "keep-alive" {
                continue
            }
            if lower == "host" { sawHost = true }
            out += "\(name): \(value)\r\n"
        }
        if !sawHost { out += "Host: \(authority)\r\n" }
        out += "Connection: close\r\n\r\n"
        return ProxyRequest(kind: .forward(head: Data(out.utf8)), host: host, port: port, proxyAuthorization: auth)
    }

    /// `host:port`, `[v6]:port`, or a bare host when `defaultPort` is given.
    static func parseAuthority(_ authority: String, defaultPort: UInt16?) -> (String, UInt16)? {
        var host: Substring
        var portText: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = authority[authority.index(after: authority.startIndex)..<close]
            let rest = authority[authority.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return nil }
                portText = rest.dropFirst()
            }
            guard IPv6Address(String(host)) != nil else { return nil }
        } else {
            if let colon = authority.lastIndex(of: ":") {
                host = authority[..<colon]
                portText = authority[authority.index(after: colon)...]
            } else {
                host = Substring(authority)
            }
            // Hostname or IPv4 literal: letters, digits, '-', '.', '_'.
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
            guard !host.isEmpty, host.count <= 253,
                  host.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) })
            else { return nil }
        }
        guard !host.isEmpty else { return nil }
        let port: UInt16
        if let portText {
            guard let value = UInt16(portText), value > 0 else { return nil }
            port = value
        } else if let defaultPort {
            port = defaultPort
        } else {
            return nil
        }
        return (String(host), port)
    }
}

// MARK: - Session

/// One client connection: reads the request head, opens the upstream with
/// encrypted DNS, then splices bytes both ways. Confined to the engine's queue.
final class ProxySession: @unchecked Sendable {
    private let client: NWConnection
    private var upstream: NWConnection?
    private unowned let engine: ProxyEngine
    private var queue: DispatchQueue { engine.queue }

    private var buffer = Data()
    private var closed = false
    private var connectTimer: DispatchWorkItem?
    private var headerTimer: DispatchWorkItem?
    private var idleTimer: DispatchSourceTimer?
    private var lastActivity = Date()
    private var halfClosed: Set<Direction> = []
    private var established = false

    private enum Direction { case clientToUpstream, upstreamToClient }

    init(client: NWConnection, engine: ProxyEngine) {
        self.client = client
        self.engine = engine
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        client.start(queue: queue)
        let timer = DispatchWorkItem { [weak self] in self?.respondAndClose(408, "Request Timeout") }
        headerTimer = timer
        queue.asyncAfter(deadline: .now() + ProxyEngine.headerTimeout, execute: timer)
        readHead()
    }

    // MARK: Head

    private func readHead() {
        client.receive(minimumIncompleteLength: 1, maximumLength: ProxyEngine.maxHeaderBytes) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            if let end = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.headerTimer?.cancel()
                let head = self.buffer[..<end.lowerBound]
                let rest = self.buffer[end.upperBound...]
                self.handle(head: Data(head), leftover: Data(rest))
                self.buffer = Data()
            } else if self.buffer.count >= ProxyEngine.maxHeaderBytes {
                self.respondAndClose(431, "Request Header Fields Too Large")
            } else if error != nil || isComplete {
                self.respondAndClose(400, "Bad Request")
            } else {
                self.readHead()
            }
        }
    }

    private func handle(head: Data, leftover: Data) {
        let request: ProxyRequest
        do { request = try ProxyRequest.parse(head: head) } catch {
            respondAndClose(400, "Bad Request")
            return
        }
        if let expected = engine.expectedAuthorization {
            guard let given = request.proxyAuthorization, Self.constantTimeEqual(given, expected) else {
                respondAndClose(407, "Proxy Authentication Required", extraHeaders: "Proxy-Authenticate: Basic realm=\"Aegis\"\r\n")
                return
            }
        }
        // Don't let a request loop back into the proxy itself.
        if request.port == engine.listenPort, ["127.0.0.1", "::1", "localhost"].contains(request.host.lowercased()) {
            respondAndClose(400, "Bad Request")
            return
        }
        engine.log.debug("Proxy \(request.kind == .tunnel ? "CONNECT" : "forward", privacy: .public) \(request.host, privacy: .private):\(request.port, privacy: .public)")
        openUpstream(for: request, leftover: leftover)
    }

    // MARK: Upstream

    private func openUpstream(for request: ProxyRequest, leftover: Data) {
        guard let port = NWEndpoint.Port(rawValue: request.port) else { respondAndClose(400, "Bad Request"); return }
        let connection = NWConnection(host: NWEndpoint.Host(request.host), port: port, using: engine.outboundParameters())
        upstream = connection

        let timer = DispatchWorkItem { [weak self] in self?.respondAndClose(504, "Gateway Timeout") }
        connectTimer = timer
        queue.asyncAfter(deadline: .now() + ProxyEngine.connectTimeout, execute: timer)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                guard !self.established else { return }
                self.established = true
                self.connectTimer?.cancel()
                if let handler = self.engine.establishmentReportHandler {
                    connection.requestEstablishmentReport(queue: self.queue) { report in
                        if let report { handler(report) }
                    }
                }
                self.upstreamReady(request: request, leftover: leftover)
            case .waiting(let error), .failed(let error):
                // .waiting covers DNS failures (NXDOMAIN, or a blocked cleartext
                // query). The browser retries on its own; don't hold the client.
                if self.established { self.close(); return }
                self.engine.log.debug("Proxy upstream failed: \(String(describing: error), privacy: .private)")
                self.respondAndClose(502, "Bad Gateway")
            case .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func upstreamReady(request: ProxyRequest, leftover: Data) {
        guard let upstream else { return }
        startIdleTimer()
        switch request.kind {
        case .tunnel:
            client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                if error != nil { self.close(); return }
                self.beginSplice(firstUpstreamBytes: leftover)
            })
        case .forward(let head):
            upstream.send(content: head, completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                if error != nil { self.close(); return }
                self.beginSplice(firstUpstreamBytes: leftover)
            })
        }
    }

    // MARK: Splice

    private func beginSplice(firstUpstreamBytes: Data) {
        guard let upstream else { return }
        if firstUpstreamBytes.isEmpty {
            startPumps()
        } else {
            upstream.send(content: firstUpstreamBytes, completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                if error != nil { self.close(); return }
                self.startPumps()
            })
        }
    }

    private func startPumps() {
        guard !closed, let upstream else { return }
        pump(from: client, to: upstream, direction: .clientToUpstream)
        pump(from: upstream, to: client, direction: .upstreamToClient)
    }

    /// receive → send → receive: the next read waits for the previous write to
    /// be processed, so a slow side applies backpressure to the fast one.
    private func pump(from source: NWConnection, to sink: NWConnection, direction: Direction) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if error != nil { self.close(); return }
            if let data, !data.isEmpty {
                self.lastActivity = Date()
                sink.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self, !self.closed else { return }
                    if error != nil { self.close(); return }
                    self.afterWrite(from: source, to: sink, direction: direction, isComplete: isComplete)
                })
            } else {
                self.afterWrite(from: source, to: sink, direction: direction, isComplete: isComplete)
            }
        }
    }

    private func afterWrite(from source: NWConnection, to sink: NWConnection, direction: Direction, isComplete: Bool) {
        guard isComplete else { pump(from: source, to: sink, direction: direction); return }
        // Pass the half-close on; tear down once both directions are done.
        sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            guard let self, !self.closed else { return }
            self.halfClosed.insert(direction)
            if self.halfClosed.count == 2 { self.close() }
        })
    }

    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = min(ProxyEngine.idleTimeout / 4, 30)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastActivity) > ProxyEngine.idleTimeout { self.close() }
        }
        timer.resume()
        idleTimer = timer
    }

    // MARK: Teardown

    private func respondAndClose(_ code: Int, _ reason: String, extraHeaders: String = "") {
        guard !closed else { return }
        connectTimer?.cancel()
        headerTimer?.cancel()
        upstream?.cancel()
        let response = "HTTP/1.1 \(code) \(reason)\r\n\(extraHeaders)Content-Length: 0\r\nConnection: close\r\n\r\n"
        client.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        connectTimer?.cancel()
        headerTimer?.cancel()
        idleTimer?.cancel()
        idleTimer = nil
        client.stateUpdateHandler = nil
        upstream?.stateUpdateHandler = nil
        client.cancel()
        upstream?.cancel()
        upstream = nil
        engine.sessionDidClose(self)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
