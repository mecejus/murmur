import CWhisper
import Foundation

/// whisper.cpp, loaded once and kept resident.
///
/// The context (weights, Metal pipelines, KV cache and compute buffers) is
/// created in `load` and reused for every dictation, so steady-state
/// transcription allocates nothing new in the model and memory stays flat.
public final class WhisperEngine: Transcriber {
    public struct Options {
        public var modelURL: URL
        public var language: String = "auto"
        public var threads: Int = 4
        public var gpu: Bool = true
        public var prompt: String = ""
        /// Encode only as much audio context as the clip needs (plus
        /// `contextPad` frames of 20 ms, at least `minContext`) instead of
        /// Whisper's fixed 30 s window. Several times faster on short
        /// dictations, but large-v3-turbo loses accuracy with a shortened
        /// window (see TESTING.md), so it is off by default. Output that
        /// looks like a decoder loop is re-decoded with the full window.
        public var fastDecode: Bool = false
        public var contextPad: Int = 384
        public var minContext: Int = 384

        public init(modelURL: URL) { self.modelURL = modelURL }
    }

    public let options: Options
    private var ctx: OpaquePointer?
    // C strings handed to whisper_full must outlive the call; kept for the
    // engine's lifetime instead of re-created per dictation.
    private let languageC: UnsafeMutablePointer<CChar>
    private let promptC: UnsafeMutablePointer<CChar>?
    private let abort = AbortFlag()

    public init(_ options: Options) {
        self.options = options
        languageC = strdup(options.language.isEmpty ? "auto" : options.language)!
        promptC = options.prompt.isEmpty ? nil : strdup(options.prompt)
        WhisperEngine.installLogHook()
    }

    deinit {
        unload()
        free(languageC)
        free(promptC)
    }

    public var isLoaded: Bool { ctx != nil }

    /// What the last `transcribe` call did, for logs and benchmarks.
    public struct Stats {
        public var audioContext = 0      // frames encoded; 0 means the full window
        public var fellBack = false      // fast decode was redone with the full window
    }
    public private(set) var lastStats = Stats()

    public func load() throws {
        unload()
        let path = options.modelURL.path
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw TranscribeError.modelMissing(path)
        }
        var cp = whisper_context_default_params()
        cp.use_gpu = options.gpu
        cp.flash_attn = options.gpu
        let started = Date()
        guard let c = whisper_init_from_file_with_params(path, cp) else {
            throw TranscribeError.loadFailed(path)
        }
        ctx = c
        log.info("model_loaded", [
            "model": options.modelURL.lastPathComponent,
            "gpu": options.gpu,
            "ms": Int(Date().timeIntervalSince(started) * 1000),
        ])
    }

    public func unload() {
        if let c = ctx {
            whisper_free(c)
            ctx = nil
        }
    }

    public func transcribe(_ samples: UnsafeBufferPointer<Float>, timeout: TimeInterval) throws -> String {
        guard let ctx else { throw TranscribeError.notLoaded }
        guard samples.baseAddress != nil, !samples.isEmpty else { return "" }

        abort.deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1e9)
        abort.fired = false
        lastStats = Stats()

        let seconds = Double(samples.count) / 16_000
        let full = Int(whisper_model_n_audio_ctx(ctx))
        if options.fastDecode, seconds < 29 {
            let needed = Int((seconds / 30 * Double(full)).rounded(.up)) + options.contextPad
            let audioCtx = max(options.minContext, needed)
            if audioCtx < full {
                lastStats.audioContext = audioCtx
                let text = try run(ctx, samples, audioCtx: audioCtx, timeout: timeout)
                if !Self.looksDegenerate(text, seconds: seconds) { return text }
                lastStats.fellBack = true
                log.info("fast_decode_fallback", ["seconds": seconds, "audio_ctx": audioCtx])
            }
        }
        lastStats.audioContext = 0
        return try run(ctx, samples, audioCtx: 0, timeout: timeout)
    }

    private func run(_ ctx: OpaquePointer, _ samples: UnsafeBufferPointer<Float>, audioCtx: Int, timeout: TimeInterval) throws -> String {
        var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        p.n_threads = Int32(options.threads)
        p.language = UnsafePointer(languageC)
        p.detect_language = false
        p.translate = false
        // Each dictation stands alone. Carrying the previous text over as a
        // prompt makes one misheard phrase leak into the next dictation.
        p.no_context = true
        p.no_timestamps = true
        p.single_segment = false
        p.print_progress = false
        p.print_realtime = false
        p.print_special = false
        p.print_timestamps = false
        p.suppress_blank = true
        p.suppress_nst = true
        p.audio_ctx = Int32(audioCtx)
        if let promptC { p.initial_prompt = UnsafePointer(promptC) }
        p.abort_callback = { data in
            guard let data else { return false }
            let a = Unmanaged<AbortFlag>.fromOpaque(data).takeUnretainedValue()
            if DispatchTime.now().uptimeNanoseconds > a.deadline {
                a.fired = true
                return true
            }
            return false
        }
        p.abort_callback_user_data = Unmanaged.passUnretained(abort).toOpaque()

        let rc = whisper_full(ctx, p, samples.baseAddress, Int32(samples.count))
        if abort.fired { throw TranscribeError.timedOut(timeout) }
        if rc != 0 { throw TranscribeError.inferenceFailed(rc) }

        var text = ""
        let n = whisper_full_n_segments(ctx)
        for i in 0..<n {
            if let s = whisper_full_get_segment_text(ctx, i) { text += String(cString: s) }
        }
        return Self.clean(text)
    }

    /// The failure mode of a shortened audio context is a decoder loop: the
    /// same phrase over and over, or far more words than the audio can hold.
    /// Normal speech is under 4 words a second.
    static func looksDegenerate(_ text: String, seconds: Double) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if Double(words.count) > seconds * 6 + 8 { return true }
        // Any run of 4+ words that occurs three times.
        let n = 4
        guard words.count >= n * 3 else { return false }
        var seen: [String: Int] = [:]
        for i in 0...(words.count - n) {
            let key = words[i..<i + n].joined(separator: " ")
            seen[key, default: 0] += 1
            if seen[key]! >= 3 { return true }
        }
        return false
    }

    /// Strips what Whisper emits for non-speech: bracketed or parenthesized
    /// annotations such as "[BLANK_AUDIO]" or "(music)", and whitespace.
    static func clean(_ text: String) -> String {
        var t = text
        for (open, close) in [("[", "]"), ("(", ")"), ("*", "*")] {
            while let r = t.range(of: open), let e = t.range(of: close, range: r.upperBound..<t.endIndex) {
                let inner = t[r.upperBound..<e.lowerBound]
                // Only drop short annotations, not parenthetical speech.
                guard inner.count <= 24, inner.split(separator: " ").count <= 3 else { break }
                t.removeSubrange(r.lowerBound..<e.upperBound)
            }
        }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let logHookOnce: Void = {
        // Route whisper/ggml diagnostics into our log; drop their info chatter.
        let hook: @convention(c) (ggml_log_level, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { level, text, _ in
            guard let text else { return }
            let msg = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !msg.isEmpty else { return }
            switch level {
            case GGML_LOG_LEVEL_ERROR: log.error("whisper", ["msg": msg])
            case GGML_LOG_LEVEL_WARN: log.warn("whisper", ["msg": msg])
            default: log.debug("whisper", ["msg": msg])
            }
        }
        whisper_log_set(hook, nil)
    }()

    static func installLogHook() { _ = logHookOnce }
}

private final class AbortFlag {
    var deadline: UInt64 = 0
    var fired = false
}
