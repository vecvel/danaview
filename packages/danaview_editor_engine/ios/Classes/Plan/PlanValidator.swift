// OWNER: IOS-08
//
// RenderPlan invariants (ARCH §11.3), mirroring
// packages/danaview_editor_core/lib/src/plan/plan_validator.dart (CORE-29) rule for rule, with the
// same violation codes and ids, so the `invalid/` contract fixtures report the same offender
// natively. A violation is `planInvalid` (a bug: logged with the layer id; preview keeps the last
// good frame).

import Foundation

/// Kinds of plan invariant violations (names equal the Dart `PlanViolationCode`).
enum PlanViolationCode: String, CaseIterable {
    case version, canvas, duration, duplicateId, asset, range, offGrid, map, seq, order, anim, value, zBand, gain
}

/// One violation, naming the offending layer, segment or asset id when there is one.
struct PlanViolation: Equatable, CustomStringConvertible {
    let code: PlanViolationCode
    let message: String
    let id: String?

    var description: String { "PlanViolation(\(code.rawValue)\(id.map { " \($0)" } ?? ""): \(message))" }
}

enum PlanValidator {
    private static let minRate = 0.1
    private static let maxRate = 10.0
    private static let rateEps = 1e-6
    /// First z of the text band (ARCH §11.4).
    private static let textBand = 20000

    /// All violations of [plan] (empty when valid).
    static func validate(_ plan: RenderPlan) -> [PlanViolation] {
        var out: [PlanViolation] = []
        func add(_ c: PlanViolationCode, _ m: String, _ id: String? = nil) { out.append(PlanViolation(code: c, message: m, id: id)) }

        if plan.v != renderPlanVersion { add(.version, "v must be \(renderPlanVersion)") }
        let c = plan.canvas
        if c.w < 16 || c.h < 16 || c.w % 2 != 0 || c.h % 2 != 0 { add(.canvas, "w/h must be even and ≥ 16") }
        if !FrameGrid.v1Rates.contains(c.fps) || !FrameGrid.v1Rates.contains(c.gridFps) {
            add(.canvas, "fps and gridFps must be integer v1 rates")
        }
        let gridValid = FrameGrid.v1Rates.contains(c.gridFps)
        let grid = FrameGrid(gridValid ? c.gridFps : 30)
        func onGrid(_ t: Int64) -> Bool { !gridValid || grid.isOnGrid(t) }
        if plan.durUs < 0 || !onGrid(plan.durUs) { add(.duration, "durUs must be ≥ 0 and on the gridFps grid") }

        for (id, asset) in plan.assets.sorted(by: { PlanIds.less($0.key, $1.key) }) {
            checkAsset(asset) { add(.asset, $0, id) }
        }

        var ids = Set<String>()
        var bySeq: [Int: [PlanLayer]] = [:]
        var byZ: [Int: [PlanLayer]] = [:]
        var prev: PlanLayer?
        for l in plan.layers {
            if !ids.insert(l.id).inserted { add(.duplicateId, "duplicate layer id", l.id) }
            if let p = prev, compareLayers(p, l) > 0 { add(.order, "layers must be sorted by (z, t0, id)", l.id) }
            prev = l
            if !(l.t0 < l.t1) || l.t0 < 0 || l.t1 > plan.durUs { add(.range, "needs 0 ≤ t0 < t1 ≤ durUs", l.id) }
            if !onGrid(l.t0) || !onGrid(l.t1) { add(.offGrid, "layer edges must lie on the gridFps grid", l.id) }
            if l.z < 0 || l.z >= 40000 { add(.zBand, "z outside the four bands", l.id) }
            if l.kind == .sprite && l.z >= 0 && l.z < textBand {
                add(.zBand, "sprite layers belong to the text or subtitle bands", l.id)
            }
            if (l.kind == .media || l.kind == .image) && l.z >= textBand && l.z < 40000 {
                add(.zBand, "media and image layers belong to the video or overlay bands", l.id)
            }
            byZ[l.z, default: []].append(l)

            let assetKind = l.asset.flatMap { plan.assets[$0]?.kind }
            switch l.kind {
            case .media:
                if assetKind != .video { add(.asset, "media layers need a video asset", l.id) }
                if let s = l.seq, s >= 0 {
                    bySeq[s, default: []].append(l)
                } else {
                    add(.seq, "media layers need seq ≥ 0", l.id)
                }
                checkMap(l.map, l.t0, l.t1, onGrid, { add(.map, $0, l.id) }, { add(.offGrid, $0, l.id) })
            case .image:
                if assetKind != .image { add(.asset, "image layers need an image asset", l.id) }
                if l.seq != nil { add(.seq, "only media layers carry seq", l.id) }
            case .sprite:
                if assetKind != .sprite { add(.asset, "sprite layers need a sprite asset", l.id) }
                if l.seq != nil { add(.seq, "only media layers carry seq", l.id) }
            case .solid:
                if l.color == nil { add(.value, "solid layers need a color", l.id) }
                if l.seq != nil { add(.seq, "only media layers carry seq", l.id) }
            }
            if l.kind != .media && (!l.map.isEmpty || l.hold) { add(.map, "map/hold only on media layers", l.id) }
            if let lut = l.fx.lut, plan.assets[lut.asset]?.kind != .lut { add(.asset, "lut asset missing", l.id) }
            checkValues(l) { add(.value, $0, l.id) }
            for (channel, keys) in l.anim.sorted(by: { PlanIds.less($0.key, $1.key) }) {
                if !PlanChannels.all.contains(channel) { add(.anim, "unknown channel \(channel)", l.id) }
                if !sortedUnique(keys) { add(.anim, "keys of \(channel) must be sorted and unique", l.id) }
                if keys.isEmpty { add(.anim, "channel \(channel) has no keys", l.id) }
                if let range = channelRange(channel), keys.contains(where: { !($0.v >= range.0 && $0.v <= range.1) }) {
                    add(.value, "values of \(channel) outside [\(range.0), \(range.1)]", l.id)
                }
            }
            if l.anim[PlanChannels.reveal] != nil {
                let ok = l.kind == .sprite && l.asset.flatMap { plan.assets[$0]?.reveal } == true
                if !ok { add(.anim, "reveal only on sprites whose asset has reveal: true", l.id) }
            }
            for m in l.cmasks {
                if !(m.w >= 0 && m.h >= 0 && m.feather >= 0) { add(.value, "canvas mask w, h and feather must be ≥ 0", l.id) }
                for (channel, keys) in m.anim where !PlanChannels.canvasMask.contains(channel) || !sortedUnique(keys) {
                    add(.anim, "invalid canvas-mask channel \(channel)", l.id)
                }
            }
        }

        // Packing slots never overlap (CORE-36).
        for seq in bySeq.keys.sorted() {
            let sorted = bySeq[seq]!.enumerated().sorted {
                $0.element.t0 != $1.element.t0 ? $0.element.t0 < $1.element.t0 : $0.offset < $1.offset
            }.map(\.element)
            for i in 1..<max(1, sorted.count) where sorted[i].t0 < sorted[i - 1].t1 {
                add(.seq, "overlaps \(sorted[i - 1].id) in seq \(seq)", sorted[i].id)
            }
        }
        // Within one z, at most two layers at once (lowered transition windows).
        for z in byZ.keys.sorted() {
            var events: [(t: Int64, d: Int, id: String)] = []
            for l in byZ[z]! {
                events.append((l.t0, 1, l.id))
                events.append((l.t1, -1, l.id))
            }
            events = events.enumerated().sorted { a, b in
                if a.element.t != b.element.t { return a.element.t < b.element.t }
                if a.element.d != b.element.d { return a.element.d < b.element.d }
                return a.offset < b.offset
            }.map(\.element)
            var active = 0
            for e in events {
                active += e.d
                if active > 2 {
                    add(.zBand, "more than two layers overlap within one z", e.id)
                    break
                }
            }
        }

        // Audio.
        var audioIds = Set<String>()
        var prevA: AudioSeg?
        for a in plan.audio {
            if !audioIds.insert(a.id).inserted { add(.duplicateId, "duplicate audio id", a.id) }
            if let p = prevA, p.t0 > a.t0 || (p.t0 == a.t0 && PlanIds.less(a.id, p.id)) {
                add(.order, "audio must be sorted by (t0, id)", a.id)
            }
            prevA = a
            let kind = plan.assets[a.asset]?.kind
            if kind != .audio && kind != .video { add(.asset, "audio needs an audio or video asset", a.id) }
            if !(a.t0 < a.t1) || a.t0 < 0 || a.t1 > plan.durUs { add(.range, "needs 0 ≤ t0 < t1 ≤ durUs", a.id) }
            if !onGrid(a.t0) || !onGrid(a.t1) { add(.offGrid, "audio edges must lie on the gridFps grid", a.id) }
            checkMap(a.map, a.t0, a.t1, onGrid, { add(.map, $0, a.id) }, { add(.offGrid, $0, a.id) })
            if a.stream < 0 { add(.value, "stream must be ≥ 0", a.id) }
            if a.gain.isEmpty { add(.gain, "gain needs at least one key", a.id) }
            if a.gain.contains(where: { $0.v < 0 || $0.v > 2 }) { add(.gain, "gain values must be in [0, 2]", a.id) }
            if !sortedUnique(a.gain) { add(.gain, "gain keys must be sorted and unique", a.id) }
        }
        return out
    }

    /// Layer draw-order comparison (z, t0, id).
    static func compareLayers(_ a: PlanLayer, _ b: PlanLayer) -> Int {
        if a.z != b.z { return a.z < b.z ? -1 : 1 }
        if a.t0 != b.t0 { return a.t0 < b.t0 ? -1 : 1 }
        if a.id == b.id { return 0 }
        return PlanIds.less(a.id, b.id) ? -1 : 1
    }

    private static func channelRange(_ channel: String) -> (Double, Double)? {
        if channel == PlanChannels.xfOp || channel == "mask.op" || channel == "mask.feather" || channel.hasPrefix("detail.") {
            return (0, 1)
        }
        if channel.hasPrefix("adj.") { return (-1, 1) }
        if channel == PlanChannels.xfS || channel == "mask.w" || channel == "mask.h" || channel == PlanChannels.reveal {
            return (0, Double.greatestFiniteMagnitude)
        }
        return nil
    }

    private static func checkAsset(_ a: PlanAsset, _ bad: (String) -> Void) {
        func uriOk(_ u: String) -> Bool { u.hasPrefix("file://") || u.hasPrefix("content://") }
        if !uriOk(a.uri) { bad("uri must be file:// or content:// (never http)") }
        if let proxy = a.proxyUri, !uriOk(proxy) { bad("proxyUri must be file:// or content://") }
        if let rot = a.rot, ![0, 90, 180, 270].contains(rot) { bad("rot must be 0, 90, 180 or 270") }
        if (a.w.map { $0 < 1 } ?? false) || (a.h.map { $0 < 1 } ?? false) { bad("w and h must be ≥ 1") }
        if let d = a.durUs, d < 0 { bad("durUs must be ≥ 0") }
        switch a.kind {
        case .lut:
            if a.n == nil || a.n! < 2 || a.n! > 65 { bad("lut assets need n in 2…65") }
        case .sprite:
            if a.sw == nil || a.sh == nil || a.sw! < 1 || a.sh! < 1 { bad("sprite assets need sw and sh ≥ 1") }
            if a.sscale == nil || !(a.sscale! > 0) { bad("sprite assets need sscale > 0") }
        case .video, .audio, .image:
            break
        }
    }

    private static func sortedUnique(_ keys: [AnimKey]) -> Bool {
        for i in 1..<max(1, keys.count) where keys[i].tUs <= keys[i - 1].tUs { return false }
        return true
    }

    private static func checkMap(
        _ map: [MapSegment], _ t0: Int64, _ t1: Int64, _ onGrid: (Int64) -> Bool,
        _ bad: (String) -> Void, _ offGrid: (String) -> Void
    ) {
        guard let first = map.first, let last = map.last else {
            bad("map must cover [t0, t1)")
            return
        }
        if first.t0 != t0 || last.t1 != t1 { bad("map must start at t0 and end at t1") }
        for (i, s) in map.enumerated() {
            if i > 0 && s.t0 != map[i - 1].t1 { bad("map segments must be contiguous") }
            if !onGrid(s.t0) || !onGrid(s.t1) { offGrid("map breakpoints must lie on the gridFps grid") }
            let r = s.rate
            if r < minRate - rateEps || r > maxRate + rateEps { bad("segment rate \(r) outside [0.1, 10]") }
        }
    }

    private static func checkValues(_ l: PlanLayer, _ bad: (String) -> Void) {
        func unit(_ v: Double) -> Bool { v >= 0 && v <= 1 }
        if !unit(l.xf.op) { bad("xf.op outside [0, 1]") }
        if let adj = l.fx.adj, adj.values.contains(where: { $0 < -1 || $0 > 1 }) { bad("adj values outside [-1, 1]") }
        if let d = l.fx.detail, !(unit(d.sharpen) && unit(d.blur) && unit(d.vignette)) { bad("detail values outside [0, 1]") }
        if let lut = l.fx.lut, !unit(lut.i) { bad("lut.i outside [0, 1]") }
        if let ch = l.fx.chroma, !(unit(ch.sim) && unit(ch.smooth) && unit(ch.spill)) { bad("chroma values outside [0, 1]") }
        if let m = l.fx.mask, !(unit(m.feather) && unit(m.op) && m.corner >= 0 && m.corner <= 0.5) { bad("mask values out of range") }
        if let b = l.base, !(b.w.isFinite && b.h.isFinite && b.w > 0 && b.h > 0) { bad("base must be positive") }
        if !(l.xf.s.isFinite && l.xf.r.isFinite && (l.xf.cx ?? 0).isFinite && (l.xf.cy ?? 0).isFinite) { bad("xf values must be finite") }
        let c = l.crop
        if !(unit(c.l) && unit(c.t) && unit(c.r) && unit(c.b) && c.l < c.r && c.t < c.b) {
            bad("crop must satisfy 0 ≤ l < r ≤ 1, 0 ≤ t < b ≤ 1")
        }
    }
}
