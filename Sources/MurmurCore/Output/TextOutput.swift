import AppKit
import CoreGraphics
import Foundation

/// Where finished text goes.
public protocol TextOutput: AnyObject {
    /// Delivers `text` and returns the moment it was handed to the system
    /// (the end of the end-of-speech-to-text latency measurement).
    func deliver(_ text: String) throws -> DispatchTime
}

public enum OutputError: Error, CustomStringConvertible {
    case pasteboardWrite
    case keystroke

    public var description: String {
        switch self {
        case .pasteboardWrite: return "could not write to the pasteboard"
        case .keystroke: return "could not post the Cmd+V keystroke"
        }
    }
}

/// Pastes into the focused app: put the text (plus a trailing space, so
/// consecutive dictations don't run together) on the pasteboard, post Cmd+V,
/// then put back what the pasteboard held before. Needs Accessibility access
/// for the keystroke.
///
/// Cmd+V is asynchronous: the app reads the pasteboard whenever it gets to
/// the keystroke. Restoring on a fixed timer (it used to be 150 ms) lost
/// that race whenever the app was busy, and the app pasted the *previous*
/// clipboard instead of the dictation. So the text is put on the pasteboard
/// as a promise: the pasteboard asks us for the data at the moment someone
/// reads it, which tells us the paste has happened. The old contents go
/// back a short grace period after that read, or after `maxWait` if nothing
/// reads it at all (no text field focused).
public final class PasteOutput: TextOutput {
    let pasteboard: NSPasteboard
    let postKeystroke: () -> Bool
    /// After the first read, how long before restoring, so an app that reads
    /// in more than one step finishes with our text.
    let grace: TimeInterval
    /// Longest wait for a read before restoring anyway.
    let maxWait: TimeInterval

    public init(pasteboard: NSPasteboard = .general, grace: TimeInterval = 0.2, maxWait: TimeInterval = 3,
                postKeystroke: @escaping () -> Bool = PasteOutput.postCmdV) {
        self.pasteboard = pasteboard
        self.grace = grace
        self.maxWait = maxWait
        self.postKeystroke = postKeystroke
    }

    public func deliver(_ text: String) throws -> DispatchTime {
        guard !text.isEmpty else { return .now() }
        return try autoreleasepool {
            let pb = pasteboard
            let saved = Self.snapshot(pb)
            let promise = Promise(text + " ")
            let item = NSPasteboardItem()
            pb.clearContents()
            guard item.setDataProvider(promise, forTypes: [.string]), pb.writeObjects([item]) else {
                Self.restore(pb, saved)
                throw OutputError.pasteboardWrite
            }
            let ourChange = pb.changeCount

            guard postKeystroke() else {
                Self.restore(pb, saved)
                throw OutputError.keystroke
            }
            let posted = DispatchTime.now()
            if promise.waitForRead(timeout: maxWait) {
                Thread.sleep(forTimeInterval: grace)
            } else {
                log.warn("paste_not_read", ["waited_s": maxWait, "hint": "no text field focused?"])
            }
            // If something else wrote the pasteboard meanwhile (the user
            // copied), leave theirs alone.
            if pb.changeCount == ourChange { Self.restore(pb, saved) }
            return posted
        }
    }

    /// Supplies the text when the pasteboard is read, and reports that read.
    final class Promise: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
        let text: String
        private let read = DispatchSemaphore(value: 0)
        private let lock = NSLockLite()
        private var signalled = false

        init(_ text: String) { self.text = text }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {
            item.setString(text, forType: type)
            let first = lock.locked { () -> Bool in
                defer { signalled = true }
                return !signalled
            }
            if first { read.signal() }
        }

        func waitForRead(timeout: TimeInterval) -> Bool {
            read.wait(timeout: .now() + timeout) == .success
        }
    }

    /// Every item and type on the pasteboard, so images and rich text the
    /// user had copied survive a dictation, not just plain text.
    /// Capped at 8 MB so a huge copied image cannot stall the paste or
    /// spike memory; past the cap only plain text is kept.
    static func snapshot(_ pb: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        var total = 0
        var out: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in pb.pasteboardItems ?? [] {
            var pairs: [(NSPasteboard.PasteboardType, Data)] = []
            for t in item.types {
                guard let d = item.data(forType: t) else { continue }
                total += d.count
                if total > 8 << 20 {
                    if let s = pb.string(forType: .string) { return [[(.string, Data(s.utf8))]] }
                    return []
                }
                pairs.append((t, d))
            }
            out.append(pairs)
        }
        return out
    }

    static func restore(_ pb: NSPasteboard, _ saved: [[(NSPasteboard.PasteboardType, Data)]]) {
        pb.clearContents()
        guard !saved.isEmpty else { return }
        let items: [NSPasteboardItem] = saved.map { pairs in
            let item = NSPasteboardItem()
            for (t, d) in pairs { item.setData(d, forType: t) }
            return item
        }
        pb.writeObjects(items)
    }

    public static func postCmdV() -> Bool {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

/// Collects output in memory; for tests and `murmur bench`.
public final class RecordingOutput: TextOutput, @unchecked Sendable {
    private let lock = NSLockLite()
    private var items: [String] = []
    public var failNext = 0

    public init() {}

    public func deliver(_ text: String) throws -> DispatchTime {
        try lock.locked {
            if failNext > 0 {
                failNext -= 1
                throw OutputError.keystroke
            }
            items.append(text)
        }
        return .now()
    }

    public var texts: [String] { lock.locked { items } }
}
