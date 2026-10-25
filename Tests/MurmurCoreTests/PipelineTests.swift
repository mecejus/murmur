import Foundation
import Testing
@testable import MurmurCore

/// A scriptable model for exercising the pipeline without whisper.
final class FakeTranscriber: Transcriber, @unchecked Sendable {
    enum Step { case text(String), fail(TranscribeError) }

    private let lock = NSLock()
    private var _loaded = false
    private var _loads = 0
    private var _calls = 0
    private var _inputs: [(count: Int, finite: Bool)] = []
    var script: [Step] = []
    var loadFailures = 0
    var delay: TimeInterval = 0

    var isLoaded: Bool { lock.withLock { _loaded } }
    var loads: Int { lock.withLock { _loads } }
    var calls: Int { lock.withLock { _calls } }
    var inputs: [(count: Int, finite: Bool)] { lock.withLock { _inputs } }

    func load() throws {
        try lock.withLock {
            _loads += 1
            if loadFailures > 0 {
                loadFailures -= 1
                throw TranscribeError.modelMissing("/nowhere")
            }
            _loaded = true
        }
    }

    func unload() { lock.withLock { _loaded = false } }

    func transcribe(_ samples: UnsafeBufferPointer<Float>, timeout: TimeInterval) throws -> String {
        let finite = samples.allSatisfy { $0.isFinite && abs($0) <= 1 }
        let (n, step): (Int, Step?) = lock.withLock {
            _calls += 1
            _inputs.append((samples.count, finite))
            return (_calls, script.isEmpty ? nil : script.removeFirst())
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        switch step {
        case .fail(let e)?: throw e
        case .text(let t)?: return t
        case nil: return "dictation \(n)"
        }
    }
}

/// Tone bursts with gaps: passes the speech detector like a short phrase.
func speechLike(seconds: Double, rate: Double = 16_000) -> WAV {
    let n = Int(seconds * rate)
    var s = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / rate
        let inWord = (t.truncatingRemainder(dividingBy: 0.5)) < 0.35 && t > 0.2 && t < seconds - 0.2
        if inWord { s[i] = Float(sin(2 * .pi * 220 * t) * 0.3 + sin(2 * .pi * 660 * t) * 0.1) }
    }
    return WAV(sampleRate: rate, samples: s)
}

func makeRunner(_ fake: FakeTranscriber, _ settings: Pipeline.Settings = Pipeline.Settings(),
                faults: FileSource.Faults = FileSource.Faults()) -> OfflineRunner {
    let r = OfflineRunner(transcriber: fake, settings: settings, speed: .infinity, faults: faults)
    pipelineLogQuiet()
    return r
}

func pipelineLogQuiet() {
    log.configure(url: nil, level: .error, echoToStderr: false)
}

@Suite(.serialized) struct PipelineTests {
    @Test func deliversText() {
        let fake = FakeTranscriber()
        fake.script = [.text(""), .text("hello there")] // first call is the warm-up
        let r = makeRunner(fake)
        #expect(r.start(timeout: 5))
        let res = r.run(speechLike(seconds: 2))
        #expect(res.text == "hello there")
        #expect(res.report?.outcome == .delivered(chars: 11))
        #expect(res.report?.latency != nil)
        #expect(r.chimes.played == [.start, .stop])
        r.shutdown()
        #expect(!fake.isLoaded) // shutdown frees the model
    }

    @Test func modelLoadsOnceAcrossManyDictations() {
        let fake = FakeTranscriber()
        let r = makeRunner(fake)
        #expect(r.start(timeout: 5))
        for _ in 0..<20 { _ = r.run(speechLike(seconds: 1)) }
        #expect(fake.loads == 1)
        #expect(r.output.texts.count == 20)
        r.shutdown()
    }

    @Test func strayTapIsIgnored() {
        let fake = FakeTranscriber()
        let r = makeRunner(fake)
        #expect(r.start(timeout: 5))
        let res = r.run(speechLike(seconds: 0.2))
        #expect(res.report?.outcome == .tooShort)
        #expect(fake.calls == 1) // only the warm-up
        r.shutdown()
    }

    @Test func silenceIsNotSentToTheModel() {
        let fake = FakeTranscriber()
        let r = makeRunner(fake)
        #expect(r.start(timeout: 5))
        let res = r.run(WAV(sampleRate: 16_000, samples: [Float](repeating: 0, count: 32_000)))
        #expect(res.report?.outcome == .noSpeech)
        #expect(fake.calls == 1)
        r.shutdown()
    }

    @Test func resultsArriveInDictationOrder() {
        let fake = FakeTranscriber()
        fake.delay = 0.15
        var s = Pipeline.Settings()
        s.queueDepth = 3
        let r = makeRunner(fake, s)
        #expect(r.start(timeout: 5))
        var done = 0
        let sem = DispatchSemaphore(value: 0)
        r.pipeline.onReport = { _ in done += 1; sem.signal() }
        for _ in 0..<4 {
            r.source.load(speechLike(seconds: 1))
            #expect(r.pipeline.runFile(r.source))
        }
        for _ in 0..<4 { _ = sem.wait(timeout: .now() + 10) }
        #expect(r.output.texts == ["dictation 2", "dictation 3", "dictation 4", "dictation 5"])
        r.shutdown()
    }

    /// The pool is the bound: with queue_depth 0 there is one buffer being
    /// transcribed and one being recorded. A third press while both are busy
    /// is refused, with the error chime, instead of queueing without limit.
    @Test func backlogRefusesNewPressInsteadOfGrowing() {
        let fake = FakeTranscriber()
        fake.delay = 1.0
        var s = Pipeline.Settings()
        s.queueDepth = 0
        let r = makeRunner(fake, s)
        #expect(r.start(timeout: 5))
        r.source.load(speechLike(seconds: 1))
        #expect(r.pipeline.runFile(r.source))   // goes to the model (slow)
        #expect(r.pipeline.runFile(r.source))   // waits in the second buffer
        #expect(!r.pipeline.runFile(r.source))  // no buffer left: refused
        #expect(r.chimes.played.last == .error)
        Thread.sleep(forTimeInterval: 2.5)
        // Capacity is back once the backlog drains.
        #expect(r.pipeline.runFile(r.source))
        r.shutdown()
    }

    @Test func recordingIsCappedAtMaxDuration() {
        let fake = FakeTranscriber()
        var s = Pipeline.Settings()
        s.maxRecordSeconds = 1
        let r = makeRunner(fake, s)
        #expect(r.start(timeout: 5))
        let res = r.run(speechLike(seconds: 3))
        #expect(res.report.map { abs($0.audioSeconds - 1.0) < 0.01 } == true)
        #expect(res.text != nil)
        r.shutdown()
    }

    // MARK: Faults

    @Test func corruptChunkIsRepairedBeforeTheModel() {
        let fake = FakeTranscriber()
        var faults = FileSource.Faults()
        faults.corruptAt = 0.8
        let r = makeRunner(fake, faults: faults)
        #expect(r.start(timeout: 5))
        let res = r.run(speechLike(seconds: 2))
        #expect(res.text != nil)
        #expect(fake.inputs.last?.finite == true)
        r.shutdown()
    }

    @Test func deviceLossMidRecordingKeepsWhatWasSaidAndRecovers() {
        let fake = FakeTranscriber()
        var faults = FileSource.Faults()
        faults.loseDeviceAt = 1.5
        let r = makeRunner(fake, faults: faults)
        #expect(r.start(timeout: 5))
        let res = r.run(speechLike(seconds: 4))
        #expect(res.text != nil)
        #expect(res.report.map { $0.audioSeconds < 1.7 } == true)
        // The next dictation works normally.
        r.source.faults = FileSource.Faults()
        let next = r.run(speechLike(seconds: 2))
        #expect(next.text != nil)
        #expect(next.report.map { $0.audioSeconds > 1.9 } == true)
        r.shutdown()
    }

    @Test func failedStartIsReportedAndTheNextPressWorks() {
        let fake = FakeTranscriber()
        var faults = FileSource.Faults()
        faults.failStarts = 1
        let r = makeRunner(fake, faults: faults)
        #expect(r.start(timeout: 5))
        let first = r.run(speechLike(seconds: 1))
        #expect(first.report == nil)
        #expect(r.chimes.played.last == .error)
        let second = r.run(speechLike(seconds: 1))
        #expect(second.text != nil)
        r.shutdown()
    }

    @Test func repeatedModelErrorsTriggerReloadAndRecovery() {
        let fake = FakeTranscriber()
        // Warm-up, two failures, the warm-up after the reload, then success.
        fake.script = [.text(""), .fail(.inferenceFailed(-6)), .fail(.inferenceFailed(-6)), .text(""), .text("back")]
        let r = makeRunner(fake)
        #expect(r.start(timeout: 5))
        let a = r.run(speechLike(seconds: 1))
        let b = r.run(speechLike(seconds: 1))
        guard case .failed? = a.report?.outcome, case .failed? = b.report?.outcome else {
            Issue.record("expected two failures, got \(String(describing: a.report?.outcome)), \(String(describing: b.report?.outcome))")
            r.shutdown()
            return
        }
        #expect(fake.loads == 2) // reloaded after the second failure
        let c = r.run(speechLike(seconds: 1))
        #expect(c.text == "back")
        r.shutdown()
    }

    @Test func modelTimeoutIsAFailureNotAHang() {
        let fake = FakeTranscriber()
        fake.script = [.text(""), .fail(.timedOut(20))]
        let r = makeRunner(fake)
        #expect(r.start(timeout: 5))
        let a = r.run(speechLike(seconds: 1))
        #expect(a.report?.outcome == .failed("inference exceeded 20 s and was aborted"))
        #expect(r.run(speechLike(seconds: 1)).text != nil)
        r.shutdown()
    }

    @Test func missingModelIsRetriedWithoutCrashing() {
        let fake = FakeTranscriber()
        fake.loadFailures = 2
        var s = Pipeline.Settings()
        s.modelRetryInterval = 0.2
        let r = makeRunner(fake, s)
        r.pipeline.start()
        // Presses before the model is there are refused, not crashes.
        #expect(!r.pipeline.runFile(r.source))
        #expect(r.chimes.played.last == .error)
        #expect(r.pipeline.waitUntilReady(timeout: 5))
        #expect(fake.loads == 3)
        #expect(r.run(speechLike(seconds: 1)).text != nil)
        r.shutdown()
    }

    @Test func outputFailureDoesNotStopLaterDictations() {
        let fake = FakeTranscriber()
        let r = makeRunner(fake)
        #expect(r.start(timeout: 5))
        r.output.failNext = 1
        let a = r.run(speechLike(seconds: 1))
        guard case .failed? = a.report?.outcome else {
            Issue.record("expected failure")
            r.shutdown()
            return
        }
        #expect(r.run(speechLike(seconds: 1)).text != nil)
        r.shutdown()
    }

    @Test func resamplesFromDeviceRate() {
        let fake = FakeTranscriber()
        let r = makeRunner(fake)
        #expect(r.start(timeout: 5))
        let res = r.run(speechLike(seconds: 2, rate: 48_000))
        #expect(res.report.map { abs($0.audioSeconds - 2.0) < 0.02 } == true)
        r.shutdown()
    }
}
