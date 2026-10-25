import Foundation

/// Structured, size-bounded logging.
///
/// Each record is one JSON object per line. Records are formatted on the
/// caller's thread and written on a private serial queue, so logging never
/// blocks dictation on disk I/O. Two things keep it bounded:
///   - the file rotates at `maxBytes`, keeping `keep` old files
///     (murmur.log, murmur.log.1 ... murmur.log.<keep>);
///   - at most `maxPending` records may wait for the writer. Past that, new
///     records are counted and dropped, and the count is logged once the
///     writer catches up.
///
/// Dictated text is never logged.
public final class Log: @unchecked Sendable {
    public enum Level: Int, Comparable, Codable, Sendable {
        case debug = 0, info, warn, error

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var name: String {
            switch self {
            case .debug: return "debug"
            case .info: return "info"
            case .warn: return "warn"
            case .error: return "error"
            }
        }

        public init?(name: String) {
            switch name.lowercased() {
            case "debug": self = .debug
            case "info": self = .info
            case "warn", "warning": self = .warn
            case "error": self = .error
            default: return nil
            }
        }
    }

    public static let shared = Log()

    private let queue = DispatchQueue(label: "murmur.log", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private var droppedRecords = 0

    // Configured by `configure`; read under `lock` on the caller side, and
    // only on `queue` for the file state.
    private var minLevel: Level = .info
    private var echoToStderr = true
    private var url: URL?
    private var handle: FileHandle?
    private var size: UInt64 = 0
    private var maxBytes: UInt64 = 1 << 20
    private var keep = 3
    private let maxPending = 2048

    private static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init() {}

    /// Starts writing to `url`. Passing nil logs to stderr only.
    public func configure(url: URL?, level: Level, maxBytes: UInt64 = 1 << 20, keep: Int = 3, echoToStderr: Bool) {
        lock.lock()
        minLevel = level
        self.echoToStderr = echoToStderr
        lock.unlock()
        queue.sync {
            self.handle?.closeFile()
            self.handle = nil
            self.url = url
            self.maxBytes = max(maxBytes, 4096)
            self.keep = max(keep, 1)
            if let url { self.open(url) }
        }
    }

    public func debug(_ event: String, _ fields: [String: Any] = [:]) { write(.debug, event, fields) }
    public func info(_ event: String, _ fields: [String: Any] = [:]) { write(.info, event, fields) }
    public func warn(_ event: String, _ fields: [String: Any] = [:]) { write(.warn, event, fields) }
    public func error(_ event: String, _ fields: [String: Any] = [:]) { write(.error, event, fields) }

    public func write(_ level: Level, _ event: String, _ fields: [String: Any]) {
        lock.lock()
        guard level >= minLevel else {
            lock.unlock()
            return
        }
        if pending >= maxPending {
            droppedRecords += 1
            lock.unlock()
            return
        }
        pending += 1
        let echo = echoToStderr
        lock.unlock()

        var record: [String: Any] = ["ts": Log.timestamp.string(from: Date()), "level": level.name, "event": event]
        for (k, v) in fields { record[k] = Log.jsonSafe(v) }
        let line: Data
        if let d = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) {
            line = d + Data([0x0A])
        } else {
            line = Data("{\"event\":\"\(event)\",\"level\":\"\(level.name)\",\"note\":\"unserializable fields\"}\n".utf8)
        }

        queue.async {
            if echo { FileHandle.standardError.write(line) }
            self.append(line)
            self.lock.lock()
            self.pending -= 1
            let dropped = self.droppedRecords
            self.droppedRecords = 0
            self.lock.unlock()
            if dropped > 0 {
                self.append(Data("{\"event\":\"log_records_dropped\",\"count\":\(dropped),\"level\":\"warn\"}\n".utf8))
            }
        }
    }

    /// Blocks until every record logged so far is on disk.
    public func flush() {
        queue.sync { try? self.handle?.synchronize() }
    }

    // MARK: - File handling (on `queue`)

    private func open(_ url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: url)
        size = (try? handle?.seekToEnd()) ?? 0
        if size >= maxBytes { rotate() }
    }

    private func append(_ line: Data) {
        guard let handle else { return }
        do {
            try handle.write(contentsOf: line)
            size += UInt64(line.count)
        } catch {
            // Disk full or file gone: try to reopen once, then give up on
            // this record. Logging must never take the process down.
            if let url { open(url) }
            return
        }
        if size >= maxBytes { rotate() }
    }

    private func rotate() {
        guard let url else { return }
        handle?.closeFile()
        handle = nil
        let fm = FileManager.default
        let path = url.path
        try? fm.removeItem(atPath: "\(path).\(keep)")
        if keep > 1 {
            for i in stride(from: keep - 1, through: 1, by: -1) {
                try? fm.moveItem(atPath: "\(path).\(i)", toPath: "\(path).\(i + 1)")
            }
        }
        try? fm.moveItem(atPath: path, toPath: "\(path).1")
        fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        handle = try? FileHandle(forWritingTo: url)
        size = 0
    }

    private static func jsonSafe(_ v: Any) -> Any {
        switch v {
        case let d as Double:
            // NSDecimalNumber serializes as written ("0.051"), where a
            // rounded Double would still print as 0.050999999999999997.
            return d.isFinite ? NSDecimalNumber(string: String(format: "%.3f", d)) : String(describing: d)
        case let f as Float:
            return jsonSafe(Double(f))
        case is Int, is Int32, is Int64, is UInt32, is UInt64, is Bool, is String:
            return v
        case let e as Error:
            return String(describing: e)
        default:
            return String(describing: v)
        }
    }
}

public let log = Log.shared
