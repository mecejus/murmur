import AVFoundation
import Foundation

public enum Chime: Sendable {
    case start, stop, error
}

public protocol ChimePlayer: AnyObject {
    func play(_ chime: Chime)
}

/// Blow on press, Bottle on release, Basso when a dictation could not be
/// taken or failed.
///
/// Played as ordinary audio at the output volume, not as system sounds:
/// macOS silences system sounds when "Play user interface sound effects" is
/// off, which made the chimes inaudible on Macs with that setting. Each clip
/// is decoded and prepared once; playback is handed to a private queue so a
/// caller never waits on the audio system, and nothing plays (or keeps an
/// output stream open) between dictations.
public final class SystemChimes: ChimePlayer {
    private var players: [Chime: AVAudioPlayer] = [:]
    private let queue = DispatchQueue(label: "murmur.chimes", qos: .userInteractive)

    public init(enabled: Bool) {
        guard enabled else { return }
        let files: [Chime: String] = [
            .start: "/System/Library/Sounds/Blow.aiff",
            .stop: "/System/Library/Sounds/Bottle.aiff",
            .error: "/System/Library/Sounds/Basso.aiff",
        ]
        for (chime, path) in files {
            do {
                let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
                p.prepareToPlay()
                players[chime] = p
            } catch {
                log.warn("chime_load_failed", ["path": path, "error": error])
            }
        }
    }

    public func play(_ chime: Chime) {
        guard let p = players[chime] else { return }
        queue.async {
            p.stop()
            p.currentTime = 0
            p.play()
        }
    }
}

public final class SilentChimes: ChimePlayer, @unchecked Sendable {
    private let lock = NSLockLite()
    private var log: [Chime] = []
    public init() {}
    public func play(_ chime: Chime) { lock.locked { log.append(chime) } }
    public var played: [Chime] { lock.locked { log } }
}
