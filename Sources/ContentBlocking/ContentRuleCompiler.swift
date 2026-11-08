import CryptoKit
import Foundation
import WebKit

/// Compiles converted rule-list JSON into `WKContentRuleList`s, caching compiled lists on disk
/// keyed by the SHA-256 of their JSON, and keeping the last good set when a compile fails.
@MainActor
public final class ContentRuleCompiler {
    public nonisolated static let identifierPrefix = "aegis-"

    /// `~/Library/Application Support/Aegis/RuleLists`.
    public static var defaultStoreURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Aegis/RuleLists", isDirectory: true)
    }

    /// The lists currently in effect (last successful `compile`).
    public private(set) var current: [WKContentRuleList] = []
    /// The error from the most recent failed `compile`, if any.
    public private(set) var lastError: Error?

    private let store: WKContentRuleListStore

    /// - Parameter storeURL: directory for compiled lists; `nil` uses `WKContentRuleListStore.default()`.
    public init(storeURL: URL? = ContentRuleCompiler.defaultStoreURL) {
        if let storeURL {
            try? FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
            store = WKContentRuleListStore(url: storeURL) ?? .default()
        } else {
            store = .default()
        }
    }

    /// Stable store identifier for a JSON rule list.
    public nonisolated static func identifier(for json: String) -> String {
        let digest = SHA256.hash(data: Data(json.utf8))
        return identifierPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Looks up every list in the cache without compiling. Returns `nil` if any is missing.
    public func lookUpCached(_ lists: [String]) async -> [WKContentRuleList]? {
        var result: [WKContentRuleList] = []
        for json in lists {
            guard let list = await lookUp(Self.identifier(for: json)) else {
                return nil
            }
            result.append(list)
        }
        return result
    }

    /// Returns compiled lists for `lists`, using cached compilations where possible.
    ///
    /// All-or-nothing: if any list fails to compile, `current` (the last good set) is returned
    /// unchanged and `lastError` is set. On success, `current` is replaced and stale cached lists
    /// with the Aegis prefix are removed from the store.
    @discardableResult
    public func compile(_ lists: [String]) async -> [WKContentRuleList] {
        do {
            var compiled: [WKContentRuleList] = []
            for json in lists {
                compiled.append(try await compileOne(json))
            }
            current = compiled
            lastError = nil
            await prune(keeping: Set(lists.map(Self.identifier(for:))))
        } catch {
            lastError = error
        }
        return current
    }

    @discardableResult
    public func compile(_ result: ConversionResult) async -> [WKContentRuleList] {
        await compile(result.lists)
    }

    /// Compiles (or looks up) a single list; throws on a WebKit compile error.
    public func compileOne(_ json: String) async throws -> WKContentRuleList {
        let id = Self.identifier(for: json)
        if let cached = await lookUp(id) {
            return cached
        }
        guard let list = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) else {
            throw CompileError.noList
        }
        return list
    }

    public enum CompileError: Error { case noList }

    private func lookUp(_ id: String) async -> WKContentRuleList? {
        await withCheckedContinuation { (cont: CheckedContinuation<WKContentRuleList?, Never>) in
            store.lookUpContentRuleList(forIdentifier: id) { list, _ in
                cont.resume(returning: list)
            }
        }
    }

    /// Removes cached lists with the Aegis prefix that aren't in `keeping`.
    public func prune(keeping: Set<String>) async {
        let ids = await store.availableIdentifiers() ?? []
        for id in ids where id.hasPrefix(Self.identifierPrefix) && !keeping.contains(id) {
            try? await store.removeContentRuleList(forIdentifier: id)
        }
    }
}
