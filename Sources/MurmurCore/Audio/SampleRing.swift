import CRealtime

/// Owns a lock-free single-producer single-consumer float ring (CRealtime).
/// The producer is the CoreAudio input callback in C, or `FileSource` in
/// tests; the consumer is the pipeline's drain step.
public final class SampleRing: @unchecked Sendable {
    let raw: OpaquePointer

    public init?(capacity: Int) {
        guard capacity > 0, capacity <= 1 << 30, let r = mm_ring_create(UInt32(capacity)) else { return nil }
        raw = r
    }

    deinit { mm_ring_destroy(raw) }

    public var capacity: Int { Int(mm_ring_capacity(raw)) }
    public var available: Int { Int(mm_ring_available(raw)) }

    /// Producer side. Returns how many samples fit; the rest are dropped
    /// and counted.
    @discardableResult
    public func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
        guard let base = samples.baseAddress, !samples.isEmpty else { return 0 }
        return Int(mm_ring_write(raw, base, UInt32(samples.count)))
    }

    /// Consumer side.
    public func read(into out: UnsafeMutableBufferPointer<Float>) -> Int {
        guard let base = out.baseAddress, !out.isEmpty else { return 0 }
        return Int(mm_ring_read(raw, base, UInt32(out.count)))
    }

    public func takeDropped() -> UInt64 { mm_ring_take_dropped(raw) }

    public func clear() { mm_ring_clear(raw) }
}
