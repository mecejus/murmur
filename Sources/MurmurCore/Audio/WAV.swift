import Foundation

/// Minimal RIFF/WAVE reader for the offline paths (`murmur transcribe`, the
/// integration test, the benchmarks). Accepts PCM 16/24/32-bit integer and
/// 32-bit float, any rate and channel count, and returns mono float.
/// Malformed input throws; it never traps.
public struct WAV {
    public var sampleRate: Double
    public var samples: [Float]

    public var duration: Double { Double(samples.count) / sampleRate }

    public enum Failure: Error, CustomStringConvertible {
        case notWAV, truncated, unsupported(String)

        public var description: String {
            switch self {
            case .notWAV: return "not a RIFF/WAVE file"
            case .truncated: return "file is truncated"
            case .unsupported(let s): return "unsupported WAV format: \(s)"
            }
        }
    }

    public init(sampleRate: Double, samples: [Float]) {
        self.sampleRate = sampleRate
        self.samples = samples
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        let b = [UInt8](data)
        func u16(_ o: Int) throws -> Int {
            guard o + 2 <= b.count else { throw Failure.truncated }
            return Int(b[o]) | Int(b[o + 1]) << 8
        }
        func u32(_ o: Int) throws -> Int {
            guard o + 4 <= b.count else { throw Failure.truncated }
            return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
        }
        func tag(_ o: Int) -> String {
            guard o + 4 <= b.count else { return "" }
            return String(decoding: b[o..<o + 4], as: UTF8.self)
        }

        guard b.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { throw Failure.notWAV }

        var format = 0, channels = 0, rate = 0, bits = 0
        var dataRange: Range<Int>?
        var o = 12
        while o + 8 <= b.count {
            let id = tag(o)
            let size = try u32(o + 4)
            let body = o + 8
            switch id {
            case "fmt ":
                format = try u16(body)
                channels = try u16(body + 2)
                rate = try u32(body + 4)
                bits = try u16(body + 14)
                if format == 0xFFFE, size >= 26 { format = try u16(body + 24) } // WAVE_FORMAT_EXTENSIBLE
            case "data":
                // Tolerate a data size that overruns the file (common in
                // streamed or interrupted recordings): read what is there.
                dataRange = body..<min(b.count, body + size)
            default:
                break
            }
            if dataRange != nil, format != 0 { break }
            o = body + size + (size & 1)
        }

        guard format != 0 else { throw Failure.truncated }
        guard let dataRange else { throw Failure.truncated }
        guard channels > 0, channels <= 32 else { throw Failure.unsupported("\(channels) channels") }
        guard rate >= 1000, rate <= 384_000 else { throw Failure.unsupported("\(rate) Hz") }

        let bytes = bits / 8
        let frameBytes = bytes * channels
        guard frameBytes > 0 else { throw Failure.unsupported("\(bits)-bit") }
        let frames = dataRange.count / frameBytes

        let decode: (Int) -> Float
        switch (format, bits) {
        case (1, 16):
            decode = { Float(Int16(bitPattern: UInt16(b[$0]) | UInt16(b[$0 + 1]) << 8)) / 32768 }
        case (1, 24):
            decode = {
                let v = Int32(b[$0]) | Int32(b[$0 + 1]) << 8 | Int32(b[$0 + 2]) << 16
                return Float((v << 8) >> 8) / 8_388_608
            }
        case (1, 32):
            decode = {
                Float(Int32(bitPattern: UInt32(b[$0]) | UInt32(b[$0 + 1]) << 8 | UInt32(b[$0 + 2]) << 16 | UInt32(b[$0 + 3]) << 24)) / 2_147_483_648
            }
        case (3, 32):
            decode = {
                Float(bitPattern: UInt32(b[$0]) | UInt32(b[$0 + 1]) << 8 | UInt32(b[$0 + 2]) << 16 | UInt32(b[$0 + 3]) << 24)
            }
        default:
            throw Failure.unsupported("format \(format), \(bits)-bit")
        }

        var out = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        for f in 0..<frames {
            var sum: Float = 0
            let at = dataRange.lowerBound + f * frameBytes
            for c in 0..<channels { sum += decode(at + c * bytes) }
            out[f] = sum * scale
        }
        sampleRate = Double(rate)
        samples = out
    }

    /// 16-bit PCM mono encoding, for tests and benchmark fixtures.
    public func pcm16Data() -> Data {
        var d = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); put32(36 + dataBytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16)
        put16(1); put16(1); put32(UInt32(sampleRate)); put32(UInt32(sampleRate) * 2); put16(2); put16(16)
        d.append(contentsOf: Array("data".utf8)); put32(dataBytes)
        for s in samples {
            let v = Int16(max(-1, min(1, s.isFinite ? s : 0)) * 32767)
            put16(UInt16(bitPattern: v))
        }
        return d
    }
}
