// OWNER: IOS-11
//
// QualityGovernor (ARCH §12.2 'Adaptive preview', §13.2 'Session', §13.4; D-43(e)): the preview
// render scale of one session.
//
// - Render size = canvas × {1, ½, ¼}, then capped so its long side is ≤ `maxPreviewLongSide`
//   (tier), rounded to even pixels.
// - `PreviewQuality.auto` (default) adapts: during playback it steps down one level after more
//   than 10% of the frames of the last 2 s were missed, and back up one level after 10 s of
//   playback without a missed frame. Thermal `.serious` or worse caps auto at ½ until it eases.
// - `full`, `half` and `quarter` are pinned: the governor never changes a pinned quality (neither
//   miss statistics nor thermal state move it, owner decision 2026-10-11).
// - Only playback is measured: paused, scrub and exact seek frames never count.
// Pure and single-threaded (the session calls it on `previewControlQueue`); time is injected.

import CoreGraphics
import Foundation

final class QualityGovernor {
    /// Render scale levels.
    enum Level: Int, Comparable {
        case full = 0, half = 1, quarter = 2

        var scale: Double {
            switch self {
            case .full: return 1
            case .half: return 0.5
            case .quarter: return 0.25
            }
        }

        var msg: PreviewQualityMsg {
            switch self {
            case .full: return .full
            case .half: return .half
            case .quarter: return .quarter
            }
        }

        static func of(_ q: PreviewQualityMsg) -> Level {
            switch q {
            case .auto, .full: return .full
            case .half: return .half
            case .quarter: return .quarter
            }
        }

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    struct Config {
        /// Window of the missed-frame ratio (s).
        var window: TimeInterval = 2
        /// Step down above this missed fraction of the window.
        var missRatio = 0.10
        /// Step up after this much clean playback (s).
        var cleanSeconds: TimeInterval = 10
        /// Fewest frames in a full window before a step down (avoids reacting to start-up).
        var minFrames = 10
    }

    let config: Config
    private(set) var requested: PreviewQualityMsg
    private(set) var level: Level
    private(set) var thermalCapped = false
    private var samples: [(t: TimeInterval, missed: Bool)] = []
    private var windowStart: TimeInterval?
    private var cleanSince: TimeInterval?

    init(requested: PreviewQualityMsg, config: Config = Config()) {
        self.config = config
        self.requested = requested
        self.level = Level.of(requested)
    }

    var isAuto: Bool { requested == .auto }

    /// Sets the requested quality. Returns the new level when it changed.
    @discardableResult
    func setRequested(_ q: PreviewQualityMsg, at t: TimeInterval) -> Level? {
        requested = q
        resetStats(at: t)
        let next = isAuto ? (thermalCapped ? max(Level.full, .half) : .full) : Level.of(q)
        return change(to: next)
    }

    /// Thermal state change. Auto is capped at ½ while `.serious` or `.critical`.
    @discardableResult
    func setThermal(_ state: ProcessInfo.ThermalState, at t: TimeInterval) -> Level? {
        thermalCapped = state == .serious || state == .critical
        guard isAuto, thermalCapped, level < .half else { return nil }
        resetStats(at: t)
        return change(to: .half)
    }

    /// Playback started (statistics run only while playing).
    func playbackStarted(at t: TimeInterval) {
        resetStats(at: t)
    }

    /// Playback stopped.
    func playbackStopped() {
        samples.removeAll()
        windowStart = nil
        cleanSince = nil
    }

    /// One played frame, missed or shown. Returns the new level when the governor stepped.
    @discardableResult
    func record(missed: Bool, at t: TimeInterval) -> Level? {
        guard isAuto else { return nil }
        if windowStart == nil { resetStats(at: t) }
        samples.append((t, missed))
        while let first = samples.first, t - first.t > config.window { samples.removeFirst() }
        if missed { cleanSince = t }
        let elapsed = t - (windowStart ?? t)
        if elapsed >= config.window, samples.count >= config.minFrames, level < .quarter {
            let misses = samples.reduce(0) { $0 + ($1.missed ? 1 : 0) }
            if Double(misses) / Double(samples.count) > config.missRatio {
                resetStats(at: t)
                return change(to: Level(rawValue: level.rawValue + 1)!)
            }
        }
        if let clean = cleanSince, t - clean >= config.cleanSeconds, level > .full {
            let up = Level(rawValue: level.rawValue - 1)!
            if thermalCapped && up < .half { return nil }
            resetStats(at: t)
            return change(to: up)
        }
        return nil
    }

    private func resetStats(at t: TimeInterval) {
        samples.removeAll()
        windowStart = t
        cleanSince = t
    }

    private func change(to next: Level) -> Level? {
        guard next != level else { return nil }
        level = next
        return next
    }

    // MARK: Size

    /// The render size of [canvas] at [level], long side ≤ [maxLongSide] (0 = no cap), even px.
    static func renderSize(canvasWidth: Int, canvasHeight: Int, level: Level, maxLongSide: Int) -> CGSize {
        var w = Double(max(1, canvasWidth)) * level.scale
        var h = Double(max(1, canvasHeight)) * level.scale
        let long = max(w, h)
        if maxLongSide > 0, long > Double(maxLongSide) {
            let k = Double(maxLongSide) / long
            w *= k
            h *= k
        }
        func even(_ v: Double) -> CGFloat { CGFloat(max(2, Int((v / 2).rounded()) * 2)) }
        return CGSize(width: even(w), height: even(h))
    }
}
