import Foundation
import Testing
@testable import MurmurCore

@Suite struct RingTests {
    @Test func writeReadWrapsAround() {
        let r = SampleRing(capacity: 8)!
        #expect(r.capacity == 8)
        var out = [Float](repeating: 0, count: 8)
        for round in 0..<5 {
            let input = (0..<6).map { Float(round * 10 + $0) }
            #expect(input.withUnsafeBufferPointer { r.write($0) } == 6)
            #expect(r.available == 6)
            let n = out.withUnsafeMutableBufferPointer { r.read(into: $0) }
            #expect(n == 6)
            #expect(Array(out[0..<6]) == input)
        }
        #expect(r.takeDropped() == 0)
    }

    @Test func overflowDropsNewestAndCounts() {
        let r = SampleRing(capacity: 4)!
        let input: [Float] = [1, 2, 3, 4, 5, 6]
        #expect(input.withUnsafeBufferPointer { r.write($0) } == 4)
        #expect(r.takeDropped() == 2)
        #expect(r.takeDropped() == 0)
        var out = [Float](repeating: 0, count: 8)
        let n = out.withUnsafeMutableBufferPointer { r.read(into: $0) }
        #expect(Array(out[0..<n]) == [1, 2, 3, 4])
    }

    @Test func capacityRoundsUpToPowerOfTwo() {
        #expect(SampleRing(capacity: 1000)!.capacity == 1024)
        #expect(SampleRing(capacity: 0) == nil)
    }

    /// One producer thread, one consumer: every sample arrives once, in
    /// order, with nothing lost while the ring has room.
    @Test func concurrentProducerConsumerKeepsOrder() async {
        let r = SampleRing(capacity: 1 << 12)!
        let total = 2_000_000
        let producer = Thread {
            var next = 0
            var chunk = [Float](repeating: 0, count: 256)
            while next < total {
                let n = min(256, total - next)
                for i in 0..<n { chunk[i] = Float(next + i) }
                var written = 0
                while written < n {
                    let from = written
                    written += chunk.withUnsafeBufferPointer { r.write(UnsafeBufferPointer(rebasing: $0[from..<n])) }
                    if written < n { usleep(10) }
                }
                next += n
            }
        }
        producer.start()
        var expected = 0
        var out = [Float](repeating: 0, count: 300)
        var ok = true
        while expected < total {
            let n = out.withUnsafeMutableBufferPointer { r.read(into: $0) }
            for i in 0..<n where out[i] != Float(expected + i) { ok = false }
            expected += n
            if n == 0 { usleep(10) }
        }
        #expect(ok)
        #expect(expected == total)
    }
}

@Suite struct ResamplerTests {
    func sine(_ hz: Double, rate: Double, seconds: Double) -> [Float] {
        (0..<Int(rate * seconds)).map { Float(sin(2 * .pi * hz * Double($0) / rate) * 0.5) }
    }

    @Test(arguments: [44_100.0, 48_000.0, 24_000.0, 96_000.0])
    func convertsToSixteenKilohertz(rate: Double) {
        let rs = Resampler(inputRate: rate)!
        let input = sine(440, rate: rate, seconds: 1)
        var out: [Float] = []
        var i = 0
        while i < input.count {
            let n = min(4096, input.count - i)
            input.withUnsafeBufferPointer { rs.process(UnsafeBufferPointer(rebasing: $0[i..<i + n])) { out.append(contentsOf: $0) } }
            i += n
        }
        rs.process(UnsafeBufferPointer(start: nil, count: 0), end: true) { out.append(contentsOf: $0) }
        #expect(abs(out.count - 16_000) < 64)
        // Same tone, same level: RMS of a 0.5-amplitude sine is ~0.354.
        let mid = out[2000..<14000]
        let rms = sqrt(mid.map { $0 * $0 }.reduce(0, +) / Float(mid.count))
        #expect(abs(rms - 0.354) < 0.02)
    }

    @Test func passesSixteenKilohertzThrough() {
        let rs = Resampler(inputRate: 16_000)!
        let input: [Float] = [0.1, 0.2, 0.3]
        var out: [Float] = []
        input.withUnsafeBufferPointer { rs.process($0) { out.append(contentsOf: $0) } }
        #expect(out == input)
    }

    @Test func resetAllowsReuseAcrossSessions() {
        let rs = Resampler(inputRate: 48_000)!
        for _ in 0..<3 {
            rs.reset()
            var count = 0
            let input = sine(300, rate: 48_000, seconds: 0.5)
            input.withUnsafeBufferPointer { b in
                var i = 0
                while i < b.count {
                    let n = min(4096, b.count - i)
                    rs.process(UnsafeBufferPointer(rebasing: b[i..<i + n])) { count += $0.count }
                    i += n
                }
            }
            rs.process(UnsafeBufferPointer(start: nil, count: 0), end: true) { count += $0.count }
            #expect(abs(count - 8000) < 64)
        }
    }
}

@Suite struct SpeechTests {
    @Test func sanitizeRepairsNonFiniteAndClips() {
        var s: [Float] = [0.1, .nan, .infinity, -.infinity, 3, -2, 0.5]
        let fixed = s.withUnsafeMutableBufferPointer { Speech.sanitize($0) }
        #expect(fixed == 5)
        #expect(s == [0.1, 0, 0, 0, 1, -1, 0.5])
    }

    @Test func silenceHasNoSpeech() {
        let s = [Float](repeating: 0, count: 16_000)
        let a = s.withUnsafeBufferPointer { Speech.analyze($0) }
        #expect(a.speech.isEmpty)
        let noise = (0..<16_000).map { _ in Float.random(in: -0.0005...0.0005) }
        #expect(noise.withUnsafeBufferPointer { Speech.analyze($0) }.speech.isEmpty)
    }

    @Test func toneIsFoundAndPadded() {
        var s = [Float](repeating: 0, count: 48_000)
        for i in 16_000..<32_000 { s[i] = Float(sin(Double(i) * 0.1)) * 0.3 }
        let a = s.withUnsafeBufferPointer { Speech.analyze($0) }
        #expect(a.speech.lowerBound <= 16_000 - 4000)
        #expect(a.speech.lowerBound >= 16_000 - 5000)
        #expect(a.speech.upperBound >= 32_000 + 4000)
        #expect(a.speech.upperBound <= 32_000 + 5000)
    }

    @Test func singleClickIsNotSpeech() {
        var s = [Float](repeating: 0, count: 16_000)
        for i in 8000..<8040 { s[i] = 0.9 }
        #expect(s.withUnsafeBufferPointer { Speech.analyze($0) }.speech.isEmpty)
    }
}

@Suite struct WAVTests {
    @Test func roundTripsPCM16() throws {
        let w = WAV(sampleRate: 16_000, samples: (0..<1600).map { Float(sin(Double($0) * 0.05)) * 0.8 })
        let back = try WAV(data: w.pcm16Data())
        #expect(back.sampleRate == 16_000)
        #expect(back.samples.count == 1600)
        for (a, b) in zip(w.samples, back.samples) { #expect(abs(a - b) < 1e-3) }
    }

    @Test func rejectsGarbage() {
        #expect(throws: WAV.Failure.self) { try WAV(data: Data("hello world, not audio".utf8)) }
        #expect(throws: WAV.Failure.self) { try WAV(data: Data()) }
    }

    @Test func truncatedHeaderThrows() throws {
        let d = WAV(sampleRate: 16_000, samples: [0.1, 0.2]).pcm16Data()
        #expect(throws: WAV.Failure.self) { try WAV(data: d.prefix(20)) }
    }

    @Test func toleratesDataChunkOverrunningFile() throws {
        let d = WAV(sampleRate: 16_000, samples: [Float](repeating: 0.25, count: 1000)).pcm16Data()
        let cut = try WAV(data: d.prefix(44 + 500 * 2))
        #expect(cut.samples.count == 500)
    }

    @Test func downmixesStereoFloat() throws {
        var d = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let frames: [(Float, Float)] = [(1, 0), (0.5, 0.5), (-1, 1)]
        d.append(contentsOf: Array("RIFF".utf8)); put32(36 + 24)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16)
        put16(3); put16(2); put32(48_000); put32(48_000 * 8); put16(8); put16(32)
        d.append(contentsOf: Array("data".utf8)); put32(24)
        for (l, r) in frames { put32(l.bitPattern); put32(r.bitPattern) }
        let w = try WAV(data: d)
        #expect(w.sampleRate == 48_000)
        #expect(w.samples == [0.5, 0.5, 0])
    }
}
