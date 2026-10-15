// OWNER: IOS-20
//
// Multi-pass precompose planning (ARCH D-45(B), §14.2 'Multi-pass fallback'; parity with AND-19).
// Pure: no AVFoundation, no files.
//
// Given an export plan and the number of composition tracks the device decodes at once (the
// decoder limit), the planner cuts the plan's layers, in draw order (z, t0, id), into passes:
//
//   pass 1      the canvas background plus the longest bottom prefix of layers whose
//               decoder-backed slots (distinct `seq` of media layers) fit the limit, rendered
//               into an opaque full-resolution intermediate `pre-1`;
//   pass n > 1  `pre-(n-1)` as the bottom layer plus the next prefix that fits the limit minus
//               the one decoder the intermediate takes;
//   final       the last intermediate plus every remaining layer, with the plan's audio (audio is
//               mixed once, in the final pass).
//
// Because each intermediate is the opaque result of everything below it and the compositor
// composites premultiplied source-over in draw order, nothing above it changes: no alpha is
// carried between passes and the blending order is unchanged. Images, solids and sprites take no
// decoder; they go with the prefix they belong to in draw order. Every pass consumes at least one
// media layer, so a limit of at least 2 always terminates.
//
// The intermediate of pass n is a media layer over the whole duration: identity transform, base =
// canvas, map [0, durUs) → [0, durUs) (the composition builder adds its ε, D-04, so output frame k
// samples intermediate frame k, both on the export frame grid), a fresh `seq` above every slot of
// the plan, and z below every other layer of its pass (z = min − 1, or 0 with an id that sorts
// first; otherwise the other layers move up by one z, which keeps their order). Its asset uri is
// a placeholder (`placeholderURI(n)`) so pass hashes do not depend on the app container path,
// which iOS may change between launches; `resolve` swaps the real file in before a build. The
// asset fingerprint carries the hash of the pass that wrote it, so a pass hash covers every pass
// below it (a resumed job reuses an intermediate only when everything that produced it matches).
// With the `.rotated` encode layout (ARCH §14.1) intermediates are written as landscape buffers and
// the asset says `rot: 90`, which the compositor turns back upright.

import Foundation

/// One intermediate pass.
struct PrecomposePassSpec: Equatable {
    /// 1-based pass number (the intermediate is `pre-<index>.mov`).
    let index: Int
    /// The pass plan (video only; the previous intermediate, if any, under its placeholder uri).
    let plan: RenderPlan
    /// Hex SHA-256 of the canonical pass plan (and the encode layout).
    let hash: String
    /// Ids of the plan's own layers this pass bakes in (the previous intermediate excluded).
    let layerIds: [String]
    /// Distinct composition tracks the pass decodes (its intermediate input included).
    let decoderTracks: Int
}

/// The passes of a plan for one decoder limit.
struct PrecomposeSchedule: Equatable {
    let limit: Int
    /// Intermediate passes in order (empty: the plan fits in one pass).
    let passes: [PrecomposePassSpec]
    /// The final pass plan (the last intermediate under its placeholder uri; the plan itself
    /// when `passes` is empty).
    let finalPlan: RenderPlan
    /// Distinct composition tracks of the final pass.
    let finalDecoderTracks: Int

    /// Intermediate passes plus the final one.
    var totalPasses: Int { passes.count + 1 }
}

enum PrecomposePlanner {
    /// The smallest limit that makes progress (the intermediate plus one new track).
    static let minimumLimit = 2
    /// Prefix of intermediate asset ids, layer ids and placeholder uris.
    static let assetPrefix = "__precompose"
    static let layerPrefix = "!precompose-"
    static let placeholderScheme = "file:///danaview-precompose/"

    static func assetId(_ pass: Int) -> String { "\(assetPrefix)\(pass)" }
    static func layerId(_ pass: Int) -> String { "\(layerPrefix)\(pass)" }
    static func placeholderURI(_ pass: Int) -> String { "\(placeholderScheme)pre-\(pass).mov" }
    static func fileName(_ pass: Int) -> String { "pre-\(pass).mov" }

    // MARK: Counting

    /// Distinct decoder-backed composition tracks (CORE-36 slots) of [layers].
    static func decoderSeqs<S: Sequence>(_ layers: S) -> Set<Int> where S.Element == PlanLayer {
        var out = Set<Int>()
        for l in layers where l.kind == .media {
            if let s = l.seq { out.insert(s) }
        }
        return out
    }

    // MARK: Limits

    /// The limit the first schedule uses: the device limit when it was exceeded; after a
    /// `decoderInitFailed` at export start, one track fewer than the plan needed (capped by the
    /// device limit). Nil when no split can help (the plan needs fewer tracks than a pass with an
    /// intermediate takes).
    static func initialLimit(reason: MultiPassReason, decoderLimit: Int, needed: Int) -> Int? {
        switch reason {
        case .decoderLimit(_, let limit):
            return max(minimumLimit, limit)
        case .decoderInitFailed:
            let limit = min(max(minimumLimit, decoderLimit), needed - 1)
            return limit >= minimumLimit ? limit : nil
        }
    }

    /// The next limit after a pass failed with `decoderInitFailed` at [current] (about three
    /// quarters, at least one fewer), nil at the minimum.
    static func reducedLimit(_ current: Int) -> Int? {
        guard current > minimumLimit else { return nil }
        return max(minimumLimit, min(current - 1, current * 3 / 4))
    }

    // MARK: Schedule

    /// Cuts [plan] into passes for [limit] (clamped to `minimumLimit`). [rotated]: intermediates
    /// are encoded with the `.rotated` layout.
    static func schedule(_ plan: RenderPlan, limit requested: Int, rotated: Bool) throws -> PrecomposeSchedule {
        let limit = max(minimumLimit, requested)
        let ordered = plan.layers.sorted(by: PlanLayer.drawOrder)
        if decoderSeqs(ordered).count <= limit {
            return PrecomposeSchedule(limit: limit, passes: [], finalPlan: plan, finalDecoderTracks: decoderSeqs(ordered).count)
        }
        let interSeq = (plan.layers.compactMap(\.seq).max() ?? -1) + 1
        var passes: [PrecomposePassSpec] = []
        var remaining = ordered[...]
        var previous: (pass: Int, hash: String)?
        while true {
            let available = limit - (previous == nil ? 0 : 1)
            if decoderSeqs(remaining).count <= available { break }
            // The longest prefix whose slots fit.
            var taken = Set<Int>()
            var end = remaining.startIndex
            while end < remaining.endIndex {
                let l = remaining[end]
                if l.kind == .media, let s = l.seq, !taken.contains(s) {
                    if taken.count == available { break }
                    taken.insert(s)
                }
                end += 1
            }
            guard !taken.isEmpty else {
                throw EngineError(.decoderInitFailed, "decoder limit \(limit) leaves no room for a precompose pass")
            }
            let prefix = Array(remaining[remaining.startIndex..<end])
            remaining = remaining[end...]
            let index = passes.count + 1
            let below = previous.map { intermediate(pass: $0.pass, hash: $0.hash, plan: plan, seq: interSeq, rotated: rotated) }
            let layers = stack(prefix, over: below?.layer)
            var assets = referencedAssets(layers, plan: plan)
            if let below = below { assets[below.layer.asset!] = below.asset }
            let passPlan = RenderPlan(
                v: plan.v, rev: plan.rev, target: .export, canvas: plan.canvas, durUs: plan.durUs, assets: assets,
                layers: layers, audio: [], req: nil)
            let hash = passHash(passPlan, rotated: rotated)
            passes.append(PrecomposePassSpec(
                index: index, plan: passPlan, hash: hash, layerIds: prefix.map(\.id),
                decoderTracks: decoderSeqs(layers).count))
            previous = (index, hash)
        }
        guard let last = previous else {
            return PrecomposeSchedule(limit: limit, passes: [], finalPlan: plan, finalDecoderTracks: decoderSeqs(ordered).count)
        }
        let below = intermediate(pass: last.pass, hash: last.hash, plan: plan, seq: interSeq, rotated: rotated)
        let layers = stack(Array(remaining), over: below.layer)
        var assets = referencedAssets(layers, plan: plan)
        for seg in plan.audio { if let a = plan.assets[seg.asset] { assets[seg.asset] = a } }
        assets[below.layer.asset!] = below.asset
        let finalPlan = RenderPlan(
            v: plan.v, rev: plan.rev, target: .export, canvas: plan.canvas, durUs: plan.durUs, assets: assets,
            layers: layers, audio: plan.audio, req: nil)
        return PrecomposeSchedule(limit: limit, passes: passes, finalPlan: finalPlan, finalDecoderTracks: decoderSeqs(layers).count)
    }

    /// [plan] with every placeholder intermediate uri replaced by the file [url] gives for its pass.
    static func resolve(_ plan: RenderPlan, url: (Int) -> URL) -> RenderPlan {
        var out = plan
        for (id, asset) in plan.assets where id.hasPrefix(assetPrefix) {
            guard let pass = Int(id.dropFirst(assetPrefix.count)) else { continue }
            var a = asset
            a.uri = url(pass).absoluteString
            out.assets[id] = a
        }
        return out
    }

    // MARK: Pieces

    /// The intermediate layer and asset of [pass].
    static func intermediate(pass: Int, hash: String, plan: RenderPlan, seq: Int, rotated: Bool)
        -> (layer: PlanLayer, asset: PlanAsset) {
        let w = plan.canvas.w
        let h = plan.canvas.h
        let asset = PlanAsset(
            kind: .video, uri: placeholderURI(pass), bookmark: nil, fp: "precompose:\(hash)", proxyUri: nil, w: w, h: h,
            rot: rotated ? 90 : 0, durUs: plan.durUs, transfer: .sdr, hasAudio: false)
        var layer = PlanLayer(id: layerId(pass), z: 0, seq: seq, t0: 0, t1: plan.durUs, kind: .media, asset: assetId(pass))
        layer.map = [MapSegment(0, plan.durUs, 0, plan.durUs)]
        layer.base = PlanSize(w: Double(w), h: Double(h))
        return (layer, asset)
    }

    /// [layers] (draw order) over [bottom]: the bottom layer gets a z below all of them, or the
    /// layers move up one z when z 0 is taken and the bottom's id would not sort first.
    static func stack(_ layers: [PlanLayer], over bottom: PlanLayer?) -> [PlanLayer] {
        guard var bottom = bottom else { return layers }
        guard let minZ = layers.map(\.z).min() else { return [bottom] }
        var others = layers
        if minZ > 0 {
            bottom.z = minZ - 1
        } else {
            bottom.z = 0
            let blocked = layers.contains { $0.z == 0 && !PlanLayer.drawOrder(bottom, $0) }
            if blocked {
                others = layers.map { var l = $0; l.z += 1; return l }
            }
        }
        return ([bottom] + others).sorted(by: PlanLayer.drawOrder)
    }

    /// The assets [layers] reference (media, image and sprite assets, LUTs).
    static func referencedAssets(_ layers: [PlanLayer], plan: RenderPlan) -> [String: PlanAsset] {
        var out: [String: PlanAsset] = [:]
        for l in layers {
            if let id = l.asset, let a = plan.assets[id] { out[id] = a }
            if let lut = l.fx.lut, let a = plan.assets[lut.asset] { out[lut.asset] = a }
        }
        return out
    }

    /// Hash of a pass plan (canonical JSON) and its encode layout.
    static func passHash(_ plan: RenderPlan, rotated: Bool) -> String {
        var data = PlanEncoder.encode(plan)
        data.append(contentsOf: Array((rotated ? "|rotated" : "|native").utf8))
        return ExportJob.hash(data)
    }
}
