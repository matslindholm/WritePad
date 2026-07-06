import Foundation

/// Aligns the words we *expect* to be spoken (from the script) onto the words
/// the speech recognizer actually *heard* (with timestamps), producing one
/// `WordTiming` per expected word.
///
/// Recognition is imperfect — it drops, merges, and mishears words — so we
/// anchor on the words that match and linearly interpolate timing across the
/// gaps. The result is always monotonic and gap-free, which is what the
/// karaoke highlight needs.
enum WordAligner {
    static func align(expected: [ExpectedToken],
                      recognized: [RecognizedWord],
                      totalDuration: Double) -> [WordTiming] {
        guard !expected.isEmpty else { return [] }
        let duration = max(totalDuration, lastEnd(recognized))

        let anchors = matchAnchors(expected: expected, recognized: recognized)
        guard !anchors.isEmpty else { return evenlySpread(expected, in: 0, duration) }

        var times = [ClosedRange<Double>?](repeating: nil, count: expected.count)
        for anchor in anchors { times[anchor.index] = anchor.start...max(anchor.start, anchor.end) }

        fillGap(&times, from: -1, to: anchors.first!.index, lowerBound: 0, upperBound: anchors.first!.start)
        for (a, b) in zip(anchors, anchors.dropFirst()) {
            fillGap(&times, from: a.index, to: b.index, lowerBound: times[a.index]!.upperBound, upperBound: b.start)
        }
        fillGap(&times, from: anchors.last!.index, to: expected.count,
                lowerBound: times[anchors.last!.index]!.upperBound, upperBound: duration)

        return assemble(expected, times, duration: duration)
    }

    // MARK: - Anchoring

    /// Above this many DP cells, skip LCS and fall back to the cheaper greedy
    /// walk. Real chapters stay well under this.
    private static let maxLCSCells = 40_000_000

    /// Floor on how fast speech can run, in seconds per word. On-device
    /// recognition frequently reports the opening words at timestamp ≈ 0, so a
    /// candidate *first* anchor whose time is below `index × this` is that
    /// artifact — trusting it collapses every leading word to time 0 and the
    /// highlight jumps ahead. Well under any real speaking rate (~0.3 s/word),
    /// so it only rejects the impossible, never legitimate fast speech.
    private static let minLeadWordSeconds = 0.12

    private struct Anchor { let index: Int; let start: Double; let end: Double }

    /// Matches expected words to recognized words and returns the recognized
    /// timing for each match. Recognition is typically far sparser than the
    /// script (it drops words across long audio), so we align on the longest
    /// common subsequence — which tolerates arbitrary gaps on either side —
    /// rather than a lockstep walk that would exhaust the shorter stream early.
    private static func matchAnchors(expected: [ExpectedToken], recognized: [RecognizedWord]) -> [Anchor] {
        let pairs = expected.count * recognized.count <= maxLCSCells
            ? lcsPairs(expected, recognized)
            : greedyPairs(expected, recognized)

        var anchors: [Anchor] = []
        for (i, j) in pairs {
            let r = recognized[j]
            // Reject an implausibly early *first* anchor: the recognizer often
            // timestamps the opening words at ≈ 0, and trusting one at a
            // non-trivial word index collapses every leading word to time 0.
            // Skip until a candidate whose time is consistent with its index,
            // so the leading words interpolate over a real span instead.
            if anchors.isEmpty, r.start < Double(i) * Self.minLeadWordSeconds { continue }
            // A mishearing can match a later word to an earlier timestamp; drop
            // anchors that would run time backwards so interpolation between
            // them never produces a negative span.
            if anchors.last.map({ r.start >= $0.end }) ?? true {
                anchors.append(Anchor(index: i, start: r.start, end: r.end))
            }
        }
        return anchors
    }

    /// Longest-common-subsequence match, returning (expectedIndex, recognizedIndex)
    /// pairs in increasing order.
    private static func lcsPairs(_ expected: [ExpectedToken], _ recognized: [RecognizedWord]) -> [(Int, Int)] {
        let n = expected.count, m = recognized.count
        let e = expected.map(\.normalized)
        let r = recognized.map(\.normalized)
        let width = m + 1
        var dp = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            let row = i * width, next = (i + 1) * width
            for j in stride(from: m - 1, through: 0, by: -1) {
                if !e[i].isEmpty, e[i] == r[j] {
                    dp[row + j] = dp[next + j + 1] + 1
                } else {
                    dp[row + j] = max(dp[next + j], dp[row + j + 1])
                }
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if !e[i].isEmpty, e[i] == r[j] {
                pairs.append((i, j))
                i += 1; j += 1
            } else if dp[(i + 1) * width + j] >= dp[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    /// Cheap linear fallback for pathologically large inputs: a lockstep walk
    /// that advances expected faster so the sparser recognized stream isn't
    /// exhausted prematurely.
    private static func greedyPairs(_ expected: [ExpectedToken], _ recognized: [RecognizedWord]) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < expected.count, j < recognized.count {
            if !expected[i].normalized.isEmpty, expected[i].normalized == recognized[j].normalized {
                pairs.append((i, j))
                i += 1; j += 1
            } else {
                i += 1   // assume the recognizer dropped this word
            }
        }
        return pairs
    }

    // MARK: - Interpolation

    /// Spreads the unmatched expected tokens in `(from, to)` evenly across the
    /// time span between the surrounding anchors.
    private static func fillGap(_ times: inout [ClosedRange<Double>?],
                                from: Int, to: Int, lowerBound: Double, upperBound: Double) {
        let count = to - from - 1
        guard count > 0 else { return }
        let hi = max(lowerBound, upperBound)
        let step = (hi - lowerBound) / Double(count)
        for k in 0..<count {
            let start = lowerBound + step * Double(k)
            times[from + 1 + k] = start...(start + step)
        }
    }

    private static func evenlySpread(_ expected: [ExpectedToken], in lower: Double, _ upper: Double) -> [WordTiming] {
        let step = (max(lower, upper) - lower) / Double(expected.count)
        return expected.enumerated().map { index, token in
            let start = lower + step * Double(index)
            return WordTiming(text: token.text, start: start, end: start + step,
                              paragraphIndex: token.paragraphIndex, emphasis: token.emphasis)
        }
    }

    private static func assemble(_ expected: [ExpectedToken],
                                 _ times: [ClosedRange<Double>?], duration: Double) -> [WordTiming] {
        var result: [WordTiming] = []
        var cursor = 0.0
        for (index, token) in expected.enumerated() {
            let range = times[index] ?? cursor...cursor
            let start = min(max(range.lowerBound, cursor), duration)
            let end = min(max(range.upperBound, start), duration)
            result.append(WordTiming(text: token.text, start: start, end: end,
                                     paragraphIndex: token.paragraphIndex, emphasis: token.emphasis))
            cursor = end
        }
        return result
    }

    private static func lastEnd(_ recognized: [RecognizedWord]) -> Double {
        recognized.last?.end ?? 0
    }
}
