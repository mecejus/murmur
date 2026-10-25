import AVFoundation
import CoreAudio
import CRealtime
import Foundation

/// Microphone input through an AUHAL unit (CRealtime/capture.c).
///
/// The unit is bound to one device. It is built lazily on the first `start`,
/// kept for later dictations, and thrown away when the default input
/// changes, the device dies, the machine sleeps, or a call fails, so the next
/// `start` binds to whatever device is current then. An input kept for the
/// life of the process goes deaf after headphones are unplugged or the Mac
/// wakes from sleep.
///
/// Every CoreAudio control call runs on `control` behind a timeout, so a HAL
/// that hangs (seen on Bluetooth disconnects) stalls only this object, never
/// the caller. A unit whose call timed out is abandoned, not reused.
public final class CoreAudioSource: AudioSource, @unchecked Sendable {
    public let ring: SampleRing
    public var onEvent: ((AudioSourceEvent) -> Void)?

    private let control = DispatchQueue(label: "murmur.audio.control", qos: .userInteractive)
    private let events = DispatchQueue(label: "murmur.audio.events", qos: .userInitiated)
    // Touched only on `control`.
    private var capture: OpaquePointer?
    private var running = false
    private var staleWhileRunning = false
    private var watchdog: DispatchSourceTimer?
    private var lastCallbacks: UInt64 = 0
    private var hangs = 0

    // Read from other threads, so never behind `control` (which may be
    // stuck inside CoreAudio): guarded by `lock`.
    private let lock = NSLockLite()
    private var rate: Double = 48_000
    /// Mirror of `capture` for `onControl`'s timeout path, which must disarm
    /// the unit without going through the (stuck) control queue.
    private var armedCapture: OpaquePointer?
    private var renderErrors = 0
    private var oversized: UInt64 = 0

    private let opTimeout: TimeInterval
    private var listening = false

    public init?(ringSeconds: Double = 4, opTimeout: TimeInterval = 2) {
        // Sized for the highest common device rate, so a stalled consumer
        // has seconds of slack before anything is dropped.
        guard let r = SampleRing(capacity: Int(96_000 * ringSeconds)) else { return nil }
        ring = r
        self.opTimeout = opTimeout
    }

    deinit {
        if let c = capture { mm_capture_destroy(c) }
    }

    public var sampleRate: Double { lock.locked { rate } }

    public func start() throws {
        if !listening { installListeners() }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted: throw AudioSourceError.permissionDenied
        default: break
        }
        try onControl("start") {
            if self.capture == nil { try self.build() }
            guard let c = self.capture else { throw AudioSourceError.noInputDevice }
            self.ring.clear()
            let st = mm_capture_start(c)
            if st != noErr {
                // A stale unit (device gone since it was built) fails here.
                // Rebuild once against the current default and retry.
                self.teardown()
                try self.build()
                guard let c2 = self.capture else { throw AudioSourceError.noInputDevice }
                let st2 = mm_capture_start(c2)
                if st2 != noErr {
                    self.teardown()
                    throw AudioSourceError.startFailed(st2)
                }
            }
            self.running = true
            self.armWatchdog()
        }
    }

    public func stop() {
        do {
            try onControl("stop") {
                self.disarmWatchdog()
                self.running = false
                if let c = self.capture {
                    let st = mm_capture_stop(c)
                    self.collectHealth(c)
                    if st != noErr {
                        log.warn("audio_stop_failed", ["status": Int(st)])
                        self.teardown()
                    } else if self.staleWhileRunning {
                        // The default input changed mid-recording.
                        self.teardown()
                    }
                }
                self.staleWhileRunning = false
            }
        } catch {
            log.error("audio_stop", ["error": error])
        }
    }

    public func invalidate() {
        try? onControl("invalidate") {
            self.disarmWatchdog()
            self.running = false
            self.teardown()
        }
    }

    public func takeHealth() -> AudioSourceHealth {
        var h = AudioSourceHealth()
        h.droppedSamples = ring.takeDropped()
        lock.locked {
            h.renderErrors = renderErrors
            h.oversizedCallbacks = oversized
            renderErrors = 0
            oversized = 0
        }
        return h
    }

    // MARK: - On `control`

    private func collectHealth(_ c: OpaquePointer) {
        let err = mm_capture_take_render_error(c)
        let over = mm_capture_take_oversized(c)
        lock.locked {
            if err != noErr { renderErrors += 1 }
            oversized += over
        }
    }

    private func build() throws {
        let device = mm_default_input_device()
        guard device != 0 else { throw AudioSourceError.noInputDevice }
        var st: OSStatus = noErr
        guard let c = mm_capture_create(device, ring.raw, &st) else {
            throw AudioSourceError.setupFailed(st)
        }
        capture = c
        let r = mm_capture_sample_rate(c)
        lock.locked {
            rate = r
            armedCapture = c
        }
        lastCallbacks = mm_capture_callbacks(c)
        log.info("audio_input_ready", ["device": Int(device), "name": Self.deviceName(device), "rate": r])
    }

    private func teardown() {
        if let c = capture {
            lock.locked { armedCapture = nil }
            mm_capture_destroy(c)
            capture = nil
        }
    }

    /// While recording, a unit whose IO callback count stops moving has lost
    /// its device without telling anyone. Report it so the recording ends
    /// and the next one rebuilds.
    private func armWatchdog() {
        disarmWatchdog()
        guard let c = capture else { return }
        lastCallbacks = mm_capture_callbacks(c)
        let t = DispatchSource.makeTimerSource(queue: control)
        t.schedule(deadline: .now() + 0.75, repeating: 0.75)
        t.setEventHandler { [weak self] in
            guard let self, self.running, let c = self.capture else { return }
            let n = mm_capture_callbacks(c)
            if n == self.lastCallbacks {
                log.warn("audio_input_stalled", ["device": Int(mm_capture_device(c))])
                self.running = false
                self.disarmWatchdog()
                self.teardown()
                self.emit(.deviceLost("input stopped delivering audio"))
            }
            self.lastCallbacks = n
        }
        watchdog = t
        t.resume()
    }

    private func disarmWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    // MARK: - Timeouts

    /// Runs `body` on the control queue and waits at most `opTimeout`. On a
    /// timeout the unit is disarmed at once (it can no longer write into the
    /// ring), and stopped and freed as soon as the stuck call returns. A
    /// repeat offender is reported as unrecoverable.
    private func onControl(_ name: String, _ body: @escaping () throws -> Void) throws {
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        control.async {
            do { try body() } catch { failure = error }
            done.signal()
        }
        if done.wait(timeout: .now() + opTimeout) == .timedOut {
            hangs += 1
            log.error("audio_call_hung", ["op": name, "hangs": hangs])
            lock.locked { if let c = armedCapture { mm_capture_disarm(c) } }
            // Queued behind the stuck call, so it runs once that returns,
            // when touching the unit is safe again.
            control.async { [weak self] in
                guard let self else { return }
                self.disarmWatchdog()
                self.running = false
                if let c = self.capture { mm_capture_stop(c) }
                self.teardown()
                log.info("audio_hung_unit_released", ["op": name])
            }
            if hangs >= 3 { emit(.unrecoverable("audio \(name) hung \(hangs) times")) }
            throw AudioSourceError.timedOut(name)
        }
        hangs = 0
        if let failure { throw failure }
    }

    private func emit(_ e: AudioSourceEvent) {
        events.async { [weak self] in self?.onEvent?(e) }
    }

    // MARK: - Device notifications

    private func installListeners() {
        listening = true
        var defaultInput = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInput, events) { [weak self] _, _ in
            guard let self else { return }
            log.info("audio_default_input_changed")
            self.control.async {
                // Leave a running unit alone; the recording in progress ends
                // through the watchdog or the next stop, and the unit is
                // rebuilt before the next start.
                if !self.running { self.teardown() } else { self.staleWhileRunning = true }
            }
            self.onEvent?(.deviceChanged)
        }
        var devices = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, events) { [weak self] _, _ in
            guard let self else { return }
            self.control.async {
                guard let c = self.capture else { return }
                let dev = mm_capture_device(c)
                if mm_device_is_alive(dev) == 0 {
                    log.warn("audio_device_gone", ["device": Int(dev)])
                    let wasRunning = self.running
                    self.running = false
                    self.disarmWatchdog()
                    self.teardown()
                    if wasRunning { self.emit(.deviceLost("input device disconnected")) }
                }
            }
        }
    }

    static func deviceName(_ id: UInt32) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name else { return "?" }
        return n.takeRetainedValue() as String
    }
}
