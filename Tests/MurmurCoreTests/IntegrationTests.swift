import Foundation
import Testing
@testable import MurmurCore

/// End-to-end tests with the real whisper.cpp engine. They use the small
/// `ggml-tiny.bin` model (fast) from the models folder, or MURMUR_TEST_MODEL,
/// and speech generated with macOS `say`, so no microphone is involved.
/// Skipped when no model is present.
enum Fixture {
    static let model: URL = {
        if let p = ProcessInfo.processInfo.environment["MURMUR_TEST_MODEL"] { return URL(fileURLWithPath: p) }
        return Paths.models.appendingPathComponent("ggml-tiny.bin")
    }()

    static var hasModel: Bool { FileManager.default.fileExists(atPath: model.path) }

    static let sentence = "Please schedule the design review for Thursday afternoon."

    /// A WAV of `text` spoken by the system voice, at `rate`.
    static func speech(_ text: String = sentence, rate: Int = 16_000) throws -> WAV {
        let url = tempDir().appendingPathComponent("say.wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "Samantha", "-o", url.path, "--data-format=LEI16@\(rate)", text]
        try p.run()
        p.waitUntilExit()
        return try WAV(contentsOf: url)
    }

    static func engine(language: String = "en") -> WhisperEngine {
        var o = WhisperEngine.Options(modelURL: model)
        o.language = language
        o.threads = 4
        return WhisperEngine(o)
    }
}

/// Wraps the real engine and fails on demand, to test recovery from model
/// errors with the real model underneath.
final class FlakyTranscriber: Transcriber, @unchecked Sendable {
    let inner: Transcriber
    var failNext = 0
    private(set) var loads = 0
    init(_ inner: Transcriber) { self.inner = inner }
    var isLoaded: Bool { inner.isLoaded }
    func load() throws { loads += 1; try inner.load() }
    func unload() { inner.unload() }
    func transcribe(_ samples: UnsafeBufferPointer<Float>, timeout: TimeInterval) throws -> String {
        if failNext > 0 {
            failNext -= 1
            throw TranscribeError.inferenceFailed(-3)
        }
        return try inner.transcribe(samples, timeout: timeout)
    }
}

@Suite(.serialized, .enabled(if: Fixture.hasModel, "no ggml-tiny.bin in the models folder"))
struct IntegrationTests {
    /// The headline integration test: a WAV through the whole pipeline
    /// (FileSource → ring → drain → resampler → trim → whisper → output),
    /// played at real-time speed like a person speaking.
    @Test func wavThroughFullPipelineInRealTime() throws {
        pipelineLogQuiet()
        let wav = try Fixture.speech()
        let r = OfflineRunner(transcriber: Fixture.engine(), speed: 1)
        #expect(r.start(timeout: 120))
        let res = r.run(wav)
        let text = try #require(res.text)
        #expect(WER.rate(reference: Fixture.sentence, hypothesis: text) < 0.25, "heard: \(text)")
        #expect(res.report?.latency.map { $0 < 10 } == true)
        r.shutdown()
    }

    @Test func deviceRateAudioIsResampled() throws {
        pipelineLogQuiet()
        let wav = try Fixture.speech(rate: 48_000)
        let r = OfflineRunner(transcriber: Fixture.engine(), speed: 4)
        #expect(r.start(timeout: 120))
        let text = try #require(r.run(wav).text)
        #expect(WER.rate(reference: Fixture.sentence, hypothesis: text) < 0.25, "heard: \(text)")
        r.shutdown()
    }

    @Test func corruptChunkWithRealModel() throws {
        pipelineLogQuiet()
        var faults = FileSource.Faults()
        faults.corruptAt = 1.0
        let r = OfflineRunner(transcriber: Fixture.engine(), speed: .infinity, faults: faults)
        #expect(r.start(timeout: 120))
        let text = try #require(r.run(try Fixture.speech()).text)
        // One 32 ms burst of garbage costs at most a word.
        #expect(WER.rate(reference: Fixture.sentence, hypothesis: text) < 0.4, "heard: \(text)")
        r.shutdown()
    }

    @Test func deviceLossWithRealModel() throws {
        pipelineLogQuiet()
        var faults = FileSource.Faults()
        faults.loseDeviceAt = 1.6
        let r = OfflineRunner(transcriber: Fixture.engine(), speed: .infinity, faults: faults)
        #expect(r.start(timeout: 120))
        let partial = r.run(try Fixture.speech())
        #expect(partial.report != nil)
        r.source.faults = FileSource.Faults()
        let text = try #require(r.run(try Fixture.speech()).text)
        #expect(WER.rate(reference: Fixture.sentence, hypothesis: text) < 0.25, "heard: \(text)")
        r.shutdown()
    }

    @Test func modelErrorsRecoverWithRealModel() throws {
        pipelineLogQuiet()
        let flaky = FlakyTranscriber(Fixture.engine())
        let r = OfflineRunner(transcriber: flaky, speed: .infinity)
        #expect(r.start(timeout: 120))
        let wav = try Fixture.speech()
        flaky.failNext = 2
        _ = r.run(wav)
        _ = r.run(wav)
        #expect(flaky.loads == 2)
        let text = try #require(r.run(wav).text)
        #expect(WER.rate(reference: Fixture.sentence, hypothesis: text) < 0.25, "heard: \(text)")
        r.shutdown()
    }

    /// The real abort path: a deadline that has already passed aborts the
    /// call inside whisper.cpp, and the engine keeps working afterwards.
    @Test func inferenceDeadlineAbortsAndEngineSurvives() throws {
        pipelineLogQuiet()
        let e = Fixture.engine()
        try e.load()
        let wav = try Fixture.speech()
        #expect(throws: TranscribeError.timedOut(0.0001)) {
            try wav.samples.withUnsafeBufferPointer { try e.transcribe($0, timeout: 0.0001) }
        }
        let text = try wav.samples.withUnsafeBufferPointer { try e.transcribe($0, timeout: 60) }
        #expect(WER.rate(reference: Fixture.sentence, hypothesis: text) < 0.25, "heard: \(text)")
        e.unload()
    }

    @Test func missingModelFileIsAnErrorNotACrash() {
        var o = WhisperEngine.Options(modelURL: URL(fileURLWithPath: "/nonexistent/model.bin"))
        o.threads = 1
        let e = WhisperEngine(o)
        #expect(throws: TranscribeError.self) { try e.load() }
        #expect(!e.isLoaded)
    }

    @Test func corruptModelFileIsAnErrorNotACrash() throws {
        let f = tempDir().appendingPathComponent("bad.bin")
        try Data(repeating: 0x41, count: 4096).write(to: f)
        let e = WhisperEngine(WhisperEngine.Options(modelURL: f))
        #expect(throws: TranscribeError.self) { try e.load() }
    }
}
