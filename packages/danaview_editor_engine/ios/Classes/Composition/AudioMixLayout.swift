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
// - Keep-pitch latency compensation (FIX-IOS-PITCH-SYNC, QA-03 finding 2): AVFoundation's
//   `.timeDomain` time-pitch runs on a whole composition track as soon as one of its edits is
//   scaled (a track of unscaled edits only is passed through untouched), and it moves the audio of
//   every edit of such a track by a deterministic, rate-dependent amount — the same in
//   AVAssetReaderAudioMixOutput (export) and AVPlayer (preview), measured on the iOS 26.5
//   simulator: −36 ms at 0.5×, −14 ms at 0.75×, −4 ms at 1×, +6 ms at 1.5×, +9 ms at 2×, i.e.
//   shift(r) ≈ A + B / r with A = +25.8 ms and B = −30.7 ms (output delay and source look-ahead of
//   the grain search). Every piece of such a track therefore reads its source shifted by
//   δ(r) = r · shift(r) = A·r + B (whole µs; rate and grid placement unchanged). Pieces of one
//   segment at different rates get different offsets, so a seam skips or repeats |Δδ| (a few ms)
//   of source, like the time-pitch's own grains; the seam transient is unchanged (QA-11 click
//   test), but the phase of a pure tone is not continuous across seams. (A blend that kept the
//   source continuous across seams, drifting each piece between shared seam offsets, made the
//   seam transients 30× larger on the iOS 26.5 simulator and was dropped.)
//   Where the shifted range (with its ramp-seam extensions) would leave [0, asset duration], the
//   piece is trimmed at that edge by the missing source time / r (negative `preUs`/`postUs`; at
//   most a few tens of ms of what is silence-before-the-source anyway) rather than read with a
//   changed rate; a piece whose plan map already runs past its source end (silent there, ARCH
//   §11.5) is trimmed to the end the same way and keeps its shift. Pieces of `.varispeed` tracks
//   and of keep-pitch tracks without a scaled edit are not shifted.
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
    /// are the grid frames of the unextended piece; `preUs`/`postUs` the ramp-seam extensions
    /// (negative: the piece is trimmed at that edge by keep-pitch latency compensation, whose
    /// shifted source would otherwise start before 0 or end past the asset).
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
        compensatePitchLatency(&pieces, tracks: tracks, plan: plan)
        return AudioMixLayout(tracks: tracks, pieces: pieces)
    }

    // MARK: - Keep-pitch latency (FIX-IOS-PITCH-SYNC)

    /// Output delay A of the `.timeDomain` time-pitch (composition µs).
    static let pitchLatencyOutputUs = 25_800.0
    /// Source look-ahead term B of the `.timeDomain` time-pitch (composition µs at 1×, ∝ 1/rate).
    static let pitchLatencySourceUs = -30_700.0
    /// Composition-time shift (µs) of audio inside a keep-pitch track at [rate] (uncompensated).
    static func pitchShiftUs(rate: Double) -> Double {
        pitchLatencyOutputUs + pitchLatencySourceUs / rate
    }

    /// Source offset (µs) that cancels `pitchShiftUs` at [rate]: reading the source δ later moves
    /// the audio δ / rate earlier.
    static func pitchCompensationUs(rate: Double) -> Int64 {
        Int64((rate * pitchShiftUs(rate: rate)).rounded())
    }

    /// Whether piece [p] is inserted scaled (CompositionBuilder scales every non-unity piece).
    private static func isScaled(_ p: Piece) -> Bool {
        p.segment.s1 - p.segment.s0 != p.segment.t1 - p.segment.t0
    }

    /// Shifts the sources of every piece on a keep-pitch track that has a scaled piece by
    /// `pitchCompensationUs` of its rate (pieces of other tracks stay as they are: a track without
    /// a scaled piece is passed through untouched and must stay so).
    private static func compensatePitchLatency(_ pieces: inout [Piece], tracks: [Track], plan: RenderPlan) {
        let active = Set(pieces.filter { tracks[$0.track].pitch && isScaled($0) }.map(\.track))
        guard !active.isEmpty else { return }
        let assetBySeg = Dictionary(plan.audio.map { ($0.id, $0.asset) }, uniquingKeysWith: { _, b in b })
        for i in pieces.indices where active.contains(pieces[i].track) {
            let p = pieces[i]
            let m = p.segment
            let rate = m.rate
            guard rate.isFinite, rate > 0 else { continue }
            let delta = pitchCompensationUs(rate: rate)
            guard delta != 0 else { continue }
            let span = m.t1 - m.t0
            var pre = p.preUs
            var post = p.postUs
            // The shifted source must stay inside [0, asset duration]. Where it would not, the piece
            // is trimmed at that edge instead (a negative extension: it starts later / ends earlier
            // in composition time by the part that has no source), keeping its rate; the trimmed
            // part is the audio the time-pitch would have pulled from outside the source.
            let first = m.s0 + delta - Int64((Double(pre) * rate).rounded())
            if first < 0 { pre -= Int64((Double(-first) / rate).rounded(.up)) }
            if let dur = assetBySeg[p.segmentId].flatMap({ plan.assets[$0]?.durUs }) {
                let last = m.s1 + delta + Int64((Double(post) * rate).rounded())
                if last > dur { post -= Int64((Double(last - dur) / rate).rounded(.up)) }
            }
            // Never trim a piece away (a piece shorter than twice the shift keeps its plain read).
            // The span that counts is the part inside the source: past its source end a piece is
            // silent anyway (ARCH §11.5; CompositionBuilder plays it at its rate up to the end), so
            // a piece running far past its source keeps its compensation (its audible part in sync).
            var audible = span
            if let dur = assetBySeg[p.segmentId].flatMap({ plan.assets[$0]?.durUs }), m.s1 > dur {
                audible = min(span, max(0, Int64(Double(dur - m.s0) / rate)))
            }
            guard audible > 0, span + pre + post > audible / 2 else { continue }
            pieces[i] = Piece(
                track: p.track, segmentId: p.segmentId, mapIndex: p.mapIndex,
                segment: MapSegment(m.t0, m.t1, m.s0 + delta, m.s1 + delta), preUs: pre, postUs: post)
        }
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
