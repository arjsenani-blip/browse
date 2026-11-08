import Foundation
import WebKit
import os
import ContentBlocking
import WebEngine

/// Bridges ContentBlocking into the web layer's ContentPolicy: converts the
/// active filter lists off the main thread, compiles them (cached by hash),
/// and keeps the cosmetic index for per-host CSS.
@MainActor
final class BlockingAdapter: ContentPolicy {
    private(set) var ruleLists: [WKContentRuleList] = []
    private var cosmetic = CosmeticIndex()
    private let compiler = ContentRuleCompiler()
    private let manager = FilterListManager()
    private let log = Logger(subsystem: "app.aegis", category: "blocking")
    var onRulesChanged: (() -> Void)?
    private(set) var ruleCount = 0

    private static let idsKey = "blockingRuleListIDs"
    private static let countKey = "blockingRuleCount"

    /// Loads the lists compiled on a previous launch by identifier (a few ms),
    /// so pages restored at launch are blocked from their first request.
    /// Returns once rules are in place, or after `timeout` on a first launch.
    func start(timeout: TimeInterval = 6) async {
        if let ids = UserDefaults.standard.stringArray(forKey: Self.idsKey), !ids.isEmpty,
           let url = ContentRuleCompiler.defaultStoreURL, let store = WKContentRuleListStore(url: url) {
            var lists: [WKContentRuleList] = []
            for id in ids {
                guard let list = try? await store.contentRuleList(forIdentifier: id) else { lists = []; break }
                lists.append(list)
            }
            if !lists.isEmpty {
                ruleLists = lists
                ruleCount = UserDefaults.standard.integer(forKey: Self.countKey)
                log.info("blocking ready from cache: \(lists.count) lists")
            }
        }
        let fresh = Task { await rebuild(); update(force: false, report: nil) }
        guard ruleLists.isEmpty else { return }
        // First launch: wait for the compile, bounded so the window still appears.
        let waited = Date()
        while ruleLists.isEmpty, Date().timeIntervalSince(waited) < timeout {
            try? await Task.sleep(for: .milliseconds(50))
        }
        _ = fresh
    }

    func cosmeticScript(forHost host: String) -> String? {
        CosmeticScript.source(for: host, index: cosmetic)
    }

    func strippedURL(_ url: URL) -> URL? {
        TrackingParamStripper.clean(url)
    }

    func update(force: Bool, report: ((String) -> Void)?) {
        Task {
            let outcome = await manager.updateIfNeeded(force: force)
            if outcome.didChange {
                await rebuild()
                report?("Filter lists updated · \(ruleCount.formatted()) rules")
            } else if !outcome.failed.isEmpty {
                report?("Couldn't update filter lists")
            } else {
                report?("Filter lists are up to date")
            }
        }
    }

    private func rebuild() async {
        let start = Date()
        let manager = self.manager
        let result = await Task.detached(priority: .utility) { manager.convertActiveLists() }.value
        let lists = await compiler.compile(result)
        guard !lists.isEmpty else {
            log.error("rule compile produced nothing; keeping previous rules")
            return
        }
        let changed = lists.map(\.identifier) != ruleLists.map(\.identifier)
        ruleLists = lists
        cosmetic = result.cosmetic
        ruleCount = result.ruleCount
        UserDefaults.standard.set(lists.map(\.identifier), forKey: Self.idsKey)
        UserDefaults.standard.set(result.ruleCount, forKey: Self.countKey)
        log.info("blocking compiled: \(result.ruleCount) rules in \(lists.count) lists, \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
        if changed { onRulesChanged?() }
    }
}
