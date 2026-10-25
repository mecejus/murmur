import AppKit
import Foundation
import Testing
@testable import MurmurCore

/// PasteOutput against a private pasteboard, with the Cmd+V keystroke
/// replaced by a simulated app that reads the pasteboard when it gets to it.
@Suite(.serialized) struct PasteTests {
    func board(holding old: String) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("murmur-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString(old, forType: .string)
        return pb
    }

    /// An app that reads the pasteboard `after` seconds after the keystroke.
    final class SlowApp: @unchecked Sendable {
        private let lock = NSLock()
        private var _pasted: String?
        var pasted: String? { lock.withLock { _pasted } }

        func keystroke(_ pb: NSPasteboard, after: TimeInterval) -> () -> Bool {
            return {
                DispatchQueue.global().asyncAfter(deadline: .now() + after) {
                    let s = pb.string(forType: .string)
                    self.lock.withLock { self._pasted = s }
                }
                return true
            }
        }
    }

    /// The bug: a busy app reading later than the old fixed 150 ms restore
    /// got the previous clipboard. It must get the dictation.
    @Test func slowAppStillPastesTheDictation() throws {
        let pb = board(holding: "old clipboard")
        let app = SlowApp()
        let out = PasteOutput(pasteboard: pb, grace: 0.05, maxWait: 3, postKeystroke: app.keystroke(pb, after: 0.6))
        _ = try out.deliver("hello world")
        #expect(app.pasted == "hello world ")
        #expect(pb.string(forType: .string) == "old clipboard")
    }

    @Test func fastAppPastesAndClipboardIsRestored() throws {
        let pb = board(holding: "keep me")
        let app = SlowApp()
        let out = PasteOutput(pasteboard: pb, grace: 0.05, maxWait: 3, postKeystroke: app.keystroke(pb, after: 0.01))
        let started = Date()
        _ = try out.deliver("quick")
        #expect(app.pasted == "quick ")
        #expect(pb.string(forType: .string) == "keep me")
        // Restored right after the read, not after the fallback timeout.
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func nothingReadsItSoTheClipboardComesBackAfterTheTimeout() throws {
        let pb = board(holding: "untouched")
        let out = PasteOutput(pasteboard: pb, grace: 0.05, maxWait: 0.3, postKeystroke: { true })
        _ = try out.deliver("lost")
        #expect(pb.string(forType: .string) == "untouched")
    }

    @Test func userCopyDuringPasteIsNotOverwritten() throws {
        let pb = board(holding: "old")
        let out = PasteOutput(pasteboard: pb, grace: 0.05, maxWait: 0.5, postKeystroke: {
            pb.clearContents()
            pb.setString("copied by the user", forType: .string)
            return true
        })
        _ = try out.deliver("dictation")
        #expect(pb.string(forType: .string) == "copied by the user")
    }

    @Test func failedKeystrokeRestoresAndThrows() {
        let pb = board(holding: "old")
        let out = PasteOutput(pasteboard: pb, postKeystroke: { false })
        #expect(throws: OutputError.self) { try out.deliver("x") }
        #expect(pb.string(forType: .string) == "old")
    }
}
