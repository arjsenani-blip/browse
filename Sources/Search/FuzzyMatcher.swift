import Foundation

/// Result of a fuzzy match. `positions` are UTF-8 byte offsets into the candidate, ascending.
public struct FuzzyMatch: Sendable, Equatable {
    public var score: Int
    public var positions: [Int]
    public init(score: Int, positions: [Int]) {
        self.score = score
        self.positions = positions
    }

    /// Positions merged into contiguous byte ranges (for highlighting).
    public var ranges: [Range<Int>] { FuzzyMatch.ranges(from: positions) }

    public static func ranges(from positions: [Int]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for p in positions.sorted() {
            if let last = out.last, last.upperBound == p {
                out[out.count - 1] = last.lowerBound..<(p + 1)
            } else if let last = out.last, last.contains(p) {
                continue
            } else {
                out.append(p..<(p + 1))
            }
        }
        return out
    }
}

/// A pattern prepared once per keystroke: lowercased ASCII bytes.
public struct FuzzyPattern: Sendable, Equatable {
    public let text: String
    public let bytes: [UInt8]
    public init(_ text: String) {
        self.text = text
        self.bytes = text.utf8.map { ($0 >= 65 && $0 <= 90) ? $0 + 32 : $0 }
    }
    public var isEmpty: Bool { bytes.isEmpty }
}

/// Port of fzf's `FuzzyMatchV2` (Smith–Waterman-style, no omission) with the greedy `FuzzyMatchV1`
/// fallback when `N·M` exceeds the scratch slab. Case-insensitive for ASCII; non-ASCII bytes match
/// exactly and are classed as letters. Scoring constants follow fzf (default scheme).
///
/// Not thread-safe: it owns reusable scratch buffers. Create one per thread / per ranking pass.
public final class FuzzyMatcher {
    public static let scoreMatch: Int16 = 16
    public static let scoreGapStart: Int16 = -3
    public static let scoreGapExtension: Int16 = -1
    public static let bonusBoundary: Int16 = 8            // scoreMatch / 2
    public static let bonusNonWord: Int16 = 8
    public static let bonusCamel123: Int16 = 7            // bonusBoundary + scoreGapExtension
    public static let bonusConsecutive: Int16 = 4         // -(scoreGapStart + scoreGapExtension)
    public static let bonusBoundaryWhite: Int16 = 10
    public static let bonusBoundaryDelimiter: Int16 = 9
    public static let bonusFirstCharMultiplier: Int16 = 2

    /// Max N·M cells for V2 before falling back to V1 (fzf uses a 100 KiB-element slab).
    public static let defaultSlabCapacity = 100 * 1024
    /// This matcher's V2 limit; pass a small value to force the greedy V1 path.
    public let slabCapacity: Int

    enum CharClass: UInt8 { case white = 0, nonWord, delimiter, lower, upper, letter, number }

    private static let asciiClasses: [CharClass] = (0..<128).map { i -> CharClass in
        let c = UInt8(i)
        switch c {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return .lower
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return .upper
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return .number
        case 32, 9, 10, 11, 12, 13: return .white
        case UInt8(ascii: "/"), UInt8(ascii: ","), UInt8(ascii: ":"), UInt8(ascii: ";"), UInt8(ascii: "|"): return .delimiter
        default: return .nonWord
        }
    }

    /// bonusMatrix[prev][cur], flattened 7×7.
    private static let bonusMatrix: [Int16] = {
        var m = [Int16](repeating: 0, count: 49)
        for p in 0..<7 { for c in 0..<7 { m[p * 7 + c] = bonusFor(CharClass(rawValue: UInt8(p))!, CharClass(rawValue: UInt8(c))!) } }
        return m
    }()

    static func bonusFor(_ prev: CharClass, _ cls: CharClass) -> Int16 {
        if cls.rawValue > CharClass.nonWord.rawValue {
            switch prev {
            case .white: return bonusBoundaryWhite
            case .delimiter: return bonusBoundaryDelimiter
            case .nonWord: return bonusBoundary
            default: break
            }
        }
        if (prev == .lower && cls == .upper) || (prev != .number && cls == .number) { return bonusCamel123 }
        switch cls {
        case .nonWord, .delimiter: return bonusNonWord
        case .white: return bonusBoundaryWhite
        default: return 0
        }
    }

    // Lookup tables as raw pointers for the hot loop.
    private let classTable: UnsafeMutablePointer<UInt8>
    private let bonusTable: UnsafeMutablePointer<Int16>

    // Scratch.
    private var cap16 = 0
    private var slab16: UnsafeMutablePointer<Int16>
    private var capT = 0
    private var slabT: UnsafeMutablePointer<UInt8>
    private var slabB: UnsafeMutablePointer<Int16>
    private var slabF: UnsafeMutablePointer<Int32>
    private var capF = 0

    public init(slabCapacity: Int = FuzzyMatcher.defaultSlabCapacity) {
        self.slabCapacity = slabCapacity
        classTable = .allocate(capacity: 256)
        for i in 0..<256 { classTable[i] = i < 128 ? Self.asciiClasses[i].rawValue : CharClass.letter.rawValue }
        bonusTable = .allocate(capacity: 49)
        for i in 0..<49 { bonusTable[i] = Self.bonusMatrix[i] }
        slab16 = .allocate(capacity: 1); slabT = .allocate(capacity: 1)
        slabB = .allocate(capacity: 1); slabF = .allocate(capacity: 1)
    }

    deinit {
        classTable.deallocate(); bonusTable.deallocate()
        slab16.deallocate(); slabT.deallocate(); slabB.deallocate(); slabF.deallocate()
    }

    // MARK: Public API

    /// Matches `pattern` against `text`. Returns nil when not every pattern byte occurs in order.
    public func match(_ pattern: FuzzyPattern, in text: String, withPositions: Bool = true) -> FuzzyMatch? {
        if let r = text.utf8.withContiguousStorageIfAvailable({ match(pattern, bytes: $0, withPositions: withPositions) }) {
            return r
        }
        let copy = Array(text.utf8)
        return copy.withUnsafeBufferPointer { match(pattern, bytes: $0, withPositions: withPositions) }
    }

    public func match(_ pattern: String, in text: String, withPositions: Bool = true) -> FuzzyMatch? {
        match(FuzzyPattern(pattern), in: text, withPositions: withPositions)
    }

    /// Matches each whitespace-separated term independently (fzf extended-mode AND); scores add up,
    /// positions are unioned. Nil if any term fails.
    public func matchTerms(_ terms: [FuzzyPattern], in text: String, withPositions: Bool = true) -> FuzzyMatch? {
        if terms.count == 1 { return match(terms[0], in: text, withPositions: withPositions) }
        var total = 0
        var positions: [Int] = []
        for t in terms {
            guard let m = match(t, in: text, withPositions: withPositions) else { return nil }
            total += m.score
            positions += m.positions
        }
        if withPositions { positions = Array(Set(positions)).sorted() }
        return FuzzyMatch(score: total, positions: positions)
    }

    public func match(_ pattern: FuzzyPattern, bytes: UnsafeBufferPointer<UInt8>, withPositions: Bool) -> FuzzyMatch? {
        let m = pattern.bytes.count
        if m == 0 { return FuzzyMatch(score: 0, positions: []) }
        let n = bytes.count
        if m > n { return nil }
        return pattern.bytes.withUnsafeBufferPointer { pat in
            if n * m > slabCapacity {
                return matchV1(pat, bytes, withPositions: withPositions)
            }
            return matchV2(pat, bytes, withPositions: withPositions)
        }
    }

    // MARK: Helpers

    @inline(__always) private func lower(_ b: UInt8) -> UInt8 { (b >= 65 && b <= 90) ? b &+ 32 : b }

    /// fzf `asciiFuzzyIndex`: quick subsequence check; returns [minIdx, maxIdx) search window.
    @inline(__always)
    private func fuzzyIndex(_ pat: UnsafeBufferPointer<UInt8>, _ text: UnsafeBufferPointer<UInt8>) -> (Int, Int)? {
        var firstIdx = 0, idx = 0, lastIdx = 0
        let n = text.count
        for pidx in 0..<pat.count {
            let b = pat[pidx]
            while idx < n && lower(text[idx]) != b { idx += 1 }
            if idx >= n { return nil }
            if pidx == 0 && idx > 0 { firstIdx = idx - 1 }
            lastIdx = idx
            idx += 1
        }
        let b = pat[pat.count - 1]
        var off = n - 1
        while off > lastIdx {
            if lower(text[off]) == b { return (firstIdx, off + 1) }
            off -= 1
        }
        return (firstIdx, lastIdx + 1)
    }

    private func ensure16(_ count: Int) {
        if count > cap16 {
            slab16.deallocate()
            cap16 = max(count, cap16 * 2, 1024)
            slab16 = .allocate(capacity: cap16)
        }
    }

    private func ensureT(_ count: Int) {
        if count > capT {
            slabT.deallocate(); slabB.deallocate()
            capT = max(count, capT * 2, 256)
            slabT = .allocate(capacity: capT)
            slabB = .allocate(capacity: capT)
        }
    }

    private func ensureF(_ count: Int) {
        if count > capF {
            slabF.deallocate()
            capF = max(count, 32)
            slabF = .allocate(capacity: capF)
        }
    }

    // MARK: V2

    private func matchV2(_ pattern: UnsafeBufferPointer<UInt8>, _ input: UnsafeBufferPointer<UInt8>, withPositions: Bool) -> FuzzyMatch? {
        let M = pattern.count
        guard let (minIdx, maxIdx) = fuzzyIndex(pattern, input) else { return nil }
        let N = maxIdx - minIdx

        ensureT(N)
        ensureF(M)
        let T = slabT, B = slabB, F = slabF
        // H0, C0 (N each) + H, C (width·M each, ≤ N·M).
        ensure16(2 * N + 2 * N * M + 2)
        let H0 = slab16, C0 = slab16 + N

        let scoreMatch = Self.scoreMatch, gapStart = Self.scoreGapStart, gapExt = Self.scoreGapExtension
        let bonusBoundary = Self.bonusBoundary

        // Phase 2: bonuses, first-row scores, first occurrence of each pattern char.
        var maxScore: Int16 = 0, maxScorePos = 0
        var pidx = 0, lastIdx = 0
        let pchar0 = pattern[0]
        var pchar = pattern[0]
        var prevH0: Int16 = 0
        var prevClass = CharClass.white.rawValue
        var inGap = false
        for off in 0..<N {
            var ch = input[minIdx + off]
            let cls = classTable[Int(ch)]
            if cls == CharClass.upper.rawValue { ch &+= 32 }
            T[off] = ch
            let bonus = bonusTable[Int(prevClass) * 7 + Int(cls)]
            B[off] = bonus
            prevClass = cls

            if ch == pchar {
                if pidx < M {
                    F[pidx] = Int32(off)
                    pidx += 1
                    pchar = pattern[min(pidx, M - 1)]
                }
                lastIdx = off
            }
            if ch == pchar0 {
                let score = scoreMatch + bonus * Self.bonusFirstCharMultiplier
                H0[off] = score
                C0[off] = 1
                if M == 1 && score > maxScore {
                    maxScore = score; maxScorePos = off
                    if bonus >= bonusBoundary { break }
                }
                inGap = false
            } else {
                H0[off] = max(prevH0 + (inGap ? gapExt : gapStart), 0)
                C0[off] = 0
                inGap = true
            }
            prevH0 = H0[off]
        }
        if pidx != M { return nil }
        if M == 1 {
            return FuzzyMatch(score: Int(maxScore), positions: withPositions ? [minIdx + maxScorePos] : [])
        }

        // Phase 3: score matrix.
        let f0 = Int(F[0])
        let width = lastIdx - f0 + 1
        let H = slab16 + 2 * N
        let C = H + width * M
        H.update(repeating: 0, count: 2 * width * M)
        for i in 0..<width { H[i] = H0[f0 + i]; C[i] = C0[f0 + i] }

        for row in 1..<M {
            let f = Int(F[row])
            let pc = pattern[row]
            let rowOff = row * width
            var gap = false
            H[rowOff + f - f0 - 1] = 0  // Hleft[0]
            for col in f...lastIdx {
                let j0 = col - f0
                let hLeft = H[rowOff + j0 - 1]
                let s2 = hLeft + (gap ? gapExt : gapStart)
                var s1: Int16 = 0
                var consecutive: Int16 = 0
                if pc == T[col] {
                    let diag = rowOff - width + j0 - 1
                    s1 = H[diag] + scoreMatch
                    var b = B[col]
                    consecutive = C[diag] + 1
                    if consecutive > 1 {
                        let fb = B[col - Int(consecutive) + 1]
                        if b >= bonusBoundary && b > fb {
                            consecutive = 1
                        } else {
                            b = max(b, max(Self.bonusConsecutive, fb))
                        }
                    }
                    if s1 + b < s2 {
                        s1 += B[col]
                        consecutive = 0
                    } else {
                        s1 += b
                    }
                }
                C[rowOff + j0] = consecutive
                gap = s1 < s2
                let score = max(max(s1, s2), 0)
                if row == M - 1 && score > maxScore {
                    maxScore = score; maxScorePos = col
                }
                H[rowOff + j0] = score
            }
        }

        guard withPositions else { return FuzzyMatch(score: Int(maxScore), positions: []) }

        // Phase 4: backtrace.
        var positions = [Int](repeating: 0, count: M)
        var i = M - 1
        var j = maxScorePos
        var preferMatch = true
        let total = width * M
        while true {
            let I = i * width
            let j0 = j - f0
            let s = H[I + j0]
            var s1: Int16 = 0, s2: Int16 = 0
            if i > 0 && j >= Int(F[i]) { s1 = H[I - width + j0 - 1] }
            if j > Int(F[i]) { s2 = H[I + j0 - 1] }
            if s > s1 && (s > s2 || (s == s2 && preferMatch)) {
                positions[i] = j + minIdx
                if i == 0 { break }
                i -= 1
            }
            preferMatch = C[I + j0] > 1 || (I + width + j0 + 1 < total && C[I + width + j0 + 1] > 0)
            j -= 1
            if j < f0 { break } // defensive; unreachable for valid matrices
        }
        return FuzzyMatch(score: Int(maxScore), positions: positions)
    }

    // MARK: V1 (greedy)

    private func matchV1(_ pattern: UnsafeBufferPointer<UInt8>, _ text: UnsafeBufferPointer<UInt8>, withPositions: Bool) -> FuzzyMatch? {
        let M = pattern.count, n = text.count
        var pidx = 0, sidx = -1, eidx = -1
        for idx in 0..<n {
            if lower(text[idx]) == pattern[pidx] {
                if sidx < 0 { sidx = idx }
                pidx += 1
                if pidx == M { eidx = idx + 1; break }
            }
        }
        guard sidx >= 0, eidx >= 0 else { return nil }
        // Backward pass for the shortest window ending at eidx.
        pidx = M - 1
        var idx = eidx - 1
        while idx >= sidx {
            if lower(text[idx]) == pattern[pidx] {
                pidx -= 1
                if pidx < 0 { sidx = idx; break }
            }
            idx -= 1
        }
        return calculateScore(pattern, text, sidx, eidx, withPositions)
    }

    private func calculateScore(_ pattern: UnsafeBufferPointer<UInt8>, _ text: UnsafeBufferPointer<UInt8>,
                                _ sidx: Int, _ eidx: Int, _ withPositions: Bool) -> FuzzyMatch {
        var pidx = 0, score = 0, inGap = false, consecutive = 0
        var firstBonus: Int16 = 0
        var positions: [Int] = []
        if withPositions { positions.reserveCapacity(pattern.count) }
        var prevClass = sidx > 0 ? classTable[Int(text[sidx - 1])] : CharClass.white.rawValue
        for idx in sidx..<eidx {
            let raw = text[idx]
            let cls = classTable[Int(raw)]
            let ch = lower(raw)
            if pidx < pattern.count && ch == pattern[pidx] {
                if withPositions { positions.append(idx) }
                score += Int(Self.scoreMatch)
                var bonus = bonusTable[Int(prevClass) * 7 + Int(cls)]
                if consecutive == 0 {
                    firstBonus = bonus
                } else {
                    if bonus >= Self.bonusBoundary && bonus > firstBonus { firstBonus = bonus }
                    bonus = max(max(bonus, firstBonus), Self.bonusConsecutive)
                }
                score += Int(pidx == 0 ? bonus * Self.bonusFirstCharMultiplier : bonus)
                inGap = false
                consecutive += 1
                pidx += 1
            } else {
                score += Int(inGap ? Self.scoreGapExtension : Self.scoreGapStart)
                inGap = true
                consecutive = 0
                firstBonus = 0
            }
            prevClass = cls
        }
        return FuzzyMatch(score: score, positions: positions)
    }
}

extension String {
    /// Converts UTF-8 byte ranges (e.g. `FuzzyMatch.ranges`) into `String.Index` ranges, widened to
    /// whole characters.
    public func indexRanges(utf8 ranges: [Range<Int>]) -> [Range<String.Index>] {
        guard !ranges.isEmpty else { return [] }
        var out: [Range<String.Index>] = []
        for r in ranges where !r.isEmpty {
            var lo: String.Index?
            var hi: String.Index?
            var offset = 0
            var i = startIndex
            while i < endIndex {
                let next = index(after: i)
                let len = self[i..<next].utf8.count
                if offset + len > r.lowerBound && offset < r.upperBound {
                    if lo == nil { lo = i }
                    hi = next
                }
                if offset >= r.upperBound { break }
                offset += len
                i = next
            }
            if let lo, let hi { out.append(lo..<hi) }
        }
        return out
    }
}
