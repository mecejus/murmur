import Foundation

/// An AudioSource that plays a WAV file into the ring instead of a
/// microphone, from its own thread, in device-sized chunks. Used by the
/// integration tests, `murmur bench` and the soak test, so the whole pipeline
/// (ring, drain, resampler, trimming, model, output) runs without a mic.
///
/// Fault injection for tests: a corrupt (NaN/Inf/huge) chunk, losing the
/// device part-way through, a failing start.
public final class FileSource: AudioSource, @unchecked Sendable {
    public struct Faults {
        /// Replace the chunk at this second with garbage samples.
        public var corruptAt: Double?
        /// Stop delivering audio at this second and report the device lost.
        public var loseDeviceAt: Double?
        /// Make `start` throw this many times before succeeding.
        public var failStarts = 0

        public init() {}
    }

    public let ring: SampleRing
    public var onEvent: ((AudioSourceEvent) -> Void)?
    public private(set) var sampleRate: Double

    private var samples: [Float]
    private let chunk: Int
    private let speed: Double
    public var faults: Faults
    private let lock = NSLockLite()
    private var thread: Thread?
    private var running = false
    private var finishedFeeding = false
    private var doneSignal = DispatchSemaphore(value: 0)

    /// - Parameters:
    ///   - speed: 1 = real time. Higher feeds faster (the ring must hold the
    ///     difference until the drain catches up; overflow is counted).
    public init(wav: WAV, speed: Double = 1, chunk: Int = 512, faults: Faults = Faults()) {
        samples = wav.samples
        sampleRate = wav.sampleRate
        self.chunk = chunk
        self.speed = speed
        self.faults = faults
        ring = SampleRing(capacity: 48_000 * 8)!
    }

    /// Swaps in another recording for the next `start`. Not while running.
    public func load(_ wav: WAV) {
        samples = wav.samples
        sampleRate = wav.sampleRate
    }

    public var duration: Double { Double(samples.count) / sampleRate }

    public func start() throws {
        if faults.failStarts > 0 {
            faults.failStarts -= 1
            throw AudioSourceError.startFailed(-1)
        }
        ring.clear()
        lock.locked {
            running = true
            finishedFeeding = false
        }
        doneSignal = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in self?.feed() }
        t.qualityOfService = .userInteractive
        t.name = "murmur.filesource"
        thread = t
        t.start()
    }

    public func stop() {
        lock.locked { running = false }
    }

    /// Blocks until every sample has been written (or the feed stopped).
    public func waitUntilFed(timeout: TimeInterval = 600) {
        _ = doneSignal.wait(timeout: .now() + timeout)
    }

    public func invalidate() { stop() }

    public func takeHealth() -> AudioSourceHealth {
        var h = AudioSourceHealth()
        h.droppedSamples = ring.takeDropped()
        return h
    }

    private func feed() {
        var garbage = [Float](repeating: 0, count: chunk)
        for i in garbage.indices {
            garbage[i] = [Float.nan, .infinity, -.infinity, 1e9, -3][i % 5]
        }
        let interval = Double(chunk) / sampleRate / speed
        var next = DispatchTime.now().uptimeNanoseconds
        var pos = 0
        var corrupted = false
        defer {
            lock.locked { finishedFeeding = true }
            doneSignal.signal()
        }
        while pos < samples.count {
            guard lock.locked({ running }) else { return }
            let t = Double(pos) / sampleRate
            if let at = faults.loseDeviceAt, t >= at {
                lock.locked { running = false }
                onEvent?(.deviceLost("simulated device loss"))
                return
            }
            let n = min(chunk, samples.count - pos)
            if let at = faults.corruptAt, !corrupted, t >= at {
                corrupted = true
                garbage.withUnsafeBufferPointer { _ = ring.write(UnsafeBufferPointer(rebasing: $0[0..<n])) }
            } else {
                samples.withUnsafeBufferPointer { _ = ring.write(UnsafeBufferPointer(rebasing: $0[pos..<pos + n])) }
            }
            pos += n
            if speed.isFinite {
                next += UInt64(interval * 1e9)
                let now = DispatchTime.now().uptimeNanoseconds
                if next > now { usleep(UInt32((next - now) / 1000)) }
            }
        }
    }
}
