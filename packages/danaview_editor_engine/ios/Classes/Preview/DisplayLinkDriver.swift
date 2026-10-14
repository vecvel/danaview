// OWNER: IOS-11
//
// DisplayLinkDriver (ARCH §12.7, §13.2 'Session'): a CADisplayLink on the main run loop at the
// project fps (`preferredFrameRateRange`), running only while the session plays (paused when
// idle). Each tick reports `targetTimestamp` (when the next frame reaches the screen); the session
// asks the video output for `itemTime(forHostTime: targetTimestamp + textureLatency)`, where the
// latency is the time Flutter takes to composite a texture after `textureFrameAvailable`.
//
// Texture latency (§12.7, IOS-01 V-N23): Flutter 3.44 Impeller adds exactly one vsync (16.67 ms
// p50 and p95 at 60 Hz). The driver starts from one display refresh interval; `measureLatency`
// replaces it with a measured value when a host supplies one (Flutter frame timings in
// CLOCK_MONOTONIC_RAW converted with `monotonicRawOffset`).

import Foundation
import QuartzCore
import UIKit

final class DisplayLinkDriver {
    /// One display-link callback (main thread).
    struct Tick {
        let timestamp: CFTimeInterval
        let targetTimestamp: CFTimeInterval
        let duration: CFTimeInterval
    }

    /// Runs on the main thread on every tick.
    var onTick: ((Tick) -> Void)?

    private let lock = NSLock()
    private var link: CADisplayLink?
    private var _fps: Int
    private var _latency: CFTimeInterval
    private var _ticks = 0

    init(fps: Int, textureLatency: CFTimeInterval? = nil) {
        _fps = max(1, fps)
        _latency = textureLatency ?? DisplayLinkDriver.oneRefreshInterval()
    }

    deinit {
        let l = link
        if let l {
            if Thread.isMainThread { l.invalidate() } else { DispatchQueue.main.async { l.invalidate() } }
        }
    }

    /// One refresh interval of the main screen (the measured Flutter texture latency, IOS-01).
    static func oneRefreshInterval() -> CFTimeInterval {
        let hz = Thread.isMainThread ? UIScreen.main.maximumFramesPerSecond : 60
        return 1.0 / Double(max(30, hz))
    }

    /// `clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) − CACurrentMediaTime()` in seconds (converts
    /// Flutter `FrameTiming` stamps to display-link time).
    static func monotonicRawOffset() -> CFTimeInterval {
        let raw = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9
        return raw - CACurrentMediaTime()
    }

    /// The project fps the link is paced at.
    var fps: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _fps
        }
        set {
            lock.lock()
            _fps = max(1, newValue)
            let l = link
            lock.unlock()
            if let l { DispatchQueue.main.async { DisplayLinkDriver.configure(l, fps: newValue) } }
        }
    }

    /// Seconds between `textureFrameAvailable` and the frame on screen.
    var textureLatency: CFTimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return _latency
    }

    /// Replaces the latency with a measured value (ignored outside 0…100 ms).
    func measureLatency(_ seconds: CFTimeInterval) {
        guard seconds.isFinite, seconds >= 0, seconds <= 0.1 else { return }
        lock.lock()
        _latency = seconds
        lock.unlock()
    }

    /// Whether the link is running.
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return link != nil
    }

    /// Ticks delivered since creation (tests).
    var tickCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _ticks
    }

    /// Starts the link (any thread; the link runs on main).
    func start() {
        let work = {
            self.lock.lock()
            if self.link != nil {
                self.lock.unlock()
                return
            }
            let l = CADisplayLink(target: Proxy(self), selector: #selector(Proxy.tick(_:)))
            self.link = l
            let fps = self._fps
            self.lock.unlock()
            DisplayLinkDriver.configure(l, fps: fps)
            l.add(to: .main, forMode: .common)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Stops the link (any thread). Idempotent.
    func stop() {
        lock.lock()
        let l = link
        link = nil
        lock.unlock()
        guard let l else { return }
        if Thread.isMainThread { l.invalidate() } else { DispatchQueue.main.async { l.invalidate() } }
    }

    private static func configure(_ l: CADisplayLink, fps: Int) {
        let f = Float(fps)
        l.preferredFrameRateRange = CAFrameRateRange(minimum: min(f, 30), maximum: max(f, 30), preferred: f)
    }

    fileprivate func fire(_ l: CADisplayLink) {
        lock.lock()
        guard link === l else {
            lock.unlock()
            return
        }
        _ticks += 1
        let handler = onTick
        lock.unlock()
        handler?(Tick(timestamp: l.timestamp, targetTimestamp: l.targetTimestamp, duration: l.duration))
    }

    /// Weak target: CADisplayLink retains its target.
    private final class Proxy: NSObject {
        weak var owner: DisplayLinkDriver?

        init(_ owner: DisplayLinkDriver) {
            self.owner = owner
        }

        @objc func tick(_ link: CADisplayLink) {
            guard let owner else {
                link.invalidate()
                return
            }
            owner.fire(link)
        }
    }
}
