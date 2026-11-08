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

    func start() {
        Task {
            await rebuild()
            update(force: false, report: nil)
        }
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
        ruleLists = lists
        cosmetic = result.cosmetic
        ruleCount = result.ruleCount
        log.info("blocking ready: \(result.ruleCount) rules in \(lists.count) lists, \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
        onRulesChanged?()
    }
}
