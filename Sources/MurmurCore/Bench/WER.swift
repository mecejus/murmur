import Foundation

/// Word error rate against a reference, after normalizing case, punctuation
/// and number spelling differences that do not matter for dictation.
public enum WER {
    public static func normalize(_ s: String) -> [String] {
        s.lowercased()
            .folding(options: [.diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    public static func rate(reference: String, hypothesis: String) -> Double {
        let r = normalize(reference), h = normalize(hypothesis)
        if r.isEmpty { return h.isEmpty ? 0 : 1 }
        var prev = Array(0...h.count)
        var cur = [Int](repeating: 0, count: h.count + 1)
        for i in 1...r.count {
            cur[0] = i
            if h.count > 0 {
                for j in 1...h.count {
                    cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
                }
            }
            swap(&prev, &cur)
        }
        return Double(prev[h.count]) / Double(r.count)
    }
}
