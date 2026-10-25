import Foundation

/// Drives the real pipeline from WAV files: the same ring, drain, resampler,
/// trimming, model and ordering as live dictation, with a FileSource in place
/// of the microphone and an in-memory output in place of the paste.
public final class OfflineRunner {
    public let pipeline: Pipeline
    public let source: FileSource
    public let output = RecordingOutput()
    public let chimes = SilentChimes()
    private let reports = DispatchSemaphore(value: 0)
    private let lock = NSLockLite()
    private var last: Pipeline.Report?

    /// - Parameter speed: how fast the file is played into the ring
    ///   (1 = real time, as a person speaking; `.infinity` = as fast as
    ///   possible).
    public init(transcriber: Transcriber, settings: Pipeline.Settings = Pipeline.Settings(), speed: Double = 1,
                faults: FileSource.Faults = FileSource.Faults()) {
        source = FileSource(wav: WAV(sampleRate: 16_000, samples: []), speed: speed, faults: faults)
        pipeline = Pipeline(source: source, transcriber: transcriber, output: output, chimes: chimes, settings: settings)
        pipeline.onReport = { [weak self] r in
            guard let self else { return }
            self.lock.locked { self.last = r }
            self.reports.signal()
        }
    }

    public convenience init(engine options: WhisperEngine.Options, settings: Pipeline.Settings = Pipeline.Settings(), speed: Double = 1) {
        self.init(transcriber: WhisperEngine(options), settings: settings, speed: speed)
    }

    /// Starts the pipeline and waits for the model to load and warm up.
    public func start(timeout: TimeInterval = 300) -> Bool {
        pipeline.start()
        return pipeline.waitUntilReady(timeout: timeout)
    }

    public struct Result {
        public var text: String?
        public var report: Pipeline.Report?
    }

    /// Dictates one file and waits for its result.
    public func run(_ wav: WAV, timeout: TimeInterval = 300) -> Result {
        let before = output.texts.count
        source.load(wav)
        guard pipeline.runFile(source) else { return Result() }
        guard reports.wait(timeout: .now() + timeout) == .success else { return Result() }
        let r = lock.locked { last }
        let texts = output.texts
        let text: String? = texts.count > before ? texts.last : nil
        return Result(text: text, report: r)
    }

    public func shutdown() { pipeline.shutdown() }
}
