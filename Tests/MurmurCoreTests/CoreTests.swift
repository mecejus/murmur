import Foundation
import Testing
@testable import MurmurCore

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@Suite struct ConfigTests {
    @Test func missingKeysTakeDefaults() throws {
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"language":"lt"}"#.utf8))
        #expect(c.language == "lt")
        #expect(c.model == Config.defaultModelFile)
        #expect(c.queueDepth == 2)
        #expect(c.maxRecordSeconds == 300)
        #expect(c.fastDecode == false)
    }

    @Test func sanitizeClampsUnsafeValues() {
        var c = Config()
        c.queueDepth = 1000
        c.maxRecordSeconds = 0
        c.logLevel = "chatty"
        c.language = "  "
        let notes = c.sanitize()
        #expect(c.queueDepth == 8)
        #expect(c.maxRecordSeconds == 1)
        #expect(c.logLevel == "info")
        #expect(c.language == "auto")
        #expect(notes.count == 3)
    }

    @Test func firstRunWritesDefaultsThenReadsThem() throws {
        let dir = tempDir()
        let target = dir.appendingPathComponent("murmur/config.json")
        guard case .created(let cfg) = try ConfigStore.load(from: target) else {
            Issue.record("expected a new config")
            return
        }
        #expect(cfg == Config())
        #expect(FileManager.default.fileExists(atPath: target.path))
        guard case .loaded(let again) = try ConfigStore.load(from: target) else {
            Issue.record("expected the saved config")
            return
        }
        #expect(again == cfg)
    }

    @Test func malformedConfigThrows() throws {
        let dir = tempDir()
        let f = dir.appendingPathComponent("c.json")
        try Data("{not json".utf8).write(to: f)
        #expect(throws: (any Error).self) { try ConfigStore.load(from: f) }
    }

    @Test func relativeModelResolvesIntoModelsFolder() {
        var c = Config()
        c.model = "ggml-tiny.bin"
        #expect(c.modelURL.path.hasSuffix("Library/Application Support/murmur/models/ggml-tiny.bin"))
        c.model = "/tmp/x.bin"
        #expect(c.modelURL.path == "/tmp/x.bin")
    }
}

@Suite struct LogTests {
    @Test func rotatesAndStaysBounded() throws {
        let dir = tempDir()
        let file = dir.appendingPathComponent("t.log")
        let l = Log()
        l.configure(url: file, level: .debug, maxBytes: 4096, keep: 2, echoToStderr: false)
        for i in 0..<2000 { l.info("event", ["i": i, "pad": String(repeating: "x", count: 40)]) }
        l.flush()
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: file.path))
        #expect(fm.fileExists(atPath: file.path + ".1"))
        #expect(fm.fileExists(atPath: file.path + ".2"))
        #expect(!fm.fileExists(atPath: file.path + ".3"))
        var total: UInt64 = 0
        for p in [file.path, file.path + ".1", file.path + ".2"] {
            total += (try fm.attributesOfItem(atPath: p)[.size] as? UInt64) ?? 0
        }
        #expect(total < 4096 * 3 + 512)
    }

    @Test func writesOneJSONObjectPerLine() throws {
        let dir = tempDir()
        let file = dir.appendingPathComponent("t.log")
        let l = Log()
        l.configure(url: file, level: .info, echoToStderr: false)
        l.debug("hidden")
        l.info("shown", ["n": 1, "d": 0.12345, "s": "a/b", "inf": Double.infinity])
        l.flush()
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
        let obj = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        #expect(obj["event"] as? String == "shown")
        #expect(obj["s"] as? String == "a/b")
        #expect(obj["d"] as? Double == 0.123)
    }
}

@Suite struct FnTrackerTests {
    @Test func edgesFromFlags() {
        var t = FnTracker()
        #expect(t.flagsChanged(fn: true) == .down)
        #expect(t.flagsChanged(fn: true) == nil)
        #expect(t.flagsChanged(fn: false) == .up)
        #expect(t.flagsChanged(fn: false) == nil)
    }

    @Test func onlyKeycode63Counts() {
        var t = FnTracker()
        #expect(t.key(code: 9, down: true) == nil)
        #expect(t.key(code: 63, down: true) == .down)
        #expect(t.key(code: 63, down: false) == .up)
    }

    @Test func resyncReleasesAMissedKeyUp() {
        var t = FnTracker()
        _ = t.flagsChanged(fn: true)
        // The tap was disabled while fn came up; the up event never arrived.
        #expect(t.resync(fnNow: false) == .up)
        #expect(!t.isDown)
        #expect(t.resync(fnNow: false) == nil)
    }
}

@Suite struct TextTests {
    @Test func werIgnoresCaseAndPunctuation() {
        #expect(WER.rate(reference: "Hello, world.", hypothesis: "hello world") == 0)
        #expect(WER.rate(reference: "a b c d", hypothesis: "a x c d") == 0.25)
        #expect(WER.rate(reference: "a b", hypothesis: "") == 1)
    }

    @Test func cleanDropsNonSpeechAnnotations() {
        #expect(WhisperEngine.clean(" [BLANK_AUDIO] ") == "")
        #expect(WhisperEngine.clean("(music) Hello  there") == "Hello there")
        #expect(WhisperEngine.clean("Hello (and this is a long parenthetical remark that is speech) end")
                == "Hello (and this is a long parenthetical remark that is speech) end")
    }

    @Test func degenerateOutputIsDetected() {
        #expect(WhisperEngine.looksDegenerate(String(repeating: "Please schedule the review. ", count: 4), seconds: 4))
        #expect(WhisperEngine.looksDegenerate(String(repeating: "the ", count: 40), seconds: 3))
        #expect(!WhisperEngine.looksDegenerate("Please schedule the design review for Thursday afternoon.", seconds: 4))
    }
}

@Suite struct BufferTests {
    @Test func bufferRefusesPastCapacity() {
        let b = SampleBuffer(capacity: 4)
        #expect(b.append([1, 2, 3]) == 3)
        #expect(b.append([4, 5, 6]) == 1)
        #expect(b.isFull)
        b.reset()
        #expect(b.count == 0)
    }

    @Test func poolIsFixedSize() {
        let p = BufferPool(count: 2, capacity: 10)
        let a = p.take(), b = p.take()
        #expect(a != nil && b != nil)
        #expect(p.take() == nil)
        p.give(a!)
        #expect(p.available == 1)
    }

    @Test func processStatsAreSane() {
        let s = ProcessStats.current()
        #expect(s.footprint > 1 << 20)
        #expect(s.threads >= 1)
    }
}
