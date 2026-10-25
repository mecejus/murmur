import Foundation
import MurmurCore

// murmur: hold fn, speak, release; the words are pasted where the cursor is.
// Everything runs on this Mac (whisper.cpp); nothing is sent anywhere.

let usage = """
usage: murmur [command] [options]

commands:
  run                    run the dictation service (the default)
  transcribe FILE.wav..  transcribe files through the full pipeline and print the text
  bench FILE.wav..       end-of-speech to text latency, real-time playback (--runs N, --csv PATH)
  soak                   long-running stability test (--minutes N, --corpus DIR, --csv PATH, --speed X)
  mic-test               record a few seconds from the microphone and transcribe (--seconds N)
  check                  show permissions, model, input device and paths
  config                 print the effective configuration
  version                print the version

options:
  --config PATH          config file (default ~/.config/murmur/config.json)
  --model PATH           override the model
  --language CODE        override the language ("auto" or e.g. "en")
"""

struct Args {
    var command = "run"
    var files: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ argv: [String]) {
        var rest = Array(argv.dropFirst())
        if let first = rest.first, !first.hasPrefix("-") {
            command = first
            rest.removeFirst()
        }
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if ["wait-for-lock", "json", "help"].contains(key) {
                    flags.insert(key)
                } else if i + 1 < rest.count {
                    options[key] = rest[i + 1]
                    i += 1
                } else {
                    die("missing value for \(a)")
                }
            } else if a == "-h" {
                flags.insert("help")
            } else {
                files.append(a)
            }
            i += 1
        }
    }
}

func die(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("murmur: \(msg)\n".utf8))
    exit(code)
}

let args = Args(CommandLine.arguments)
if args.flags.contains("help") || args.command == "help" {
    print(usage)
    exit(0)
}
if args.command == "version" {
    print("murmur \(Version.string)")
    exit(0)
}

// MARK: - Config

let configURL = args.options["config"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? Paths.configFile
var config: Config
var configNotes: [String] = []
do {
    switch try ConfigStore.load(from: configURL) {
    case .loaded(let c):
        config = c
    case .created(let c):
        config = c
        configNotes.append("created \(configURL.path) with defaults")
    }
} catch {
    // A broken config must not stop dictation: run on defaults and say so.
    config = Config()
    configNotes.append("could not read \(configURL.path) (\(error)); using defaults")
}
if let m = args.options["model"] { config.model = m }
if let l = args.options["language"] { config.language = l }
configNotes += config.sanitize()

let isService = args.command == "run"
let interactive = isatty(STDERR_FILENO) != 0
log.configure(url: isService ? Paths.logFile : nil,
              level: isService ? config.resolvedLogLevel : (args.options["log-level"].flatMap(Log.Level.init(name:)) ?? .warn),
              maxBytes: UInt64(config.logMaxBytes), keep: config.logKeep,
              echoToStderr: isService ? interactive : true)
for n in configNotes { log.warn("config", ["note": n]) }

func engineOptions() -> WhisperEngine.Options {
    var o = WhisperEngine.Options(modelURL: config.modelURL)
    o.language = config.language
    o.threads = config.effectiveThreads
    o.gpu = config.gpu
    o.prompt = config.prompt
    o.fastDecode = config.fastDecode
    return o
}

func loadWAVs(_ paths: [String]) -> [(String, WAV)] {
    if paths.isEmpty { die("no WAV files given") }
    return paths.map { p in
        do { return ((p as NSString).lastPathComponent, try WAV(contentsOf: URL(fileURLWithPath: p))) } catch {
            die("\(p): \(error)")
        }
    }
}

func startRunner(speed: Double) -> OfflineRunner {
    var settings = Pipeline.Settings()
    settings.maxRecordSeconds = config.maxRecordSeconds
    settings.queueDepth = config.queueDepth
    let r = OfflineRunner(engine: engineOptions(), settings: settings, speed: speed)
    guard r.start() else { die("model did not load: \(config.modelURL.path) (see log)", code: 1) }
    return r
}

func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}

// MARK: - Commands

switch args.command {
case "run":
    // One service per user. Run by hand while the service is up, refuse;
    // started by launchd while a hand-run copy holds the lock, wait for it.
    try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
    let lockFD = open(Paths.support.appendingPathComponent("murmur.lock").path, O_CREAT | O_RDWR, 0o600)
    if lockFD >= 0, flock(lockFD, LOCK_EX | (args.flags.contains("wait-for-lock") ? 0 : LOCK_NB)) != 0 {
        die("another murmur is already running (launchctl list | grep murmur)", code: 0)
    }
    exit(Daemon(config: config).run())

case "transcribe":
    let wavs = loadWAVs(args.files)
    let runner = startRunner(speed: .infinity)
    for (name, wav) in wavs {
        let r = runner.run(wav)
        if args.files.count > 1 { print("\(name): ", terminator: "") }
        print(r.text ?? "(\(r.report.map { "\($0.outcome)" } ?? "no result"))")
    }
    runner.shutdown()

case "bench":
    let wavs = loadWAVs(args.files)
    let runs = Int(args.options["runs"] ?? "5") ?? 5
    let runner = startRunner(speed: 1)
    var csv = "file,audio_s,run,latency_ms,inference_ms,chars\n"
    var all: [Double] = []
    print("file                 audio    p50 ms   min ms   max ms")
    for (name, wav) in wavs {
        var lat: [Double] = []
        for i in 0..<runs {
            let r = runner.run(wav)
            guard let rep = r.report, let l = rep.latency else { continue }
            lat.append(l * 1000)
            csv += "\(name),\(String(format: "%.2f", wav.duration)),\(i),\(Int(l * 1000)),\(Int((rep.inference ?? 0) * 1000)),\(r.text?.count ?? 0)\n"
        }
        all += lat
        print(String(format: "%-20@ %5.1fs %8.0f %8.0f %8.0f", name as NSString, wav.duration,
                     percentile(lat, 0.5), lat.min() ?? .nan, lat.max() ?? .nan))
    }
    print(String(format: "all: n=%d p50=%.0f p90=%.0f p99=%.0f max=%.0f ms", all.count,
                 percentile(all, 0.5), percentile(all, 0.9), percentile(all, 0.99), all.max() ?? .nan))
    if let path = args.options["csv"] { try? csv.write(toFile: path, atomically: true, encoding: .utf8) }
    runner.shutdown()

case "soak":
    let minutes = Double(args.options["minutes"] ?? "60") ?? 60
    let speed = Double(args.options["speed"] ?? "1") ?? 1
    let corpus = args.options["corpus"] ?? "bench/audio"
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: corpus)) ?? [])
        .filter { $0.hasSuffix(".wav") }.sorted().map { "\(corpus)/\($0)" }
    let wavs = loadWAVs(files)
    let runner = startRunner(speed: speed)
    let started = Date()
    var csv = "elapsed_s,dictations,failures,footprint_mb,rss_mb,threads,cpu_s\n"
    var dictations = 0, failures = 0
    var lat: [Double] = []
    var lastSample = Date.distantPast
    func sample() {
        let s = ProcessStats.current()
        csv += String(format: "%.0f,%d,%d,%.1f,%.1f,%d,%.1f\n", Date().timeIntervalSince(started), dictations, failures,
                      Double(s.footprint) / 1_048_576, Double(s.rss) / 1_048_576, s.threads, s.cpuSeconds)
        if let path = args.options["csv"] { try? csv.write(toFile: path, atomically: true, encoding: .utf8) }
        print(String(format: "[%5.0f s] dictations=%d failures=%d footprint=%.1f MB rss=%.1f MB threads=%d cpu=%.0f s",
                     Date().timeIntervalSince(started), dictations, failures, Double(s.footprint) / 1_048_576,
                     Double(s.rss) / 1_048_576, s.threads, s.cpuSeconds))
        fflush(stdout)
    }
    sample()
    var i = 0
    while Date().timeIntervalSince(started) < minutes * 60 {
        let (_, wav) = wavs[i % wavs.count]
        i += 1
        let r = runner.run(wav)
        dictations += 1
        switch r.report?.outcome {
        case .delivered?: if let l = r.report?.latency { lat.append(l * 1000) }
        case .failed?, nil: failures += 1
        default: break
        }
        if Date().timeIntervalSince(lastSample) >= 30 {
            sample()
            lastSample = Date()
        }
    }
    sample()
    print(String(format: "latency over soak: n=%d p50=%.0f p90=%.0f p99=%.0f max=%.0f ms", lat.count,
                 percentile(lat, 0.5), percentile(lat, 0.9), percentile(lat, 0.99), lat.max() ?? .nan))
    runner.shutdown()

case "mic-test":
    // The live path minus the hotkey and paste: default input device through
    // the AUHAL callback, ring, drain, resampler and model.
    let seconds = Double(args.options["seconds"] ?? "4") ?? 4
    guard Permissions.requestMicrophone() else { die("microphone access denied (System Settings > Privacy & Security > Microphone)", code: 1) }
    guard let mic = CoreAudioSource() else { die("could not allocate the audio ring", code: 1) }
    let out = RecordingOutput()
    var settings = Pipeline.Settings()
    settings.maxRecordSeconds = Int(seconds) + 2
    let p = Pipeline(source: mic, transcriber: WhisperEngine(engineOptions()), output: out,
                     chimes: SystemChimes(enabled: config.sounds), settings: settings)
    let done = DispatchSemaphore(value: 0)
    var report: Pipeline.Report?
    p.onReport = { report = $0; done.signal() }
    p.start()
    guard p.waitUntilReady(timeout: 300) else { die("model did not load: \(config.modelURL.path)", code: 1) }
    print("input: \(mic.sampleRate > 0 ? "default device" : "?"); speak for \(Int(seconds)) s...")
    p.press()
    Thread.sleep(forTimeInterval: seconds)
    p.release()
    _ = done.wait(timeout: .now() + 120)
    print("device rate: \(Int(mic.sampleRate)) Hz")
    if let r = report {
        print("outcome: \(r.outcome), audio \(String(format: "%.1f", r.audioSeconds)) s, latency \(r.latency.map { "\(Int($0 * 1000)) ms" } ?? "-")")
    }
    print("text: \(out.texts.last ?? "(none)")")
    p.shutdown()

case "check":
    print("murmur \(Version.string)")
    print("config        \(configURL.path)")
    print("model         \(config.modelURL.path) \(FileManager.default.fileExists(atPath: config.modelURL.path) ? "(present)" : "(MISSING)")")
    print("language      \(config.language)")
    print("accessibility \(Permissions.hasAccessibility ? "granted" : "NOT granted")")
    let mic: String
    switch Permissions.microphone {
    case .authorized: mic = "granted"
    case .denied: mic = "DENIED"
    case .restricted: mic = "restricted"
    default: mic = "not asked yet"
    }
    print("microphone    \(mic)")
    print("log           \(Paths.logFile.path)")
    for n in configNotes { print("note          \(n)") }

case "config":
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try enc.encode(config), as: UTF8.self))

default:
    die("unknown command \"\(args.command)\"\n\(usage)")
}
log.flush()
