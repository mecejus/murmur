import AVFoundation

/// Streaming sample-rate conversion from the input device's rate to Whisper's
/// 16 kHz, on the drain step (never the audio thread). Buffers are allocated
/// once per input rate and reused.
public final class Resampler {
    public static let targetRate: Double = 16_000

    public let inputRate: Double
    private let converter: AVAudioConverter?
    private let inBuf: AVAudioPCMBuffer
    private let outBuf: AVAudioPCMBuffer
    private let chunk: Int

    /// - Parameter chunk: the most input frames passed to one `process` call.
    public init?(inputRate: Double, chunk: Int = 8192) {
        guard inputRate > 0,
              let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.targetRate, channels: 1, interleaved: false),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(chunk)) else { return nil }
        let outCap = AVAudioFrameCount(Double(chunk) * Self.targetRate / inputRate) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { return nil }
        self.inputRate = inputRate
        self.inBuf = inBuf
        self.outBuf = outBuf
        self.chunk = chunk
        if inputRate == Self.targetRate {
            converter = nil
        } else {
            guard let c = AVAudioConverter(from: inFmt, to: outFmt) else { return nil }
            c.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            c.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
            converter = c
        }
    }

    /// Clears filter state between dictations.
    public func reset() { converter?.reset() }

    /// Converts `input` (at most `chunk` frames) and hands the 16 kHz result
    /// to `sink`. Pass `end: true` once, after the last input, to flush the
    /// filter tail.
    public func process(_ input: UnsafeBufferPointer<Float>, end: Bool = false, sink: (UnsafeBufferPointer<Float>) -> Void) {
        guard let converter else {
            if !input.isEmpty { sink(input) }
            return
        }
        precondition(input.count <= chunk)
        if let base = input.baseAddress, !input.isEmpty {
            inBuf.floatChannelData![0].update(from: base, count: input.count)
        }
        inBuf.frameLength = AVAudioFrameCount(input.count)

        var supplied = input.isEmpty
        while true {
            outBuf.frameLength = 0
            var err: NSError?
            let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
                if !supplied {
                    supplied = true
                    outStatus.pointee = .haveData
                    return self.inBuf
                }
                outStatus.pointee = end ? .endOfStream : .noDataNow
                return nil
            }
            let n = Int(outBuf.frameLength)
            if n > 0 { sink(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: n)) }
            switch status {
            case .haveData:
                continue // output buffer filled up; drain more
            case .inputRanDry, .endOfStream:
                return
            case .error:
                log.warn("resampler_error", ["error": err?.localizedDescription ?? "unknown"])
                converter.reset()
                return
            @unknown default:
                return
            }
        }
    }
}
