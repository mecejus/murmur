import Foundation
import IOKit
import IOKit.pwr_mgt

/// System sleep and wake notifications (IOKit; works without an
/// NSApplication). Audio devices and event taps do not survive sleep
/// reliably, so the daemon ends any recording before sleep and rebuilds
/// input after wake.
public final class PowerMonitor: @unchecked Sendable {
    public enum Event: Sendable { case willSleep, didWake }

    private var root: io_connect_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private let handler: (Event) -> Void

    public init(handler: @escaping (Event) -> Void) {
        self.handler = handler
    }

    /// Registers on the current thread's run loop (the main run loop).
    public func start() -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        root = IORegisterForSystemPower(refcon, &port, { refcon, _, type, arg in
            guard let refcon else { return }
            let me = Unmanaged<PowerMonitor>.fromOpaque(refcon).takeUnretainedValue()
            me.received(type, arg)
        }, &notifier)
        guard root != 0, let port else { return false }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        return true
    }

    private func received(_ type: natural_t, _ arg: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: arg)
        switch Int(type) {
        case 0xE0000270: // kIOMessageCanSystemSleep
            IOAllowPowerChange(root, token)
        case 0xE0000280: // kIOMessageSystemWillSleep
            handler(.willSleep)
            IOAllowPowerChange(root, token)
        case 0xE0000300: // kIOMessageSystemHasPoweredOn
            handler(.didWake)
        default:
            break
        }
    }

    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if root != 0 { IOServiceClose(root) }
        if let port { IONotificationPortDestroy(port) }
    }
}
