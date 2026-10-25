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

/// Pastes into the focused app: put the text (plus a
/// trailing space, so consecutive dictations don't run together) on the
/// pasteboard, post Cmd+V, then put back what the pasteboard held before.
/// Needs Accessibility access for the keystroke.
public final class PasteOutput: TextOutput {
    /// How long the focused app gets to read the pasteboard before the
    /// previous contents are restored. Cmd+V is asynchronous.
    let restoreDelay: TimeInterval

    public init(restoreDelay: TimeInterval = 0.15) {
        self.restoreDelay = restoreDelay
    }

    public func deliver(_ text: String) throws -> DispatchTime {
        guard !text.isEmpty else { return .now() }
        return try autoreleasepool {
            let pb = NSPasteboard.general
            let saved = Self.snapshot(pb)
            pb.clearContents()
            guard pb.setString(text + " ", forType: .string) else { throw OutputError.pasteboardWrite }
            let ourChange = pb.changeCount

            guard Self.postCmdV() else {
                Self.restore(pb, saved)
                throw OutputError.keystroke
            }
            let posted = DispatchTime.now()
            Thread.sleep(forTimeInterval: restoreDelay)
            // If something else wrote the pasteboard meanwhile (the user
            // copied), leave theirs alone.
            if pb.changeCount == ourChange { Self.restore(pb, saved) }
            return posted
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

    static func postCmdV() -> Bool {
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
