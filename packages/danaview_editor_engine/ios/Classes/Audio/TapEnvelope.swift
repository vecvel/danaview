// OWNER: IOS-18
//
// The gain envelope a GainTap multiplies into one composition audio track (D-37, ARCH §11.6 Audio
// row, §11.7, §13.2 'Audio'). Immutable: a gain-only patch builds a new TapEnvelope and swaps it into
// the track's GainTap (GainTap.swapEnvelope), so the AVPlayerItem is never rebuilt.
//
// Semantics mirror the Dart reference (`AudioMath.gainAt`, API-03; vectors in
// packages/danaview_editor_engine_api/test_fixtures/vectors/gain.json):
//
// - `gain` is the plan's linear envelope (0–2, i.e. up to +6.02 dB) as [tUs, g] keys in composition
//   (timeline) µs, linear between keys and held outside; no keys = unity. Values are not clamped
//   (the validator of ARCH §11.3 owns the range), only non-finite values are treated as 0.
// - Output sample i of a buffer starting at composition time t0 µs is at t0 + i·10⁶/sampleRate.
//
// Ramp-seam option (review issue 21): when speed-ramp audio alternates across two composition
// tracks (IOS-08), each track's envelope carries the seams it touches (`withSeamCrossfades`). A seam
// at time s is a 5 ms equal-power crossfade centred on s: the outgoing side is multiplied by
// cos(π·x/2), the incoming side by sin(π·x/2), x = (t − (s − 2.5 ms)) / 5 ms. The seams also say where
// the track is meant to be heard: from the start (or an incoming window) to the next outgoing window
// (or the end). Everywhere else the track is SILENCED (factor 0), because IOS-18 measured on iOS 26.5:
// - a `.timeDomain` time-stretched segment keeps sounding after its composition range ends (its
//   overlap-add tail: +5 ms at 1.25×, +8–11 ms at 1.6×, +16 ms at 2×), which would otherwise leak
//   past the outgoing window at full level;
// - the reader hands the tap ranges about one sample off the rendered position (V-N21: ≤ 0.04 ms),
//   so the first sample of an incoming segment fell before its window (a −15 dBFS click).
// IOS-08 extends the outgoing segment 2.5 ms past the seam and starts the incoming one 2.5 ms before
// it, so both tracks carry audio across the whole window. Elsewhere the factor is 1.

import Foundation

/// A track's gain envelope plus optional ramp-seam crossfades (immutable, thread-safe).
final class TapEnvelope {
    /// One seam crossfade on this track.
    struct Seam: Equatable {
        enum Edge: Equatable {
            /// This track's segment starts at the seam (fades in).
            case incoming
            /// This track's segment ends at the seam (fades out).
            case outgoing
        }

        /// Composition time of the seam, µs.
        let timeUs: Int64
        let edge: Edge
    }

    /// Length of a seam crossfade (5 ms, centred on the seam).
    static let seamCrossfadeUs: Int64 = 5_000

    /// Whether IOS-08 lays speed-ramp audio out with the ramp-seam option (segments alternating
    /// across two composition tracks, each extended 2.5 ms over its seams, envelopes built with
    /// `withSeamCrossfades(alternatingSeams(…))`). ENABLED by IOS-18 (2026-10-11, iOS 26.5
    /// simulator): the crossfade layout keeps seam transients 59 dB under the tone (AC: −40 dBFS),
    /// while the plain single-track layout over 7 `.timeDomain` scaleTimeRange segments could not be
    /// read reliably through AVAssetReaderAudioMixOutput (silent windows, a hang; 3 of 4 reads bad).
    /// RampSeamTests re-measures both layouts on every run.
    static let rampSeamCrossfadesEnabled = true

    /// The unity envelope (gain 1 everywhere, no seams).
    static let unity = TapEnvelope(keys: [])

    /// Key times (µs, non-decreasing) and linear gains.
    let timesUs: [Double]
    let gains: [Double]
    /// Seam crossfades sorted by time.
    let seams: [Seam]
    /// Where the seams make the track silent ([a, b) µs, sorted).
    private let silentUs: [(Double, Double)]

    /// Envelope from [tUs, g] keys (sorted by time with a stable sort if they are not).
    init(keys: [(tUs: Int64, g: Double)], seams: [Seam] = []) {
        let sorted = keys.enumerated().sorted { a, b in
            a.element.tUs != b.element.tUs ? a.element.tUs < b.element.tUs : a.offset < b.offset
        }.map(\.element)
        timesUs = sorted.map { Double($0.tUs) }
        gains = sorted.map { $0.g.isFinite ? $0.g : 0 }
        self.seams = seams.sorted { $0.timeUs < $1.timeUs }
        silentUs = Self.silentIntervals(self.seams)
    }

    /// Envelope from the plan's JSON `gain` array (`[[tUs, g], …]`, ARCH §11.2). Entries that are
    /// not two numbers are ignored.
    convenience init(planGain: [[Double]]) {
        self.init(keys: planGain.compactMap { $0.count >= 2 ? (Int64($0[0].rounded()), $0[1]) : nil })
    }

    /// A copy with [seams] as its ramp-seam crossfades (API of IOS-18 for IOS-08).
    func withSeamCrossfades(_ seams: [Seam]) -> TapEnvelope {
        TapEnvelope(timesUs: timesUs, gains: gains, seams: seams.sorted { $0.timeUs < $1.timeUs })
    }

    private init(timesUs: [Double], gains: [Double], seams: [Seam]) {
        self.timesUs = timesUs
        self.gains = gains
        self.seams = seams
        silentUs = Self.silentIntervals(seams)
    }

    /// The seams of composition track [track] (0 or 1) when ramp segment k (k = 0…n) lives on
    /// track k % 2 and [boundariesUs] are the n seams between consecutive segments, in order.
    static func alternatingSeams(boundariesUs: [Int64], track: Int) -> [Seam] {
        var out: [Seam] = []
        for (j, b) in boundariesUs.enumerated() {
            // Boundary j separates segment j (outgoing) and segment j + 1 (incoming).
            if j % 2 == track { out.append(Seam(timeUs: b, edge: .outgoing)) }
            if (j + 1) % 2 == track { out.append(Seam(timeUs: b, edge: .incoming)) }
        }
        return out
    }

    /// The plan envelope alone at composition time [tUs] (exactly `AudioMath.gainAt`).
    func envelopeGain(atUs tUs: Double) -> Double {
        guard let first = timesUs.first, let last = timesUs.last else { return 1 }
        if tUs <= first { return gains[0] }
        if tUs >= last { return gains[gains.count - 1] }
        var lo = 0
        var hi = timesUs.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) >> 1
            if timesUs[mid] <= tUs { lo = mid } else { hi = mid }
        }
        return gains[lo] + (gains[hi] - gains[lo]) * (tUs - timesUs[lo]) / (timesUs[hi] - timesUs[lo])
    }

    /// The product of every seam factor at [tUs]: 0 where the seams say the track is silent, the
    /// equal-power curve inside the windows, else 1.
    func seamFactor(atUs tUs: Double) -> Double {
        guard !seams.isEmpty else { return 1 }
        for (a, b) in silentUs where tUs >= a && tUs < b { return 0 }
        var f = 1.0
        for seam in seams {
            let s = Double(seam.timeUs)
            if tUs < s - Self.halfUs { break }
            f *= Self.windowFactor(seam, tUs)
        }
        return f
    }

    private static let halfUs = Double(seamCrossfadeUs) / 2

    /// One seam's window factor at [tUs] (1 outside [s − 2.5 ms, s + 2.5 ms)).
    private static func windowFactor(_ seam: Seam, _ tUs: Double) -> Double {
        let s = Double(seam.timeUs)
        guard tUs >= s - halfUs, tUs < s + halfUs else { return 1 }
        let x = (tUs - (s - halfUs)) / Double(seamCrossfadeUs)
        return seam.edge == .outgoing ? cos(Double.pi * x / 2) : sin(Double.pi * x / 2)
    }

    /// The [a, b) µs intervals where the seams make this track silent: before the first incoming
    /// window (when the track starts with one), between an outgoing window and the next incoming
    /// window, and after a final outgoing window.
    private static func silentIntervals(_ seams: [Seam]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        var silentFrom: Double? = seams.first?.edge == .incoming ? -.infinity : nil
        for seam in seams {
            let s = Double(seam.timeUs)
            switch seam.edge {
            case .outgoing:
                silentFrom = s + halfUs
            case .incoming:
                if let from = silentFrom, s - halfUs > from { out.append((from, s - halfUs)) }
                silentFrom = nil
            }
        }
        if let from = silentFrom { out.append((from, .infinity)) }
        return out
    }

    /// The full multiplier at composition time [tUs]: envelope × seam factor.
    func gain(atUs tUs: Double) -> Double {
        envelopeGain(atUs: tUs) * seamFactor(atUs: tUs)
    }

    /// Writes the multiplier of [count] consecutive output samples, the first at [startUs], spaced
    /// 10⁶/[sampleRate] µs, into [out]. Allocation-free (runs on the audio render thread).
    func fill(_ out: UnsafeMutablePointer<Float>, count: Int, startUs: Double, sampleRate: Double) {
        guard count > 0 else { return }
        let step = 1_000_000 / sampleRate
        let n = timesUs.count
        if n == 0 {
            for i in 0..<count { out[i] = 1 }
        } else if n == 1 {
            let g = Float(gains[0])
            for i in 0..<count { out[i] = g }
        } else {
            // Index of the last key with time <= t (or -1 before the first key), advanced as t grows.
            var k = -1
            let t0 = startUs
            if t0 >= timesUs[0] {
                var lo = 0
                var hi = n - 1
                if t0 >= timesUs[hi] {
                    k = hi
                } else {
                    while hi - lo > 1 {
                        let mid = (lo + hi) >> 1
                        if timesUs[mid] <= t0 { lo = mid } else { hi = mid }
                    }
                    k = lo
                }
            }
            for i in 0..<count {
                let t = startUs + Double(i) * step
                while k + 1 < n, timesUs[k + 1] <= t { k += 1 }
                let g: Double
                if k < 0 || t <= timesUs[0] {
                    g = gains[0]
                } else if k >= n - 1 {
                    g = gains[n - 1]
                } else {
                    g = gains[k] + (gains[k + 1] - gains[k]) * (t - timesUs[k]) / (timesUs[k + 1] - timesUs[k])
                }
                out[i] = Float(g)
            }
        }
        guard !seams.isEmpty else { return }
        let endUs = startUs + Double(count) * step
        for seam in seams {
            let s = Double(seam.timeUs)
            if s - Self.halfUs >= endUs { break }
            if s + Self.halfUs <= startUs { continue }
            for i in 0..<count {
                let t = startUs + Double(i) * step
                guard t >= s - Self.halfUs, t < s + Self.halfUs else { continue }
                out[i] *= Float(Self.windowFactor(seam, t))
            }
        }
        for (a, b) in silentUs where a < endUs && b > startUs {
            for i in 0..<count {
                let t = startUs + Double(i) * step
                if t >= a && t < b { out[i] = 0 }
            }
        }
    }
}
