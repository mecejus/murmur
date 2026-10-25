import ApplicationServices
import AVFoundation
import Foundation

/// Accessibility (for the fn event tap and the Cmd+V keystroke) and the
/// microphone.
public enum Permissions {
    public static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that deep-links to the Accessibility pane.
    public static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// macOS gives a process one answer for its whole life: a process told
    /// "no" keeps hearing "no" after the user flips the switch. So the
    /// service shows the prompt once (a marker file stops
    /// every restart from re-showing it for an hour), waits for the system's
    /// grant-changed notification or a short timeout, and exits so launchd
    /// starts a fresh process that can see the grant.
    public static func waitForAccessibilityChange(timeout: TimeInterval) {
        let name = Notification.Name("com.apple.accessibility.api")
        var changed = false
        let obs = DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: nil) { _ in
            changed = true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !changed, Date() < deadline {
            RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.25)))
        }
        DistributedNotificationCenter.default().removeObserver(obs)
    }

    /// True if the prompt should be shown now: the first time, or when the
    /// previous one is over an hour old.
    public static func markAccessPrompted(at marker: URL = Paths.accessPromptMarker) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let attrs = try? fm.attributesOfItem(atPath: marker.path),
           let mod = attrs[.modificationDate] as? Date, Date().timeIntervalSince(mod) < 3600 {
            return false
        }
        fm.createFile(atPath: marker.path, contents: nil)
        return true
    }

    public static func clearAccessPrompted(at marker: URL = Paths.accessPromptMarker) {
        try? FileManager.default.removeItem(at: marker)
    }

    public static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// Asks for microphone access if it has not been decided yet. Returns
    /// whether access is granted (waits up to `timeout` for the user).
    public static func requestMicrophone(timeout: TimeInterval = 120) -> Bool {
        switch microphone {
        case .authorized: return true
        case .denied, .restricted: return false
        default: break
        }
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            granted = ok
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        return granted
    }
}
