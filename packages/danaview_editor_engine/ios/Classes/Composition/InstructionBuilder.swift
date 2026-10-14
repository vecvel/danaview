// OWNER: IOS-08
//
// InstructionBuilder (ARCH §13.2 'Composition'): splits the timeline at every layer boundary into
// compositor instructions. Every range is `CMTime(k, gridFps)` (D-35; boundaries are grid frames
// because every layer edge lies on the `canvas.gridFps` grid), layers are listed bottom → top in
// plan order (z, t0, id), and each instruction names the composition video tracks of its active
// media layers as required source tracks. Gaps get instructions too (the spacer track keeps the
// compositor running for every output frame, so the background and non-media layers render there).
//
// The instruction object handed to AVFoundation is made by a factory: by default `LayerInstruction`
// (below); IOS-10's DVCompositor supplies its own `DVInstruction` through
// `CompositionBuildOptions.makeInstruction` (Render/DVInstruction.swift is owned by IOS-10).

import AVFoundation
import Foundation

/// One instruction interval, frames [startFrame, endFrame) of the edit grid.
struct InstructionSpec: Equatable {
    let startFrame: Int64
    let endFrame: Int64
    /// The edit grid (`canvas.gridFps`).
    let gridFps: Int64
    /// Active layer ids, bottom → top.
    let layerIds: [String]
    /// Composition video track of each active media layer.
    let trackIDByLayer: [String: CMPersistentTrackID]
    /// Distinct required source tracks, in bottom → top order of first use.
    let requiredTrackIDs: [CMPersistentTrackID]

    /// `CMTime(startFrame, gridFps) ..< CMTime(endFrame, gridFps)`.
    var timeRange: CMTimeRange {
        let ts = CMTimeScale(gridFps)
        return CMTimeRange(
            start: CMTime(value: startFrame, timescale: ts),
            duration: CMTime(value: endFrame - startFrame, timescale: ts))
    }
}

/// The default compositor instruction: a grid time range, the active layers and their tracks.
/// Open for subclassing so a compositor can attach its own state.
class LayerInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let spec: InstructionSpec
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    required init(spec: InstructionSpec) {
        self.spec = spec
        self.timeRange = spec.timeRange
        self.requiredSourceTrackIDs = spec.requiredTrackIDs.isEmpty ? nil : spec.requiredTrackIDs.map { NSNumber(value: $0) }
        super.init()
    }

    /// Active layer ids, bottom → top.
    var layerIds: [String] { spec.layerIds }
}

enum InstructionBuilder {
    /// The instruction intervals of [plan] covering [0, K) of the edit grid (K = frame of `durUs`).
    /// [trackIDBySeq] maps CORE-36 slots to composition video tracks.
    static func build(plan: RenderPlan, trackIDBySeq: [Int: CMPersistentTrackID]) -> [InstructionSpec] {
        let grid = plan.canvas.editGrid
        let total = grid.frameIndexOf(plan.durUs)
        guard total > 0 else { return [] }
        // Layer frame spans (exact: edges lie on the grid; clamp defensively to [0, K]).
        struct Span {
            let k0: Int64
            let k1: Int64
            let layer: PlanLayer
        }
        var spans: [Span] = []
        spans.reserveCapacity(plan.layers.count)
        var bounds = Set<Int64>([0, total])
        for l in plan.layers {
            let k0 = max(0, min(total, grid.frameIndexOf(l.t0)))
            let k1 = max(0, min(total, grid.frameIndexOf(l.t1)))
            guard k1 > k0 else { continue }
            spans.append(Span(k0: k0, k1: k1, layer: l))
            bounds.insert(k0)
            bounds.insert(k1)
        }
        let sorted = bounds.sorted()
        // Sweep: spans by start; active set kept in plan (draw) order by span index.
        let byStart = spans.indices.sorted { spans[$0].k0 < spans[$1].k0 }
        var next = 0
        var active: [Int] = []
        var out: [InstructionSpec] = []
        out.reserveCapacity(sorted.count)
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i]
            let b = sorted[i + 1]
            active.removeAll { spans[$0].k1 <= a }
            var added = false
            while next < byStart.count, spans[byStart[next]].k0 <= a {
                if spans[byStart[next]].k1 > a {
                    active.append(byStart[next])
                    added = true
                }
                next += 1
            }
            if added { active.sort() }
            var ids: [String] = []
            var trackByLayer: [String: CMPersistentTrackID] = [:]
            var required: [CMPersistentTrackID] = []
            for s in active {
                let l = spans[s].layer
                ids.append(l.id)
                if l.kind == .media, let seq = l.seq, let track = trackIDBySeq[seq] {
                    trackByLayer[l.id] = track
                    if !required.contains(track) { required.append(track) }
                }
            }
            out.append(
                InstructionSpec(
                    startFrame: a, endFrame: b, gridFps: grid.fps, layerIds: ids, trackIDByLayer: trackByLayer,
                    requiredTrackIDs: required))
        }
        return out
    }

    /// The instruction whose range contains [time] (binary search over contiguous ranges).
    static func lookup(_ specs: [InstructionSpec], at time: CMTime) -> InstructionSpec? {
        guard let first = specs.first else { return nil }
        let grid = FrameGrid(fps: first.gridFps)
        // Exact rational comparison: the instruction [a, b) contains time iff a/g ≤ time < b/g.
        var lo = 0
        var hi = specs.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let s = specs[mid]
            if CMTimeCompare(time, grid.cmTime(frame: s.startFrame)) < 0 {
                hi = mid - 1
            } else if CMTimeCompare(time, grid.cmTime(frame: s.endFrame)) >= 0 {
                lo = mid + 1
            } else {
                return s
            }
        }
        return nil
    }
}
