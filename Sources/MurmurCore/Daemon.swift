import AppKit
import Foundation

/// The long-running service: wires the fn tap, microphone, model and paste
/// output together, and owns process lifecycle (permissions, signals, sleep,
/// recovery).
public final class Daemon {
    public enum Exit: Int32 {
        /// Clean stop (signal) or a deliberate restart request; launchd's
        /// KeepAlive starts a fresh process.
        case ok = 0
        /// Recovery inside the process failed; launchd restarts it.
        case failure = 1
    }

    private let config: Config
    private var pipeline: Pipeline?
    private var tap: FnKeyTap?
    private var power: PowerMonitor?
    private var source: CoreAudioSource?
    private var signalSources: [DispatchSourceSignal] = []
    private var healthTimer: DispatchSourceTimer?
    private var axObserver: NSObjectProtocol?
    private let shuttingDown = NSLockLite()
    private var isShuttingDown = false

    /// Accessibility wait between restarts; see Permissions.
    static let accessRetryDelay: TimeInterval = 2

    public init(config: Config) {
        self.config = config
    }

    /// Runs until a signal or an unrecoverable error. Returns the exit code.
    public func run() -> Int32 {
        // An env var could otherwise make whisper.cpp dlopen an arbitrary
        // library (its optional ANE encoder).
        unsetenv("ANEFORGE_ENCODER")
        unsetenv("ANEFORGE_DYLIB")

        Self.capLaunchdLog()
        log.info("starting", ["version": Version.string, "pid": Int(getpid()), "model": config.model,
                              "language": config.language])

        // Accessibility first and before anything heavy: without it there is
        // no hotkey, and the process has to restart to see a new grant.
        guard Permissions.hasAccessibility else {
            if Permissions.markAccessPrompted() {
                Permissions.promptAccessibility()
                log.warn("accessibility_missing", ["hint": "System Settings > Privacy & Security > Accessibility: switch murmur on. It starts by itself once you do."])
            }
            Permissions.waitForAccessibilityChange(timeout: Self.accessRetryDelay)
            log.flush()
            return Exit.ok.rawValue
        }
        Permissions.clearAccessPrompted()

        if !Permissions.requestMicrophone() {
            // Not fatal: every press reports it until access is granted.
            log.error("microphone_denied", ["hint": "System Settings > Privacy & Security > Microphone: switch murmur on."])
        }

        guard let source = CoreAudioSource() else {
            log.error("startup_failed", ["error": "could not allocate the audio ring"])
            return Exit.failure.rawValue
        }
        self.source = source

        var opts = WhisperEngine.Options(modelURL: config.modelURL)
        opts.language = config.language
        opts.threads = config.effectiveThreads
        opts.gpu = config.gpu
        opts.prompt = config.prompt
        opts.fastDecode = config.fastDecode
        let engine = WhisperEngine(opts)

        var settings = Pipeline.Settings()
        settings.maxRecordSeconds = config.maxRecordSeconds
        settings.queueDepth = config.queueDepth
        let output: TextOutput = isatty(STDOUT_FILENO) != 0 ? EchoOutput(PasteOutput()) : PasteOutput()
        let pipeline = Pipeline(source: source, transcriber: engine, output: output,
                                chimes: SystemChimes(enabled: config.sounds), settings: settings)
        pipeline.onUnrecoverable = { [weak self] why in
            DispatchQueue.main.async { self?.stop(.failure, reason: why) }
        }
        self.pipeline = pipeline
        pipeline.start()

        let tap = FnKeyTap { edge in
            switch edge {
            case .down: pipeline.press()
            case .up: pipeline.release()
            }
        }
        do {
            try tap.start()
        } catch {
            // Usually the grant was revoked between the check above and now.
            log.error("hotkey_failed", ["error": error])
            pipeline.shutdown(timeout: 5)
            log.flush()
            return Exit.ok.rawValue
        }
        self.tap = tap

        watchAccessibility()
        watchPower()
        watchSignals()
        startHealthLog()

        print("murmur ready — hold [fn] to dictate. Ctrl-C to quit.")
        fflush(stdout)
        log.info("ready", ProcessStats.current().fields)

        CFRunLoopRun()
        return exitCode.rawValue
    }

    private var exitCode: Exit = .ok

    /// launchd appends the process's stdout/stderr to launchd.log, which
    /// only ever gets the ready line and crash output. Keep even that from
    /// growing without bound.
    static func capLaunchdLog() {
        let url = Paths.logDir.appendingPathComponent("launchd.log")
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64, size > 1 << 20,
           let h = try? FileHandle(forWritingTo: url) {
            try? h.truncate(atOffset: 0)
            try? h.close()
        }
    }

    /// Graceful stop on the main thread: no new recordings, finish what is
    /// queued (bounded), free the model, flush the log, leave the run loop.
    func stop(_ code: Exit, reason: String) {
        let first = shuttingDown.locked { () -> Bool in
            defer { isShuttingDown = true }
            return !isShuttingDown
        }
        guard first else { return }
        log.info("stopping", ["reason": reason])
        exitCode = code
        tap?.stop()
        healthTimer?.cancel()
        pipeline?.shutdown(timeout: 10)
        log.info("stopped", ProcessStats.current().fields)
        log.flush()
        CFRunLoopStop(CFRunLoopGetMain())
    }

    private func watchSignals() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in self?.stop(.ok, reason: sig == SIGTERM ? "SIGTERM" : "SIGINT") }
            s.resume()
            signalSources.append(s)
        }
    }

    /// A revoked Accessibility grant kills the hotkey silently. Exit so
    /// launchd restarts into the wait-for-grant path.
    private func watchAccessibility() {
        axObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The notification can arrive before the TCC change lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !Permissions.hasAccessibility {
                    log.warn("accessibility_revoked")
                    self?.stop(.ok, reason: "accessibility revoked")
                }
            }
        }
    }

    private func watchPower() {
        let p = PowerMonitor { [weak self] event in
            guard let self, let pipeline = self.pipeline else { return }
            switch event {
            case .willSleep:
                log.info("system_will_sleep")
                pipeline.cancelRecording(reason: "sleep")
                self.source?.invalidate()
            case .didWake:
                log.info("system_did_wake")
                // Rebuilt against the then-current device on the next press.
                self.source?.invalidate()
            }
        }
        if p.start() { power = p } else { log.warn("power_notifications_unavailable") }
    }

    /// One line of resource numbers every 10 minutes: the cheapest way to see
    /// from the log alone whether memory or threads creep over days.
    private func startHealthLog() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 600, repeating: 600, leeway: .seconds(30))
        t.setEventHandler { log.info("health", ProcessStats.current().fields) }
        t.resume()
        healthTimer = t
    }
}

/// When run in a terminal, also print what was heard. Under launchd stdout
/// is not a terminal and nothing dictated is written anywhere.
final class EchoOutput: TextOutput {
    let inner: TextOutput
    init(_ inner: TextOutput) { self.inner = inner }
    func deliver(_ text: String) throws -> DispatchTime {
        let t = try inner.deliver(text)
        print("✓ \(text)")
        fflush(stdout)
        return t
    }
}

public enum Version {
    public static let string = "0.1.0"
}
