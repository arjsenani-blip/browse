import Foundation

/// Fetches a filter list. Abstracted so tests can inject responses.
public protocol FilterFetching: Sendable {
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Ephemeral, cookie-less URLSession that refuses redirects to hosts outside the allowlist.
public final class URLSessionFilterFetcher: FilterFetching {
    private let session: URLSession

    public init(allowedHosts: Set<String> = FilterListManager.allowedHosts) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: RedirectGuard(allowedHosts: allowedHosts), delegateQueue: nil)
    }

    public func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        let allowedHosts: Set<String>
        init(allowedHosts: Set<String>) { self.allowedHosts = allowedHosts }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, FilterListManager.isAllowed(url, hosts: allowedHosts) else { return nil }
            return request
        }
    }
}

/// Knows the bundled filter lists and downloaded updates; refreshes EasyList/EasyPrivacy at most once per day.
///
/// Network policy (see CLAUDE.md "Zero telemetry"): HTTPS only, allowlisted hosts only, ephemeral session,
/// no cookies, no headers beyond `If-None-Match` for ETag revalidation.
public actor FilterListManager {
    public struct RemoteList: Sendable, Hashable {
        /// File name used for both the bundled copy and the downloaded copy, e.g. "easylist.txt".
        public var name: String
        public var url: URL
        public init(name: String, url: URL) {
            self.name = name
            self.url = url
        }
    }

    public struct UpdateOutcome: Sendable, Equatable {
        public var updated: [String] = []
        public var notModified: [String] = []
        public var skippedRecentlyChecked: [String] = []
        public var failed: [String: String] = [:]
        public var didChange: Bool { !updated.isEmpty }
    }

    struct Metadata: Codable, Equatable {
        var etag: String?
        var lastChecked: Date?
        var lastFailure: Date?
    }

    public static let allowedHosts: Set<String> = ["easylist.to", "secure.fanboy.co.uk"]
    public static let updateInterval: TimeInterval = 24 * 60 * 60
    public static let failureRetryInterval: TimeInterval = 60 * 60
    public static let starterListName = "starter.txt"

    public static let defaultRemoteLists: [RemoteList] = [
        RemoteList(name: "easylist.txt", url: URL(string: "https://easylist.to/easylist/easylist.txt")!),
        RemoteList(name: "easyprivacy.txt", url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
    ]

    /// `~/Library/Application Support/Vane/Filters`.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Vane/Filters", isDirectory: true)
    }

    /// Bundled lists folder (`Resources/lists`).
    public static var bundledDirectory: URL? {
        Bundle.module.url(forResource: "lists", withExtension: nil)
    }

    public static func isAllowed(_ url: URL, hosts: Set<String> = allowedHosts) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }

    public nonisolated let directory: URL
    public nonisolated let bundledDirectory: URL?
    public nonisolated let remoteLists: [RemoteList]
    private let fetcher: any FilterFetching
    private var metadata: [String: Metadata]

    public init(directory: URL = FilterListManager.defaultDirectory,
                bundledDirectory: URL? = FilterListManager.bundledDirectory,
                remoteLists: [RemoteList] = FilterListManager.defaultRemoteLists,
                fetcher: any FilterFetching = URLSessionFilterFetcher()) {
        self.directory = directory
        self.bundledDirectory = bundledDirectory
        self.remoteLists = remoteLists.filter { Self.isAllowed($0.url) }
        self.fetcher = fetcher
        let metaURL = directory.appendingPathComponent("metadata.json")
        if let data = try? Data(contentsOf: metaURL),
           let decoded = try? JSONDecoder().decode([String: Metadata].self, from: data) {
            metadata = decoded
        } else {
            metadata = [:]
        }
    }

    private var metadataURL: URL { directory.appendingPathComponent("metadata.json") }

    /// URLs of `.txt` lists shipped in the app bundle.
    public nonisolated func bundledListURLs() -> [URL] {
        guard let dir = bundledDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "txt" && !$0.lastPathComponent.hasPrefix("LICENSE") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The list files in effect: the starter list plus each remote list (downloaded copy if present, else bundled).
    public nonisolated func activeListURLs() -> [URL] {
        let bundled = bundledListURLs()
        var result: [URL] = bundled.filter { $0.lastPathComponent == Self.starterListName }
        for list in remoteLists {
            let downloaded = directory.appendingPathComponent(list.name)
            if FileManager.default.fileExists(atPath: downloaded.path) {
                result.append(downloaded)
            } else if let b = bundled.first(where: { $0.lastPathComponent == list.name }) {
                result.append(b)
            }
        }
        return result
    }

    /// All active lists concatenated (converted together so cross-list exceptions apply).
    public nonisolated func combinedFilterText() -> String {
        activeListURLs().compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    /// Converts the active lists. Runs on the caller's executor; call from a background task.
    public nonisolated func convertActiveLists() -> ConversionResult {
        FilterListConverter.convert(combinedFilterText())
    }

    /// Fetches remote lists whose last check is older than `updateInterval` (or all, with `force`).
    public func updateIfNeeded(now: Date = Date(), force: Bool = false) async -> UpdateOutcome {
        var outcome = UpdateOutcome()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for list in remoteLists {
            var meta = metadata[list.name] ?? Metadata()
            if !force {
                if let last = meta.lastChecked, now.timeIntervalSince(last) < Self.updateInterval {
                    outcome.skippedRecentlyChecked.append(list.name)
                    continue
                }
                if let failure = meta.lastFailure, now.timeIntervalSince(failure) < Self.failureRetryInterval {
                    outcome.skippedRecentlyChecked.append(list.name)
                    continue
                }
            }
            let file = directory.appendingPathComponent(list.name)
            var request = URLRequest(url: list.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            request.httpShouldHandleCookies = false
            if let etag = meta.etag, FileManager.default.fileExists(atPath: file.path) {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            do {
                let (data, response) = try await fetcher.fetch(request)
                if let finalURL = response.url, !Self.isAllowed(finalURL) {
                    throw UpdateError.disallowedHost
                }
                switch response.statusCode {
                case 304:
                    outcome.notModified.append(list.name)
                case 200:
                    guard Self.looksLikeFilterList(data) else { throw UpdateError.invalidContent }
                    try data.write(to: file, options: .atomic)
                    meta.etag = response.value(forHTTPHeaderField: "ETag")
                    outcome.updated.append(list.name)
                default:
                    throw UpdateError.httpStatus(response.statusCode)
                }
                meta.lastChecked = now
                meta.lastFailure = nil
            } catch {
                meta.lastFailure = now
                outcome.failed[list.name] = String(describing: error)
            }
            metadata[list.name] = meta
        }
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: metadataURL, options: .atomic)
        }
        return outcome
    }

    public enum UpdateError: Error, Equatable {
        case disallowedHost
        case invalidContent
        case httpStatus(Int)
    }

    /// Basic sanity check so a captive portal page or truncated response never replaces a good list.
    static func looksLikeFilterList(_ data: Data) -> Bool {
        guard data.count >= 1024 else { return false }
        var prefix = data.prefix(64)
        if prefix.starts(with: [0xEF, 0xBB, 0xBF]) { prefix = prefix.dropFirst(3) }
        guard let head = String(data: prefix, encoding: .utf8) else { return false }
        return head.hasPrefix("[Adblock") || head.hasPrefix("! ")
    }
}
