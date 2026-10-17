// OWNER: IOS-08
//
// ParamSnapshot (ARCH §11.2 "Patch classification", §13.2 'Compositor'): the immutable per-layer
// parameters the compositor (IOS-10) renders from. It holds the current plan with the active
// transients merged over its layers and evaluates every layer at a frame: layer activity, the
// animated channels and `reveal` are evaluated at `timeOfFrame(k)` of the OUTPUT rate (D-35), never
// at a raw platform time.
//
// - Param-only patches and transients produce a new snapshot that `ParamSnapshotStore` swaps
//   atomically; a render takes one reference and never locks while it renders.
// - Transients (`setTransient`) carry param fields only, merged field by field over the current
//   layer (last write wins; an empty `fx`/`anim`/`cmasks` clears the layer's value). They are dropped
//   by the next plan or patch touching that layer, or by `clearTransient(item)`. Timing fields are
//   not part of a transient, so they never change which layers are active.

import CoreGraphics
import Foundation
import os

/// One layer evaluated at one frame (everything the compositor needs, no keyframes left).
struct EvaluatedLayer: Equatable {
    let id: String
    let kind: PlanLayerKind
    let asset: String?
    /// Media layers: the CORE-36 slot (composition video track).
    let seq: Int?
    /// Media layers: the unbiased source time s(t) in µs (ARCH §11.5; `hold` → `map[0].s0`).
    /// The displayed frame is the sample with the greatest PTS ≤ s + 500 µs (D-04).
    let sourceUs: Double?
    /// ARGB (solids).
    let color: UInt32?
    /// Size in canvas px of the cropped source after fit (defaults to the canvas).
    let base: PlanSize
    let crop: PlanCrop
    let cx: Double
    let cy: Double
    let scale: Double
    let rotation: Double
    let flipX: Bool
    let flipY: Bool
    let opacity: Double
    /// The eight adjustments in `PlanAdjust.names` order.
    let adjust: [Double]
    let detail: PlanDetail
    let lut: PlanLut?
    let chroma: PlanChroma?
    /// The item mask with its animated fields evaluated.
    let mask: PlanMask?
    /// Canvas masks with their animated fields evaluated (`anim` emptied).
    let cmasks: [CanvasMask]
    /// Sprites: glyphs shown (`floor(reveal(t))`), nil when not animated (everything shown).
    let reveal: Int?

    /// ARCH §11.6 placement matrix M = T(cx, cy)·R(r° cw, y down)·S(s·(fx ? −1 : 1), s·(fy ? −1 : 1))·
    /// T(−base.w/2, −base.h/2), mapping base-local px to canvas px (`CGAffineTransform` convention:
    /// x' = a·x + c·y + tx, y' = b·x + d·y + ty).
    var placement: CGAffineTransform {
        let rad = rotation * Double.pi / 180
        let cosR = cos(rad)
        let sinR = sin(rad)
        let sx = scale * (flipX ? -1 : 1)
        let sy = scale * (flipY ? -1 : 1)
        let a = cosR * sx
        let b = sinR * sx
        let c = -sinR * sy
        let d = cosR * sy
        let tx = cx - a * base.w / 2 - c * base.h / 2
        let ty = cy - b * base.w / 2 - d * base.h / 2
        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
}

/// Immutable render parameters of one plan revision plus its transients.
final class ParamSnapshot {
    /// The plan as last set or patched (without transients).
    let plan: RenderPlan
    /// Layers with transients merged, bottom → top.
    let layers: [PlanLayer]
    /// Active transients by item, in application order.
    let transients: [(item: String, transient: PlanTransient)]
    private let indexById: [String: Int]

    init(plan: RenderPlan) {
        self.plan = plan
        self.layers = plan.layers
        self.transients = []
        self.indexById = Self.index(plan.layers)
    }

    private init(plan: RenderPlan, transients: [(item: String, transient: PlanTransient)]) {
        self.plan = plan
        self.transients = transients
        var merged = plan.layers
        let index = Self.index(plan.layers)
        for (_, t) in transients {
            for tl in t.layers {
                guard let i = index[tl.id] else { continue }
                Self.merge(tl, into: &merged[i])
            }
        }
        self.layers = merged
        self.indexById = index
    }

    private static func index(_ layers: [PlanLayer]) -> [String: Int] {
        var out: [String: Int] = [:]
        out.reserveCapacity(layers.count)
        for (i, l) in layers.enumerated() { out[l.id] = i }
        return out
    }

    private static func merge(_ t: TransientLayer, into l: inout PlanLayer) {
        if let xf = t.xf { l.xf = xf }
        if let crop = t.crop { l.crop = crop }
        if let base = t.base { l.base = base }
        if let fx = t.fx { l.fx = fx }
        if let anim = t.anim { l.anim = anim }
        if let cmasks = t.cmasks { l.cmasks = cmasks }
    }

    // MARK: Derivation

    /// A snapshot with [transient] merged (replacing an earlier transient of the same item).
    func applying(_ transient: PlanTransient) -> ParamSnapshot {
        var list = transients.filter { $0.item != transient.item }
        list.append((transient.item, transient))
        return ParamSnapshot(plan: plan, transients: list)
    }

    /// A snapshot without [item]'s transient.
    func clearingTransient(item: String) -> ParamSnapshot {
        guard transients.contains(where: { $0.item == item }) else { return self }
        return ParamSnapshot(plan: plan, transients: transients.filter { $0.item != item })
    }

    /// A snapshot of [newPlan]. Transients touching [touchedLayerIds] are dropped (nil: a full plan
    /// drops every transient); the others stay merged.
    func replacingPlan(_ newPlan: RenderPlan, touchedLayerIds: Set<String>?) -> ParamSnapshot {
        guard let touched = touchedLayerIds else { return ParamSnapshot(plan: newPlan) }
        let kept = transients.filter { entry in !entry.transient.layers.contains { touched.contains($0.id) } }
        return ParamSnapshot(plan: newPlan, transients: kept)
    }

    // MARK: Lookup

    /// The merged layer with [id].
    func layer(_ id: String) -> PlanLayer? { indexById[id].map { layers[$0] } }

    /// Plan time of output frame k (`timeOfFrame(k)` at `canvas.fps`).
    func timeOfFrame(_ k: Int64) -> Int64 { plan.canvas.outputGrid.timeOfFrame(k) }

    /// The layers active at output frame [k], bottom → top.
    func activeLayers(atFrame k: Int64) -> [PlanLayer] {
        let t = timeOfFrame(k)
        return layers.filter { $0.covers(t) }
    }

    /// Every active layer evaluated at output frame [k], bottom → top.
    func evaluate(atFrame k: Int64) -> [EvaluatedLayer] {
        let t = timeOfFrame(k)
        return layers.compactMap { $0.covers(t) ? evaluate($0, atUs: t) : nil }
    }

    /// [layer] evaluated at plan time [t] (a `timeOfFrame` value).
    func evaluate(_ layer: PlanLayer, atUs t: Int64) -> EvaluatedLayer {
        let a = layer.anim
        func ch(_ name: String, _ fallback: Double) -> Double { Keyframes.channel(a, name, at: t, fallback: fallback) }
        let canvas = plan.canvas
        let staticAdj = layer.fx.adj ?? PlanAdjust()
        let adjust = PlanAdjust.names.enumerated().map { i, n in ch("adj.\(n)", staticAdj.values[i]) }
        let d = layer.fx.detail ?? PlanDetail()
        let detail = PlanDetail(
            sharpen: ch("detail.sharpen", d.sharpen), blur: ch("detail.blur", d.blur), vignette: ch("detail.vignette", d.vignette))
        var mask = layer.fx.mask
        if var m = mask {
            m.cx = ch("mask.cx", m.cx)
            m.cy = ch("mask.cy", m.cy)
            m.w = ch("mask.w", m.w)
            m.h = ch("mask.h", m.h)
            m.r = ch("mask.r", m.r)
            m.feather = ch("mask.feather", m.feather)
            m.op = ch("mask.op", m.op)
            mask = m
        }
        let cmasks = layer.cmasks.map { m -> CanvasMask in
            var e = m
            e.cx = Keyframes.channel(m.anim, "cx", at: t, fallback: m.cx)
            e.cy = Keyframes.channel(m.anim, "cy", at: t, fallback: m.cy)
            e.w = Keyframes.channel(m.anim, "w", at: t, fallback: m.w)
            e.h = Keyframes.channel(m.anim, "h", at: t, fallback: m.h)
            e.anim = [:]
            return e
        }
        var reveal: Int?
        if let keys = a[PlanChannels.reveal] {
            reveal = Int(Keyframes.evaluate(keys, at: t, fallback: 0).rounded(.down))
        }
        return EvaluatedLayer(
            id: layer.id,
            kind: layer.kind,
            asset: layer.asset,
            seq: layer.seq,
            sourceUs: layer.kind == .media ? Self.sourceTime(layer, at: t) : nil,
            color: layer.color,
            base: layer.base ?? PlanSize(w: Double(canvas.w), h: Double(canvas.h)),
            crop: layer.crop,
            cx: ch(PlanChannels.xfCx, layer.xf.cx ?? Double(canvas.w) / 2),
            cy: ch(PlanChannels.xfCy, layer.xf.cy ?? Double(canvas.h) / 2),
            scale: ch(PlanChannels.xfS, layer.xf.s),
            rotation: ch(PlanChannels.xfR, layer.xf.r),
            flipX: layer.xf.fx,
            flipY: layer.xf.fy,
            opacity: ch(PlanChannels.xfOp, layer.xf.op),
            adjust: adjust,
            detail: detail,
            lut: layer.fx.lut,
            chroma: layer.fx.chroma,
            mask: mask,
            cmasks: cmasks,
            reveal: reveal)
    }

    /// ARCH §11.5: s = s0 + (t − t0)·(s1 − s0)/(t1 − t0) on the containing segment; `hold` → `map[0].s0`.
    static func sourceTime(_ layer: PlanLayer, at t: Int64) -> Double? {
        guard let first = layer.map.first else { return nil }
        if layer.hold { return Double(first.s0) }
        var lo = 0
        var hi = layer.map.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) >> 1
            if layer.map[mid].t0 <= t { lo = mid } else { hi = mid - 1 }
        }
        return layer.map[lo].source(at: t)
    }
}

/// The atomically swapped current snapshot (one per preview session or export). Readers take a
/// reference and render from it without holding the lock.
final class ParamSnapshotStore {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var _snapshot: ParamSnapshot
    private var _generation: UInt64 = 0

    init(_ snapshot: ParamSnapshot) {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        _snapshot = snapshot
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// The current snapshot.
    var current: ParamSnapshot {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return _snapshot
    }

    /// Incremented by every swap (redraw and cancellation bookkeeping).
    var generation: UInt64 {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return _generation
    }

    /// Replaces the snapshot; returns the new generation.
    @discardableResult
    func swap(_ snapshot: ParamSnapshot) -> UInt64 {
        os_unfair_lock_lock(lock)
        let old = _snapshot
        _snapshot = snapshot
        _generation &+= 1
        let g = _generation
        os_unfair_lock_unlock(lock)
        withExtendedLifetime(old) {}
        return g
    }

    /// Atomically derives the next snapshot from the current one.
    @discardableResult
    func update(_ transform: (ParamSnapshot) -> ParamSnapshot) -> ParamSnapshot {
        os_unfair_lock_lock(lock)
        let old = _snapshot
        let next = transform(old)
        _snapshot = next
        _generation &+= 1
        os_unfair_lock_unlock(lock)
        withExtendedLifetime(old) {}
        return next
    }
}
