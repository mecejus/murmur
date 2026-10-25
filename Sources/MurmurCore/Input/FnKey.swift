import CoreGraphics
import Foundation

/// fn (Globe) press/release detection, as a pure state machine so it can be
/// tested without an event tap. Keycode 63 is fn on every Mac keyboard.
public struct FnTracker: Sendable {
    public enum Edge: Equatable, Sendable { case down, up }
    public static let keycode: Int64 = 63

    public private(set) var isDown = false

    public init() {}

    mutating func set(_ down: Bool) -> Edge? {
        guard down != isDown else { return nil }
        isDown = down
        return down ? .down : .up
    }

    /// A flagsChanged event; `fn` is whether the secondary-fn flag is set.
    public mutating func flagsChanged(fn: Bool) -> Edge? { set(fn) }

    public mutating func key(code: Int64, down: Bool) -> Edge? {
        code == Self.keycode ? set(down) : nil
    }

    /// After the tap was disabled events were lost, so fn may have come up
    /// unseen. Re-read the live state instead of waiting for an edge that
    /// already passed (and recording until the cap).
    public mutating func resync(fnNow: Bool) -> Edge? { set(fnNow) }
}

/// A listen-only CGEventTap for fn on its own thread and run loop.
///
/// The callback does no work beyond the tracker and an async hand-off, so it
/// cannot trip the tap timeout. If macOS disables the tap anyway (timeout or
/// user input), it is re-enabled and fn is resynced; a 5 s check catches a
/// tap that was disabled without any notification.
public final class FnKeyTap: @unchecked Sendable {
    public enum TapError: Error, CustomStringConvertible {
        case refused
        public var description: String { "the system refused the keyboard event tap (Accessibility access missing?)" }
    }

    private let onEdge: (FnTracker.Edge) -> Void
    private var tracker = FnTracker()   // tap thread only
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    public init(onEdge: @escaping (FnTracker.Edge) -> Void) {
        self.onEdge = onEdge
    }

    /// Installs the tap and returns once it is live, or throws.
    public func start() throws {
        let ready = DispatchSemaphore(value: 0)
        var ok = false
        let t = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            ok = self.install()
            ready.signal()
            if ok { CFRunLoopRun() }
        }
        t.name = "murmur.eventtap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()
        if !ok { throw TapError.refused }
    }

    public func stop() {
        guard let rl = runLoop else { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        CFRunLoopStop(rl)
        runLoop = nil
    }

    private func install() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: { _, type, event, refcon in
                                              if let refcon {
                                                  Unmanaged<FnKeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
                                              }
                                              return Unmanaged.passUnretained(event)
                                          }, userInfo: refcon) else { return false }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        let check = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 5, 5, 0, 0) { [weak self] _ in
            guard let self, let tap = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                log.warn("event_tap_reenabled", ["cause": "found disabled"])
                self.reenable()
            }
        }
        CFRunLoopAddTimer(runLoop, check, .commonModes)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        let edge: FnTracker.Edge?
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            log.warn("event_tap_reenabled", ["cause": type == .tapDisabledByTimeout ? "timeout" : "user input"])
            reenable()
            return
        case .flagsChanged:
            edge = tracker.flagsChanged(fn: event.flags.contains(.maskSecondaryFn))
        case .keyDown, .keyUp:
            edge = tracker.key(code: event.getIntegerValueField(.keyboardEventKeycode), down: type == .keyDown)
        default:
            edge = nil
        }
        if let edge { onEdge(edge) }
    }

    private func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        let fnNow = CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        if let edge = tracker.resync(fnNow: fnNow) { onEdge(edge) }
    }
}
