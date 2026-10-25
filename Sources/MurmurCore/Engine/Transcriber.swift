import Foundation

public enum TranscribeError: Error, CustomStringConvertible, Equatable {
    case notLoaded
    case modelMissing(String)
    case loadFailed(String)
    case inferenceFailed(Int32)
    case timedOut(Double)

    public var description: String {
        switch self {
        case .notLoaded: return "model not loaded"
        case .modelMissing(let p): return "model file not found: \(p)"
        case .loadFailed(let p): return "could not load model: \(p)"
        case .inferenceFailed(let rc): return "inference failed (code \(rc))"
        case .timedOut(let s): return "inference exceeded \(Int(s)) s and was aborted"
        }
    }
}

/// Speech-to-text. One call at a time; the pipeline's single worker thread
/// owns the instance.
public protocol Transcriber: AnyObject {
    var isLoaded: Bool { get }
    /// Loads the model. Called once at startup, and again only to recover
    /// from repeated inference failures.
    func load() throws
    func unload()
    /// `samples` are 16 kHz mono. `timeout` bounds the call; past it the
    /// call is aborted and throws `.timedOut`.
    func transcribe(_ samples: UnsafeBufferPointer<Float>, timeout: TimeInterval) throws -> String
}
