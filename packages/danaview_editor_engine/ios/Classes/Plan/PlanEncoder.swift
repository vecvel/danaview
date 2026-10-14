// OWNER: IOS-08
//
// Canonical encoding of RenderPlan / Patch / Transient v1, byte-identical to
// `PlanJson.encode*Bytes` of packages/danaview_editor_core/lib/src/plan/plan_json.dart (CORE-29):
// fixed key order per object (the order of the ARCH §11.2 tables), `assets` ids and `anim` channel
// names sorted, default-valued optional keys omitted, integral doubles written as integers, other
// doubles in Dart's shortest round-trip form, colours `"#RRGGBBAA"` (chroma key `"#RRGGBB"`).
// The engine only needs it for the contract round trip and diagnostics; plans flow Dart → native.

import Foundation

enum PlanEncoder {
    // MARK: Documents

    static func encode(_ plan: RenderPlan) -> Data { PlanJSONWriter.data(json(plan)) }
    static func encode(_ patch: RenderPlanPatch) -> Data { PlanJSONWriter.data(json(patch)) }
    static func encode(_ transient: PlanTransient) -> Data { PlanJSONWriter.data(json(transient)) }

    static func json(_ plan: RenderPlan) -> JSONOut {
        var o: [(String, JSONOut)] = [
            ("v", .int(Int64(plan.v))),
            ("rev", .int(plan.rev)),
            ("target", .string(plan.target.rawValue)),
            ("canvas", canvas(plan.canvas)),
            ("durUs", .int(plan.durUs)),
            ("assets", assets(plan.assets)),
            ("layers", .array(plan.layers.map(layer))),
            ("audio", .array(plan.audio.map(audio))),
        ]
        if let req = plan.req { o.append(("req", requirements(req))) }
        return .object(o)
    }

    static func json(_ p: RenderPlanPatch) -> JSONOut {
        var o: [(String, JSONOut)] = [("v", .int(Int64(p.v))), ("from", .int(p.from)), ("to", .int(p.to))]
        if let c = p.canvas { o.append(("canvas", canvas(c))) }
        if let d = p.durUs { o.append(("durUs", .int(d))) }
        if !p.assetUpserts.isEmpty || !p.assetRemovals.isEmpty {
            var a: [(String, JSONOut)] = []
            if !p.assetUpserts.isEmpty { a.append(("upsert", assets(p.assetUpserts))) }
            if !p.assetRemovals.isEmpty { a.append(("remove", .array(p.assetRemovals.map { .string($0) }))) }
            o.append(("assets", .object(a)))
        }
        if !p.layers.isEmpty {
            var l: [(String, JSONOut)] = []
            if !p.layers.upsert.isEmpty { l.append(("upsert", .array(p.layers.upsert.map(layer)))) }
            if !p.layers.remove.isEmpty { l.append(("remove", .array(p.layers.remove.map { .string($0) }))) }
            o.append(("layers", .object(l)))
        }
        if !p.audio.isEmpty {
            var a: [(String, JSONOut)] = []
            if !p.audio.upsert.isEmpty { a.append(("upsert", .array(p.audio.upsert.map(audio)))) }
            if !p.audio.remove.isEmpty { a.append(("remove", .array(p.audio.remove.map { .string($0) }))) }
            o.append(("audio", .object(a)))
        }
        return .object(o)
    }

    static func json(_ t: PlanTransient) -> JSONOut {
        .object([
            ("v", .int(Int64(t.v))),
            ("item", .string(t.item)),
            ("layers", .array(t.layers.map { l in
                var o: [(String, JSONOut)] = [("id", .string(l.id))]
                if let xf = l.xf { o.append(("xf", transform(xf))) }
                if let c = l.crop { o.append(("crop", crop(c))) }
                if let b = l.base { o.append(("base", .array([.num(b.w), .num(b.h)]))) }
                if let fx = l.fx { o.append(("fx", effects(fx))) }
                if let a = l.anim { o.append(("anim", anim(a))) }
                if let m = l.cmasks { o.append(("cmasks", .array(m.map(canvasMask)))) }
                return .object(o)
            })),
        ])
    }

    // MARK: Pieces

    static func encodeColor(_ argb: UInt32) -> String {
        let rgb = argb & 0xFF_FFFF
        let a = (argb >> 24) & 0xFF
        return "#" + hex(rgb, 6) + hex(a, 2)
    }

    private static func hex(_ v: UInt32, _ width: Int) -> String {
        let s = String(v, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }

    private static func canvas(_ c: PlanCanvas) -> JSONOut {
        var o: [(String, JSONOut)] = [("w", .int(Int64(c.w))), ("h", .int(Int64(c.h))), ("fps", .int(Int64(c.fps)))]
        if c.gridFps != c.fps { o.append(("gridFps", .int(Int64(c.gridFps)))) }
        o.append(("bg", .string(encodeColor(c.bg))))
        return .object(o)
    }

    private static func assets(_ assets: [String: PlanAsset]) -> JSONOut {
        let ids = assets.keys.sorted(by: PlanIds.less)
        return .object(ids.map { ($0, asset(assets[$0]!)) })
    }

    private static func asset(_ a: PlanAsset) -> JSONOut {
        var o: [(String, JSONOut)] = [("kind", .string(a.kind.rawValue)), ("uri", .string(a.uri))]
        if let b = a.bookmark { o.append(("bookmark", .string(b))) }
        if !a.fp.isEmpty { o.append(("fp", .string(a.fp))) }
        if let p = a.proxyUri { o.append(("proxyUri", .string(p))) }
        if let w = a.w { o.append(("w", .int(Int64(w)))) }
        if let h = a.h { o.append(("h", .int(Int64(h)))) }
        if let r = a.rot { o.append(("rot", .int(Int64(r)))) }
        if let d = a.durUs { o.append(("durUs", .int(d))) }
        if a.transfer != .sdr { o.append(("transfer", .string(a.transfer.rawValue))) }
        if let h = a.hasAudio { o.append(("hasAudio", .bool(h))) }
        if let n = a.n { o.append(("n", .int(Int64(n)))) }
        if let sw = a.sw { o.append(("sw", .int(Int64(sw)))) }
        if let sh = a.sh { o.append(("sh", .int(Int64(sh)))) }
        if let s = a.sscale { o.append(("sscale", .num(s))) }
        if let r = a.reveal { o.append(("reveal", .bool(r))) }
        return .object(o)
    }

    private static func layer(_ l: PlanLayer) -> JSONOut {
        var o: [(String, JSONOut)] = [("id", .string(l.id)), ("z", .int(Int64(l.z)))]
        if let s = l.seq { o.append(("seq", .int(Int64(s)))) }
        o.append(("t", .array([.int(l.t0), .int(l.t1)])))
        o.append(("kind", .string(l.kind.rawValue)))
        if let a = l.asset { o.append(("asset", .string(a))) }
        if !l.map.isEmpty { o.append(("map", map(l.map))) }
        if l.hold { o.append(("hold", .bool(true))) }
        if let c = l.color { o.append(("color", .string(encodeColor(c)))) }
        if let b = l.base { o.append(("base", .array([.num(b.w), .num(b.h)]))) }
        if !l.crop.isFull { o.append(("crop", crop(l.crop))) }
        if !l.xf.isIdentity { o.append(("xf", transform(l.xf))) }
        if !l.fx.isEmpty { o.append(("fx", effects(l.fx))) }
        if !l.anim.isEmpty { o.append(("anim", anim(l.anim))) }
        if !l.cmasks.isEmpty { o.append(("cmasks", .array(l.cmasks.map(canvasMask)))) }
        return .object(o)
    }

    private static func audio(_ a: AudioSeg) -> JSONOut {
        var o: [(String, JSONOut)] = [("id", .string(a.id)), ("asset", .string(a.asset))]
        if a.stream != 0 { o.append(("stream", .int(Int64(a.stream)))) }
        o.append(("t", .array([.int(a.t0), .int(a.t1)])))
        o.append(("map", map(a.map)))
        o.append(("gain", keys(a.gain)))
        if !a.pitch { o.append(("pitch", .bool(false))) }
        return .object(o)
    }

    private static func requirements(_ r: PlanRequirements) -> JSONOut {
        var o: [(String, JSONOut)] = []
        if !r.offline.isEmpty { o.append(("offline", .array(r.offline.map { .string($0) }))) }
        if !r.pendingReverse.isEmpty { o.append(("pendingReverse", .array(r.pendingReverse.map { .string($0) }))) }
        if !r.pendingStill.isEmpty { o.append(("pendingStill", .array(r.pendingStill.map { .string($0) }))) }
        return .object(o)
    }

    private static func map(_ m: [MapSegment]) -> JSONOut {
        .array(m.map { .array([.int($0.t0), .int($0.t1), .int($0.s0), .int($0.s1)]) })
    }

    private static func crop(_ c: PlanCrop) -> JSONOut { .array([.num(c.l), .num(c.t), .num(c.r), .num(c.b)]) }

    private static func transform(_ x: PlanTransform) -> JSONOut {
        var o: [(String, JSONOut)] = []
        if let cx = x.cx { o.append(("cx", .num(cx))) }
        if let cy = x.cy { o.append(("cy", .num(cy))) }
        if x.s != 1 { o.append(("s", .num(x.s))) }
        if x.r != 0 { o.append(("r", .num(x.r))) }
        if x.fx { o.append(("fx", .bool(true))) }
        if x.fy { o.append(("fy", .bool(true))) }
        if x.op != 1 { o.append(("op", .num(x.op))) }
        return .object(o)
    }

    private static func effects(_ f: PlanEffects) -> JSONOut {
        var o: [(String, JSONOut)] = []
        if let adj = f.adj {
            var a: [(String, JSONOut)] = []
            for (i, n) in PlanAdjust.names.enumerated() where adj.values[i] != 0 { a.append((n, .num(adj.values[i]))) }
            o.append(("adj", .object(a)))
        }
        if let d = f.detail {
            var a: [(String, JSONOut)] = []
            if d.sharpen != 0 { a.append(("sharpen", .num(d.sharpen))) }
            if d.blur != 0 { a.append(("blur", .num(d.blur))) }
            if d.vignette != 0 { a.append(("vignette", .num(d.vignette))) }
            o.append(("detail", .object(a)))
        }
        if let l = f.lut { o.append(("lut", .object([("asset", .string(l.asset)), ("i", .num(l.i))]))) }
        if let c = f.chroma {
            o.append((
                "chroma",
                .object([
                    ("key", .string("#" + hex(c.key & 0xFF_FFFF, 6))),
                    ("sim", .num(c.sim)),
                    ("smooth", .num(c.smooth)),
                    ("spill", .num(c.spill)),
                ])
            ))
        }
        if let m = f.mask {
            var a: [(String, JSONOut)] = [
                ("shape", .string(m.shape.rawValue)),
                ("cx", .num(m.cx)), ("cy", .num(m.cy)), ("w", .num(m.w)), ("h", .num(m.h)),
            ]
            if m.r != 0 { a.append(("r", .num(m.r))) }
            if m.corner != 0 { a.append(("corner", .num(m.corner))) }
            if m.feather != 0 { a.append(("feather", .num(m.feather))) }
            if m.op != 1 { a.append(("op", .num(m.op))) }
            if m.inv { a.append(("inv", .bool(true))) }
            o.append(("mask", .object(a)))
        }
        return .object(o)
    }

    private static func anim(_ a: [String: [AnimKey]]) -> JSONOut {
        .object(a.keys.sorted(by: PlanIds.less).map { ($0, keys(a[$0]!)) })
    }

    private static func keys(_ k: [AnimKey]) -> JSONOut {
        .array(k.map { .array([.int($0.tUs), .num($0.v)]) })
    }

    private static func canvasMask(_ m: CanvasMask) -> JSONOut {
        var o: [(String, JSONOut)] = [("cx", .num(m.cx)), ("cy", .num(m.cy)), ("w", .num(m.w)), ("h", .num(m.h))]
        if m.r != 0 { o.append(("r", .num(m.r))) }
        if m.feather != 0 { o.append(("feather", .num(m.feather))) }
        if m.inv { o.append(("inv", .bool(true))) }
        if !m.anim.isEmpty { o.append(("anim", anim(m.anim))) }
        return .object(o)
    }
}
