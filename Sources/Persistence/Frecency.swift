import Foundation

/// How a page was reached. Raw values are persisted in `visits.kind`; never renumber.
public enum VisitKind: Int, Sendable, CaseIterable, Codable {
    case typed = 1
    case link = 2
    case bookmark = 3
    case reload = 4
    case redirect = 5
}

/// Firefox-style frecency.
///
/// Per visit: `weight(bucket) · e^(−λ·Δt)`, λ = ln2 / 30 days. The last `sampleSize` visits are
/// averaged and multiplied by the total visit count.
///
/// Buckets (weights 100/70/50/20): typed = very high, bookmark = high, link = medium,
/// reload/redirect = low. An "interesting" visit (≥ 60 s viewed or ≥ 20 keypresses) moves up one bucket.
///
/// **Storage choice:** we store the *decay date* — `t_ref + ln(score)/λ`, in days since 1970 — the
/// moment at which the score will have decayed to 1. It never needs rewriting as time passes, sorts
/// identically to the live score, and converts back with `currentScore(storedValue:now:)`.
/// A zero score is stored as `0`.
public enum Frecency {
    public static let halfLifeDays: Double = 30
    public static let lambda: Double = log(2) / halfLifeDays
    public static let sampleSize = 10
    public static let interestingViewMs = 60_000
    public static let interestingKeypresses = 20

    public struct SampledVisit: Sendable {
        public var date: Date
        public var kind: VisitKind
        public var viewMs: Int
        public var keypresses: Int
        public init(date: Date, kind: VisitKind, viewMs: Int = 0, keypresses: Int = 0) {
            self.date = date
            self.kind = kind
            self.viewMs = viewMs
            self.keypresses = keypresses
        }
    }

    /// Bucket weights from lowest to highest.
    static let buckets: [Double] = [20, 50, 70, 100]

    public static func weight(_ visit: SampledVisit) -> Double {
        var bucket: Int
        switch visit.kind {
        case .typed: bucket = 3
        case .bookmark: bucket = 2
        case .link: bucket = 1
        case .reload, .redirect: bucket = 0
        }
        if visit.viewMs >= interestingViewMs || visit.keypresses >= interestingKeypresses {
            bucket = min(bucket + 1, buckets.count - 1)
        }
        return buckets[bucket]
    }

    /// Live score at `now` from up to `sampleSize` most recent visits.
    public static func score(visits: [SampledVisit], visitCount: Int, now: Date) -> Double {
        let sample = visits.sorted { $0.date > $1.date }.prefix(sampleSize)
        guard !sample.isEmpty, visitCount > 0 else { return 0 }
        let sum = sample.reduce(0.0) { acc, v in
            let ageDays = max(0, now.timeIntervalSince(v.date) / 86_400)
            return acc + weight(v) * exp(-lambda * ageDays)
        }
        return sum / Double(sample.count) * Double(visitCount)
    }

    public static func days(_ date: Date) -> Double { date.timeIntervalSince1970 / 86_400 }

    /// Converts a live score at `now` into the static, sortable stored form.
    public static func storedValue(score: Double, now: Date) -> Double {
        guard score > 0 else { return 0 }
        return days(now) + log(score) / lambda
    }

    /// Converts the stored decay date back into the live score at `now`.
    public static func currentScore(storedValue: Double, now: Date) -> Double {
        guard storedValue != 0 else { return 0 }
        return exp(lambda * (storedValue - days(now)))
    }
}
