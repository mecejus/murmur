import Foundation

/// Settings from ~/.config/murmur/config.json. Every field is optional in the
/// file; anything missing takes the default below.
public struct Config: Codable, Equatable, Sendable {
    /// Path to a ggml Whisper model. Relative paths resolve against the
    /// models folder (~/Library/Application Support/murmur/models).
    public var model: String = Config.defaultModelFile

    /// ISO-639-1 language hint such as "en", or "auto" to detect it.
    public var language: String = "auto"

    /// CPU threads for decoding. 0 picks the performance-core count.
    public var threads: Int = 0

    /// Use the GPU (Metal). Off falls back to CPU + Accelerate.
    public var gpu: Bool = true

    /// Optional text that primes the decoder with vocabulary or style, for
    /// example names it should spell a particular way.
    public var prompt: String = ""

    /// Encode a shortened audio window for short clips: much faster, less
    /// accurate. See WhisperEngine.Options.fastDecode.
    public var fastDecode: Bool = false

    /// A single dictation is capped at this many seconds; holding the key
    /// longer ends the recording there.
    public var maxRecordSeconds: Int = 300

    /// Finished recordings that may wait for transcription while another is
    /// being transcribed. A key press when that many are already waiting is
    /// refused with the error sound rather than queued without bound.
    public var queueDepth: Int = 2

    /// Play the start/stop chimes.
    public var sounds: Bool = true

    /// "debug", "info", "warn" or "error".
    public var logLevel: String = "info"

    /// Log file size limit before rotation, and how many rotated files to keep.
    public var logMaxBytes: Int = 1 << 20
    public var logKeep: Int = 3

    enum CodingKeys: String, CodingKey {
        case model, language, threads, gpu, prompt, sounds
        case fastDecode = "fast_decode"
        case maxRecordSeconds = "max_record_seconds"
        case queueDepth = "queue_depth"
        case logLevel = "log_level"
        case logMaxBytes = "log_max_bytes"
        case logKeep = "log_keep"
    }

    public static let defaultModelFile = "ggml-large-v3-turbo-q5_0.bin"

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? d.threads
        gpu = try c.decodeIfPresent(Bool.self, forKey: .gpu) ?? d.gpu
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? d.prompt
        fastDecode = try c.decodeIfPresent(Bool.self, forKey: .fastDecode) ?? d.fastDecode
        maxRecordSeconds = try c.decodeIfPresent(Int.self, forKey: .maxRecordSeconds) ?? d.maxRecordSeconds
        queueDepth = try c.decodeIfPresent(Int.self, forKey: .queueDepth) ?? d.queueDepth
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? d.sounds
        logLevel = try c.decodeIfPresent(String.self, forKey: .logLevel) ?? d.logLevel
        logMaxBytes = try c.decodeIfPresent(Int.self, forKey: .logMaxBytes) ?? d.logMaxBytes
        logKeep = try c.decodeIfPresent(Int.self, forKey: .logKeep) ?? d.logKeep
    }

    /// Clamps values that would break an invariant (an unbounded queue, a
    /// zero-length recording) and reports what was changed.
    public mutating func sanitize() -> [String] {
        var notes: [String] = []
        func clamp(_ v: inout Int, _ lo: Int, _ hi: Int, _ name: String) {
            let c = min(max(v, lo), hi)
            if c != v { notes.append("\(name) \(v) out of range, using \(c)"); v = c }
        }
        clamp(&maxRecordSeconds, 1, 600, "max_record_seconds")
        clamp(&queueDepth, 0, 8, "queue_depth")
        clamp(&threads, 0, 32, "threads")
        clamp(&logMaxBytes, 64 << 10, 64 << 20, "log_max_bytes")
        clamp(&logKeep, 1, 10, "log_keep")
        language = language.trimmingCharacters(in: .whitespaces).lowercased()
        if language.isEmpty { language = "auto" }
        if Log.Level(name: logLevel) == nil {
            notes.append("log_level \"\(logLevel)\" unknown, using info")
            logLevel = "info"
        }
        return notes
    }

    public var resolvedLogLevel: Log.Level { Log.Level(name: logLevel) ?? .info }

    public var modelURL: URL {
        let expanded = (model as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return Paths.models.appendingPathComponent(expanded)
    }

    public var effectiveThreads: Int {
        if threads > 0 { return threads }
        var perf: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &perf, &size, nil, 0) == 0, perf > 0 {
            return Int(perf)
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }
}

public enum Paths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var configDir: URL { home.appendingPathComponent(".config/murmur") }
    public static var configFile: URL { configDir.appendingPathComponent("config.json") }
    public static var accessPromptMarker: URL { configDir.appendingPathComponent("access-prompted") }
    public static var support: URL { home.appendingPathComponent("Library/Application Support/murmur") }
    public static var models: URL { support.appendingPathComponent("models") }
    public static var logDir: URL { home.appendingPathComponent("Library/Logs/murmur") }
    public static var logFile: URL { logDir.appendingPathComponent("murmur.log") }
}

public enum ConfigStore {
    public enum LoadResult {
        case loaded(Config)
        case created(Config)
    }

    /// Loads the config, writing one with the defaults on first run so the
    /// available settings are visible and editable.
    public static func load(from url: URL = Paths.configFile) throws -> LoadResult {
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            return .loaded(try JSONDecoder().decode(Config.self, from: data))
        }
        let cfg = Config()
        try save(cfg, to: url)
        return .created(cfg)
    }

    public static func save(_ cfg: Config, to url: URL = Paths.configFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(cfg).write(to: url, options: .atomic)
    }
}
