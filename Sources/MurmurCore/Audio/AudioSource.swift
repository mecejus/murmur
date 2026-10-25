import Foundation

public enum AudioSourceEvent: Equatable, Sendable {
    /// The device being recorded from went away or stopped delivering audio.
    case deviceLost(String)
    /// The default input changed; the next recording uses the new device.
    case deviceChanged
    /// Audio control calls keep hanging. Recovery inside the process has
    /// failed and a restart (launchd) is the remaining option.
    case unrecoverable(String)
}

public struct AudioSourceHealth: Sendable {
    public var droppedSamples: UInt64 = 0
    public var renderErrors = 0
    public var oversizedCallbacks: UInt64 = 0
}

/// Where dictation audio comes from. Samples arrive in `ring` (mono float at
/// `sampleRate`) between `start` and `stop`.
///
/// `start` and `stop` must return within a bounded time even when the
/// hardware misbehaves; implementations time out rather than hang.
public protocol AudioSource: AnyObject {
    var ring: SampleRing { get }
    /// Rate of the samples currently in the ring. Valid after `start`.
    var sampleRate: Double { get }
    var onEvent: ((AudioSourceEvent) -> Void)? { get set }
    func start() throws
    func stop()
    /// Drops device state (before sleep, or after an error) so the next
    /// `start` rebuilds it from the current default device.
    func invalidate()
    func takeHealth() -> AudioSourceHealth
}

public enum AudioSourceError: Error, CustomStringConvertible {
    case noInputDevice
    case setupFailed(OSStatus)
    case startFailed(OSStatus)
    case timedOut(String)
    case permissionDenied

    public var description: String {
        switch self {
        case .noInputDevice: return "no input device"
        case .setupFailed(let s): return "input setup failed (OSStatus \(s))"
        case .startFailed(let s): return "input start failed (OSStatus \(s))"
        case .timedOut(let op): return "audio \(op) timed out"
        case .permissionDenied: return "microphone access denied"
        }
    }
}
