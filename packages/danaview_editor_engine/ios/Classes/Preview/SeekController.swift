// OWNER: IOS-11
//
// SeekController (ARCH §12.2 seek semantics, §13.2 'Session', D-35, IOS-01 V-N10): exact and scrub
// seeks of one preview session. Every method runs on `previewControlQueue`.
//
// Exact seek to output frame k:
//   `player.seek(to: CMTime(k, fps), toleranceBefore: .zero, toleranceAfter: .zero)`, then the video
//   output is queried **with the seek target** CMTime(k, fps) (not `currentTime()`) until a buffer
//   whose `danaview.frame` stamp == k arrives; it is pushed to the texture and the seek acks k. A
//   frame k that someone else already pushed after the seek started (the display link while
//   playing) acks too; when the frame on screen and the compositor's last request both are k and
//   no new buffer is expected (a seek to the frame already shown), it acks at once. After 500 ms
//   it acks the frame actually on screen (D-35: the ack never lies about the displayed frame).
//   A newer exact seek supersedes an older one, which acks the frame on screen.
// Scrub:
//   one seek in flight, latest wins: scrubs requested meanwhile collapse into one pending scrub
//   whose completions all receive its ack. Fast drags (> 2× real time between consecutive
//   scrubs) seek with ±0.5 s tolerance (any frame within the GOP), slow ones exactly; the ack
//   reports the displayed frame either way. An exact seek drops the pending scrub, whose callers
//   get the exact seek's ack.

import AVFoundation
import Foundation
import QuartzCore

final class SeekController {
    /// The outcome of one seek.
    struct Outcome: Equatable {
        /// The frame on screen when the seek completed.
        let frame: Int64
        /// True when the frame is the one requested (exact seeks) or a fresh scrub frame.
        let reached: Bool
        let ms: Double
    }

    typealias Completion = (Outcome) -> Void

    enum Kind { case exact, scrub }

    private final class Request {
        let kind: Kind
        let k: Int64
        var completions: [Completion]
        let start: CFTimeInterval
        let startSerial: UInt64
        let requireNew: Bool
        var timeoutMs: Double?
        var seekDone = false

        init(kind: Kind, k: Int64, completions: [Completion], startSerial: UInt64, requireNew: Bool) {
            self.kind = kind
            self.k = k
            self.completions = completions
            self.start = CACurrentMediaTime()
            self.startSerial = startSerial
            self.requireNew = requireNew
        }
    }

    private let queue: DispatchQueue
    private let bridge: TextureBridge
    /// The session's player (nil before the first plan).
    var player: AVPlayer?
    /// Output frame rate.
    var fps: Int64
    /// The frame of the compositor's last request (redraw cache), nil before the first.
    var lastComposedFrame: () -> Int64? = { nil }
    /// Ack timeout of exact seeks (ms).
    var timeoutMs: Double = 500
    /// How long a scrub waits for its frame after the seek completed (ms).
    var scrubSettleMs: Double = 150
    /// Frames per second of drag speed above which scrubs seek with tolerance (× fps).
    var fastScrubFactor: Double = 2
    /// Tolerance of fast scrubs.
    var scrubTolerance = CMTime(value: 1, timescale: 2)

    private var active: Request?
    private var pendingScrub: (k: Int64, completions: [Completion])?
    private var lastScrub: (k: Int64, t: CFTimeInterval)?
    /// Seeks issued (tests: coalescing).
    private(set) var issuedSeeks = 0
    private(set) var issuedScrubs = 0

    init(queue: DispatchQueue, bridge: TextureBridge, fps: Int64) {
        self.queue = queue
        self.bridge = bridge
        self.fps = fps
    }

    /// Whether a seek is in flight.
    var isBusy: Bool { active != nil || pendingScrub != nil }

    // MARK: Exact

    /// Seeks exactly to output frame [k]; [requireNew] ignores the frame already on screen (after
    /// a rebuild or quality change the same k must be composed again). [timeoutMs] overrides the
    /// ack timeout (a new player item pays decoder start-up first).
    func exact(_ k: Int64, requireNew: Bool = false, timeoutMs: Double? = nil, completion: @escaping Completion) {
        var completions = [completion]
        if let pending = pendingScrub {
            completions += pending.completions
            pendingScrub = nil
        }
        if let old = active {
            active = nil
            finish(old, frame: displayedFrame(fallback: old.k), reached: false)
        }
        let request = Request(kind: .exact, k: k, completions: completions, startSerial: bridge.currentSerial, requireNew: requireNew)
        request.timeoutMs = timeoutMs
        active = request
        guard let player else {
            finish(request, frame: displayedFrame(fallback: k), reached: false)
            return
        }
        issuedSeeks += 1
        let target = CMTime(value: k, timescale: CMTimeScale(fps))
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                request.seekDone = true
                self.pollExact(request)
            }
        }
    }

    private func pollExact(_ r: Request) {
        guard active === r else { return }
        let elapsed = (CACurrentMediaTime() - r.start) * 1000
        let target = CMTime(value: r.k, timescale: CMTimeScale(fps))
        if let f = bridge.pull(itemTime: target), f.k == r.k {
            finish(r, frame: r.k, reached: true)
            return
        }
        if let cur = bridge.current, cur.k == r.k {
            if cur.serial > r.startSerial {
                finish(r, frame: r.k, reached: true)
                return
            }
            if !r.requireNew, lastComposedFrame() == r.k, elapsed >= 4 {
                finish(r, frame: r.k, reached: true)
                return
            }
        }
        if elapsed >= (r.timeoutMs ?? timeoutMs) {
            Log.info(.preview, "exact seek to \(r.k) timed out; showing \(String(describing: bridge.current?.k))")
            finish(r, frame: displayedFrame(fallback: r.k), reached: false)
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in self?.pollExact(r) }
    }

    // MARK: Scrub

    /// Scrubs to output frame [k] (coalesced, latest wins).
    func scrub(_ k: Int64, completion: @escaping Completion) {
        if active != nil {
            if var pending = pendingScrub {
                pending.k = k
                pending.completions.append(completion)
                pendingScrub = pending
            } else {
                pendingScrub = (k, [completion])
            }
            return
        }
        startScrub(k, completions: [completion])
    }

    private func startScrub(_ k: Int64, completions: [Completion]) {
        let now = CACurrentMediaTime()
        var tolerance = CMTime.zero
        if let last = lastScrub, now > last.t {
            let speed = Double(abs(k - last.k)) / (now - last.t)
            if speed > fastScrubFactor * Double(fps) { tolerance = scrubTolerance }
        }
        lastScrub = (k, now)
        let request = Request(kind: .scrub, k: k, completions: completions, startSerial: bridge.currentSerial, requireNew: false)
        active = request
        guard let player else {
            finish(request, frame: displayedFrame(fallback: k), reached: false)
            return
        }
        issuedSeeks += 1
        issuedScrubs += 1
        let target = CMTime(value: k, timescale: CMTimeScale(fps))
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                request.seekDone = true
                self.pollScrub(request)
            }
        }
    }

    private func pollScrub(_ r: Request) {
        guard active === r else { return }
        let elapsed = (CACurrentMediaTime() - r.start) * 1000
        let time = player?.currentItem?.currentTime() ?? CMTime(value: r.k, timescale: CMTimeScale(fps))
        if let f = bridge.pull(itemTime: time), let k = f.k {
            finish(r, frame: k, reached: true)
            return
        }
        if let cur = bridge.current, cur.serial > r.startSerial, let k = cur.k {
            finish(r, frame: k, reached: true)
            return
        }
        if let cur = bridge.current, cur.k == r.k, lastComposedFrame() == r.k, elapsed >= 4 {
            finish(r, frame: r.k, reached: true)
            return
        }
        if elapsed >= scrubSettleMs + (r.seekDone ? 0 : timeoutMs) {
            finish(r, frame: displayedFrame(fallback: r.k), reached: false)
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in self?.pollScrub(r) }
    }

    // MARK: Completion

    private func finish(_ r: Request, frame: Int64, reached: Bool) {
        if active === r { active = nil }
        let outcome = Outcome(frame: frame, reached: reached, ms: (CACurrentMediaTime() - r.start) * 1000)
        let completions = r.completions
        r.completions = []
        completions.forEach { $0(outcome) }
        if active == nil, let next = pendingScrub {
            pendingScrub = nil
            startScrub(next.k, completions: next.completions)
        }
    }

    /// Completes every waiting seek with the frame on screen (dispose, play dropping scrubs).
    func cancelAll() {
        let pending = pendingScrub
        pendingScrub = nil
        let fallback = displayedFrame(fallback: 0)
        if let r = active {
            active = nil
            finish(r, frame: displayedFrame(fallback: r.k), reached: false)
        }
        if let pending {
            let outcome = Outcome(frame: fallback, reached: false, ms: 0)
            pending.completions.forEach { $0(outcome) }
        }
    }

    /// Drops the pending scrub (play/pause): its callers get the in-flight scrub's ack.
    func dropPendingScrub() {
        guard let pending = pendingScrub else { return }
        pendingScrub = nil
        if let r = active {
            r.completions += pending.completions
        } else {
            let outcome = Outcome(frame: displayedFrame(fallback: pending.k), reached: false, ms: 0)
            pending.completions.forEach { $0(outcome) }
        }
    }

    private func displayedFrame(fallback: Int64) -> Int64 {
        bridge.lastComposed?.k ?? fallback
    }
}
