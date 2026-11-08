import Foundation
import Synchronization
import Persistence

/// Two-stage palette/omnibox engine.
///
/// 1. `quickResults` — synchronous, in-memory: tabs, bookmarks, commands and a cached top-N history
///    slice (`HistorySnapshot`). Cheap enough to run on the main thread per keystroke.
/// 2. `fullResults` — async: adds FTS5 trigram hits from `HistoryStore`, then re-ranks. Callers should
///    run it in a `Task` cancelled on the next keystroke; a cancelled call returns the quick results.
public final class PaletteEngine: Sendable {
    public let history: HistoryStore?
    public let ranker: OmniboxRanker
    private let snapshot = Mutex(HistorySnapshot.empty)

    public init(history: HistoryStore?, ranker: OmniboxRanker = OmniboxRanker()) {
        self.history = history
        self.ranker = ranker
    }

    /// Reloads the cached history slice (quick-index candidates + adaptive input history).
    /// Call at launch, after visits settle, and at idle.
    public func refreshHistoryCache(limit: Int = 20_000) async throws {
        guard let history else { return }
        let hits = try await history.quickIndexCandidates(limit: limit)
        let inputs = try await history.inputMatches(prefix: "")
        setHistorySnapshot(HistorySnapshot(hits: hits, inputs: inputs))
    }

    public func setHistorySnapshot(_ s: HistorySnapshot) {
        snapshot.withLock { $0 = s }
    }

    public var historySnapshot: HistorySnapshot { snapshot.withLock { $0 } }

    public func quickResults(_ query: PaletteQuery) -> [PaletteResult] {
        ranker.rank(query, snapshot: historySnapshot)
    }

    public func fullResults(_ query: PaletteQuery, ftsLimit: Int = 50) async -> [PaletteResult] {
        let (scope, text) = query.parsed
        guard let history, !text.isEmpty, scope == .all || scope == .history else {
            return quickResults(query)
        }
        let hits = (try? await history.search(text, limit: ftsLimit)) ?? []
        if Task.isCancelled { return quickResults(query) }
        return ranker.rank(query, snapshot: historySnapshot, extraHits: hits)
    }
}
