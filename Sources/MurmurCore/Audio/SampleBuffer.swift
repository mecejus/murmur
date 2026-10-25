import Darwin
import os

/// A fixed-capacity buffer of 16 kHz mono samples, allocated once and reused
/// for every dictation. Appending past capacity is refused, never grown.
public final class SampleBuffer: @unchecked Sendable {
    public let capacity: Int
    public private(set) var count = 0
    let storage: UnsafeMutablePointer<Float>

    public init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
    }

    deinit { storage.deallocate() }

    public var isFull: Bool { count >= capacity }
    public var remaining: Int { capacity - count }

    /// Appends as much of `src` as fits and returns how much that was.
    @discardableResult
    public func append(_ src: UnsafeBufferPointer<Float>) -> Int {
        let n = min(src.count, remaining)
        guard n > 0, let base = src.baseAddress else { return 0 }
        (storage + count).update(from: base, count: n)
        count += n
        return n
    }

    public func append(_ src: [Float]) -> Int {
        src.withUnsafeBufferPointer { append($0) }
    }

    public var samples: UnsafeBufferPointer<Float> { UnsafeBufferPointer(start: storage, count: count) }

    /// Empties the buffer. Pages a long recording touched are handed back to
    /// the kernel so one five-minute dictation does not pin 19 MB for the
    /// rest of the process's life.
    public func reset() {
        let touchedBytes = count * MemoryLayout<Float>.stride
        if touchedBytes > 4 << 20 {
            let page = Int(getpagesize())
            let base = Int(bitPattern: storage)
            let start = (base + page - 1) & ~(page - 1)
            let end = (base + touchedBytes) & ~(page - 1)
            if end > start, let p = UnsafeMutableRawPointer(bitPattern: start) {
                madvise(p, end - start, MADV_FREE)
            }
        }
        count = 0
    }
}

/// A fixed set of SampleBuffers. Taking from an empty pool fails; that is the
/// backpressure point for the whole pipeline (see Pipeline).
public final class BufferPool: @unchecked Sendable {
    private var free: [SampleBuffer]
    private let lock = NSLockLite()
    public let size: Int

    public init(count: Int, capacity: Int) {
        size = count
        free = (0..<count).map { _ in SampleBuffer(capacity: capacity) }
    }

    public func take() -> SampleBuffer? {
        lock.locked { free.popLast() }
    }

    public func give(_ b: SampleBuffer) {
        b.reset()
        lock.locked { free.append(b) }
    }

    public var available: Int { lock.locked { free.count } }
}

/// os_unfair_lock wrapper for short critical sections off the audio thread.
final class NSLockLite: @unchecked Sendable {
    private let l: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        p.initialize(to: os_unfair_lock())
        return p
    }()

    deinit { l.deallocate() }

    @inline(__always)
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(l)
        defer { os_unfair_lock_unlock(l) }
        return try body()
    }
}
