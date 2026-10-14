// OWNER: IOS-08
//
// Patch application and classification (ARCH §11.2 "Patch", "Patch classification"), mirroring
// packages/danaview_editor_core/lib/src/plan/plan_diff.dart (CORE-32). Shared vectors:
// packages/danaview_editor_core/test/fixtures/render_plans/classification.json.
//
// - A patch applies only when `from` equals the engine's current `rev` (`planOutOfSync`
//   otherwise): removals, then upserts (whole objects by id), layers re-sorted by (z, t0, id) and
//   audio by (t0, id). `req` is informational and kept.
// - Structural: a layer set change, a layer's `kind`, `z`, `t`, `asset`, `map`, `hold`, `seq`;
//   any audio change except `gain`; canvas, `durUs`, the asset set or an asset entry.
//   Param-only: `xf`, `crop`, `base`, `fx`, `anim`, `cmasks`, `color` and audio `gain`
//   (snapshot swap + tap envelope swap, no rebuild).

import Foundation

/// How the engine applies a patch.
enum PatchClass: Equatable {
    /// Rebuild the composition and restore playhead and play state.
    case structural
    /// Swap the `ParamSnapshot` (and gain-tap envelopes) and redraw.
    case paramOnly
}

/// The patch does not start at the engine's revision (`planOutOfSync`).
struct PlanOutOfSync: Error, Equatable {
    let planRev: Int64
    let patchFrom: Int64
}

enum PlanPatching {
    /// [plan] with [patch] applied. Throws `PlanOutOfSync` when `patch.from != plan.rev`.
    static func apply(_ patch: RenderPlanPatch, to plan: RenderPlan) throws -> RenderPlan {
        guard patch.from == plan.rev else { throw PlanOutOfSync(planRev: plan.rev, patchFrom: patch.from) }
        var assets = plan.assets
        for id in patch.assetRemovals { assets.removeValue(forKey: id) }
        for (id, a) in patch.assetUpserts { assets[id] = a }

        var layers = plan.layers
        if !patch.layers.isEmpty {
            let removed = Set(patch.layers.remove)
            let upserted = Dictionary(patch.layers.upsert.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            layers = layers.filter { !removed.contains($0.id) && upserted[$0.id] == nil }
            layers.append(contentsOf: upserted.values)
            layers.sort(by: PlanLayer.drawOrder)
        }
        var audio = plan.audio
        if !patch.audio.isEmpty {
            let removed = Set(patch.audio.remove)
            let upserted = Dictionary(patch.audio.upsert.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            audio = audio.filter { !removed.contains($0.id) && upserted[$0.id] == nil }
            audio.append(contentsOf: upserted.values)
            audio.sort(by: AudioSeg.order)
        }
        return RenderPlan(
            v: plan.v, rev: patch.to, target: plan.target, canvas: patch.canvas ?? plan.canvas,
            durUs: patch.durUs ?? plan.durUs, assets: assets, layers: layers, audio: audio, req: plan.req)
    }

    /// The classification of [patch] applied to [from]. An empty patch is param-only.
    static func classify(_ patch: RenderPlanPatch, from: RenderPlan) -> PatchClass {
        isStructural(patch, from: from) ? .structural : .paramOnly
    }

    static func isStructural(_ patch: RenderPlanPatch, from: RenderPlan) -> Bool {
        if let c = patch.canvas, c != from.canvas { return true }
        if let d = patch.durUs, d != from.durUs { return true }
        if patch.assetRemovals.contains(where: { from.assets[$0] != nil }) { return true }
        for (id, a) in patch.assetUpserts where from.assets[id] != a { return true }
        if !patch.layers.remove.isEmpty {
            let ids = Set(from.layers.map(\.id))
            if patch.layers.remove.contains(where: ids.contains) { return true }
        }
        if !patch.audio.remove.isEmpty {
            let ids = Set(from.audio.map(\.id))
            if patch.audio.remove.contains(where: ids.contains) { return true }
        }
        if !patch.layers.upsert.isEmpty {
            let old = Dictionary(from.layers.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            for l in patch.layers.upsert {
                guard let o = old[l.id], !layerStructureChanged(o, l) else { return true }
            }
        }
        if !patch.audio.upsert.isEmpty {
            let old = Dictionary(from.audio.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            for s in patch.audio.upsert {
                guard let o = old[s.id], !audioStructureChanged(o, s) else { return true }
            }
        }
        return false
    }

    /// Whether [a] → [b] changes a structural field of a layer.
    static func layerStructureChanged(_ a: PlanLayer, _ b: PlanLayer) -> Bool {
        a.kind != b.kind || a.z != b.z || a.t0 != b.t0 || a.t1 != b.t1 || a.asset != b.asset
            || a.hold != b.hold || a.seq != b.seq || a.map != b.map
    }

    /// Whether [a] → [b] changes anything of an audio segment but its `gain`.
    static func audioStructureChanged(_ a: AudioSeg, _ b: AudioSeg) -> Bool {
        a.asset != b.asset || a.stream != b.stream || a.t0 != b.t0 || a.t1 != b.t1 || a.pitch != b.pitch || a.map != b.map
    }

    /// Ids of the layers a patch touches (their transients are dropped, ARCH §11.2).
    static func touchedLayerIds(_ patch: RenderPlanPatch) -> Set<String> {
        Set(patch.layers.upsert.map(\.id)).union(patch.layers.remove)
    }
}
