import Accelerate

/// Cheap signal checks run on a finished recording before it reaches the
/// model: repair samples a broken driver or file can produce, and trim the
/// silence around the speech so the model is not asked to transcribe noise
/// (where Whisper tends to invent "Thank you." and similar).
public enum Speech {
    public static let rate = 16_000
    static let frame = 160 // 10 ms

    /// Replaces NaN and infinities with 0 and clamps to [-1, 1]. Returns how
    /// many samples needed fixing. A corrupt chunk then costs a click in the
    /// audio instead of a poisoned model input.
    @discardableResult
    public static func sanitize(_ s: UnsafeMutableBufferPointer<Float>) -> Int {
        var fixed = 0
        for i in s.indices {
            let v = s[i]
            if !v.isFinite {
                s[i] = 0
                fixed += 1
            } else if v > 1 || v < -1 {
                s[i] = max(-1, min(1, v))
                fixed += 1
            }
        }
        return fixed
    }

    public struct Analysis: Equatable {
        /// Sample range that holds speech, padded; empty when there is none.
        public var speech: Range<Int>
        public var peak: Float
        public var noiseFloor: Float
    }

    /// Finds where speech starts and ends using short-term energy against an
    /// adaptive threshold. Deliberately generous: `pad` samples are kept on
    /// both sides, and anything near the threshold counts as speech, because
    /// clipping the first syllable is worse than sending some silence.
    public static func analyze(_ s: UnsafeBufferPointer<Float>, pad: Int = rate * 3 / 10) -> Analysis {
        let frames = s.count / frame
        guard frames > 0, let base = s.baseAddress else {
            return Analysis(speech: 0..<0, peak: 0, noiseFloor: 0)
        }
        var rms = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            vDSP_rmsqv(base + f * frame, 1, &rms[f], vDSP_Length(frame))
        }
        var peak: Float = 0
        vDSP_maxmgv(base, 1, &peak, vDSP_Length(s.count))

        let sorted = rms.sorted()
        let floor = sorted[min(sorted.count - 1, sorted.count / 10)]
        let loud = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        // Speech has to stand clearly above the quietest tenth of the
        // recording, and above an absolute floor (about -54 dBFS) so a
        // silent room does not count as speech.
        let threshold = max(0.002, floor * 3, loud * 0.05)

        guard let first = rms.firstIndex(where: { $0 > threshold }),
              let last = rms.lastIndex(where: { $0 > threshold }) else {
            return Analysis(speech: 0..<0, peak: peak, noiseFloor: floor)
        }
        // A lone click is not speech: require 50 ms above threshold in total.
        let voiced = rms[first...last].reduce(0) { $0 + ($1 > threshold ? 1 : 0) }
        if voiced < 5 {
            return Analysis(speech: 0..<0, peak: peak, noiseFloor: floor)
        }
        let lo = max(0, first * frame - pad)
        let hi = min(s.count, (last + 1) * frame + pad)
        return Analysis(speech: lo..<hi, peak: peak, noiseFloor: floor)
    }
}
