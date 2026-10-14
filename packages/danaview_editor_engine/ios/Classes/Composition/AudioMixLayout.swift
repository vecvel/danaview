// OWNER: IOS-08
//
// Audio layout of a plan (ARCH §13.2 'Audio', §11.6 Audio row, D-37):
//
// - Audio segments are interval-coloured × `pitch` into composition audio tracks: segments of one
//   track never overlap and share one time-pitch algorithm (`.timeDomain` keeps pitch, ARCH §13.2
//   overrides the `.spectral` of the BUILD_PLAN after IOS-01 V-N21; `.varispeed` otherwise).
// - Every track carries one IOS-18 `GainTap` whose `TapEnvelope` is the concatenation of its
//   segments' plan gain envelopes (clipped to each segment's range; no `setVolumeRamp`). A gain-only
//   patch rebuilds the envelopes and swaps them into the taps without rebuilding the item.
// - Speed ramps (a segment whose map has more than one piece) with IOS-18's ramp-seam option
//   enabled (`TapEnvelope.rampSeamCrossfadesEnabled`) get a PAIR of tracks: piece k goes to track
//   k % 2, extended 2.5 ms over each inner seam, and both envelopes carry the seams' 5 ms
//   equal-power crossfades. Ramp segments that do not overlap share a pair.
//
// This file is the pure part (which segment and piece goes where, the envelopes); the
// AVFoundation insertion is in CompositionBuilder.

import Foundation

/// Where audio goes: tracks (lanes) and their segments.
struct AudioMixLayout: Equatable {
    /// One composition audio track (or one track of a ramp pair).
    struct Track: Equatable {
        /// true = keep pitch (`.timeDomain`), false = `.varispeed`.
        let pitch: Bool
        /// Index of the lane this track belongs to.
        let lane: Int
        /// 0 for plain lanes; 0 or 1 within a ramp pair.
        let pairIndex: Int
        /// Whether this track is half of a ramp-seam pair.
        let isRampPair: Bool
        /// The plan segments whose audio (or ramp pieces) this track carries, in time order.
        var segmentIds: [String]
    }

    /// One piece of audio to insert: composition [t0, t1) ← source [s0, s1) µs. `t0Frame`/`t1Frame`
    /// are the grid frames of the unextended piece; `preUs`/`postUs` the ramp-seam extensions.
    struct Piece: Equatable {
        let track: Int
        let segmentId: String
        let mapIndex: Int
        let segment: MapSegment
        let preUs: Int64
        let postUs: Int64
    }

    var tracks: [Track]
    var pieces: [Piece]

    /// The layout of [plan]'s audio (skipping segments in [skip], e.g. a missing stream).
    static func make(_ plan: RenderPlan, rampSeams: Bool, skip: Set<String> = []) -> AudioMixLayout {
        struct Lane {
            let pitch: Bool
            let ramp: Bool
            var end: Int64
            var tracks: [Int]
        }
        var lanes: [Lane] = []
        var tracks: [Track] = []
        var pieces: [Piece] = []
        let half = TapEnvelope.seamCrossfadeUs / 2
        for seg in plan.audio where !skip.contains(seg.id) {
            let ramp = rampSeams && seg.map.count > 1
            var laneIndex = lanes.firstIndex { $0.pitch == seg.pitch && $0.ramp == ramp && $0.end <= seg.t0 }
            if laneIndex == nil {
                let first = tracks.count
                let count = ramp ? 2 : 1
                for p in 0..<count {
                    tracks.append(Track(pitch: seg.pitch, lane: lanes.count, pairIndex: p, isRampPair: ramp, segmentIds: []))
                }
                lanes.append(Lane(pitch: seg.pitch, ramp: ramp, end: Int64.min, tracks: Array(first..<(first + count))))
                laneIndex = lanes.count - 1
            }
            let li = laneIndex!
            lanes[li].end = seg.t1
            for t in lanes[li].tracks { tracks[t].segmentIds.append(seg.id) }
            let n = seg.map.count
            for (k, m) in seg.map.enumerated() {
                if ramp {
                    pieces.append(
                        Piece(
                            track: lanes[li].tracks[k % 2], segmentId: seg.id, mapIndex: k, segment: m,
                            preUs: k > 0 ? half : 0, postUs: k < n - 1 ? half : 0))
                } else {
                    pieces.append(Piece(track: lanes[li].tracks[0], segmentId: seg.id, mapIndex: k, segment: m, preUs: 0, postUs: 0))
                }
            }
        }
        return AudioMixLayout(tracks: tracks, pieces: pieces)
    }

    /// The tap envelope of track [index] for [plan]'s current gains; nil when a segment of the
    /// track is no longer in the plan (a structural change: rebuild instead).
    func envelope(track index: Int, plan: RenderPlan) -> TapEnvelope? {
        let track = tracks[index]
        let byId = Dictionary(plan.audio.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        var keys: [(tUs: Int64, g: Double)] = []
        var seams: [TapEnvelope.Seam] = []
        for id in track.segmentIds {
            guard let seg = byId[id] else { return nil }
            keys.append(contentsOf: Self.clippedKeys(seg))
            if track.isRampPair {
                let boundaries = seg.map.dropFirst().map(\.t0)
                seams.append(contentsOf: TapEnvelope.alternatingSeams(boundariesUs: Array(boundaries), track: track.pairIndex))
            }
        }
        let envelope = TapEnvelope(keys: keys)
        return seams.isEmpty ? envelope : envelope.withSeamCrossfades(seams)
    }

    /// [seg]'s gain keys restricted to [t0, t1]: the envelope value at both edges plus the keys
    /// strictly inside, so concatenated segments switch envelopes exactly at their boundaries.
    static func clippedKeys(_ seg: AudioSeg) -> [(tUs: Int64, g: Double)] {
        guard !seg.gain.isEmpty else { return [(seg.t0, 1), (seg.t1, 1)] }
        var out: [(tUs: Int64, g: Double)] = [(seg.t0, Keyframes.evaluate(seg.gain, at: seg.t0, fallback: 1))]
        for k in seg.gain where k.tUs > seg.t0 && k.tUs < seg.t1 { out.append((k.tUs, k.v)) }
        out.append((seg.t1, Keyframes.evaluate(seg.gain, at: seg.t1, fallback: 1)))
        return out
    }
}
