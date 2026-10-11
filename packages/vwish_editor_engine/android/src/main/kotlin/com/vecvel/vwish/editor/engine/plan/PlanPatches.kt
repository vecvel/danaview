// OWNER: AND-08
//
// Patch application and classification (ARCH §11.2 Patch, "Patch classification"; mirrors core's
// `plan_diff.dart`, CORE-32). A patch applies atomically and only when `from` equals the engine's
// current revision (else `planOutOfSync`): removals first, then upserts that replace whole objects
// by id; layers re-sorted by (z, t0, id) and audio by (t0, id). Structural = layer set change, a
// layer's kind / z / t / asset / map / hold / seq, any audio change except `gain`, canvas, durUs,
// the asset set or an asset entry. Param-only = xf, crop, base, fx, anim, cmasks, color and audio
// gain: those swap the ParamSnapshot and redraw. Shared vectors:
// packages/vwish_editor_core/test/fixtures/render_plans/classification.json.

package com.vecvel.vwish.editor.engine.plan

/** The patch does not start at the plan's revision (`planOutOfSync`). */
class PlanOutOfSyncException(val planRev: Long, val patchFrom: Long) :
    Exception("patch from $patchFrom does not match plan rev $planRev")

/** How an engine applies a patch. */
enum class PatchClass {
    /** Rebuild the platform composition and restore playhead and play state. */
    STRUCTURAL,

    /** Swap the ParamSnapshot and redraw. */
    PARAM_ONLY,
}

/** Patch application and classification. */
object PlanPatches {
    /** [plan] with [patch] applied; throws [PlanOutOfSyncException] when `patch.from != plan.rev`. */
    fun apply(plan: RenderPlan, patch: RenderPlanPatch): RenderPlan {
        if (patch.from != plan.rev) throw PlanOutOfSyncException(plan.rev, patch.from)
        val assets = LinkedHashMap(plan.assets)
        for (id in patch.assetRemovals) assets.remove(id)
        assets.putAll(patch.assetUpserts)

        val layers = LinkedHashMap<String, PlanLayer>()
        for (l in plan.layers) layers[l.id] = l
        for (id in patch.layers.remove) layers.remove(id)
        for (l in patch.layers.upsert) layers[l.id] = l
        val sortedLayers = layers.values.sortedWith(PlanValidator::compareLayers)

        val audio = LinkedHashMap<String, AudioSeg>()
        for (a in plan.audio) audio[a.id] = a
        for (id in patch.audio.remove) audio.remove(id)
        for (a in patch.audio.upsert) audio[a.id] = a
        val sortedAudio = audio.values.sortedWith(PlanValidator::compareAudio)

        return plan.copy(
            rev = patch.to,
            canvas = patch.canvas ?: plan.canvas,
            durUs = patch.durUs ?: plan.durUs,
            assets = assets,
            layers = sortedLayers,
            audio = sortedAudio,
        )
    }

    /** The classification of [patch] applied to [from]. An empty patch is param-only. */
    fun classify(from: RenderPlan, patch: RenderPlanPatch): PatchClass =
        if (isStructural(from, patch)) PatchClass.STRUCTURAL else PatchClass.PARAM_ONLY

    /** Whether [patch] applied to [from] is structural (file header). */
    fun isStructural(from: RenderPlan, patch: RenderPlanPatch): Boolean {
        if (patch.canvas != null && patch.canvas != from.canvas) return true
        if (patch.durUs != null && patch.durUs != from.durUs) return true
        if (patch.assetRemovals.any { from.assets.containsKey(it) }) return true
        if (patch.assetUpserts.any { (id, a) -> from.assets[id] != a }) return true
        if (patch.layers.remove.isNotEmpty() && from.layers.any { it.id in patch.layers.remove }) return true
        if (patch.audio.remove.isNotEmpty() && from.audio.any { it.id in patch.audio.remove }) return true
        if (patch.layers.upsert.isNotEmpty()) {
            val byId = from.layers.associateBy { it.id }
            for (l in patch.layers.upsert) {
                val old = byId[l.id] ?: return true
                if (layerStructureChanged(old, l)) return true
            }
        }
        if (patch.audio.upsert.isNotEmpty()) {
            val byId = from.audio.associateBy { it.id }
            for (a in patch.audio.upsert) {
                val old = byId[a.id] ?: return true
                if (audioStructureChanged(old, a)) return true
            }
        }
        return false
    }

    /** Whether [a] → [b] changes a structural field of a layer (kind, z, t, asset, map, hold, seq). */
    fun layerStructureChanged(a: PlanLayer, b: PlanLayer): Boolean =
        a.kind != b.kind || a.z != b.z || a.t0 != b.t0 || a.t1 != b.t1 || a.asset != b.asset ||
            a.hold != b.hold || a.seq != b.seq || a.map != b.map

    /** Whether [a] → [b] changes anything of an audio segment but its gain. */
    fun audioStructureChanged(a: AudioSeg, b: AudioSeg): Boolean =
        a.asset != b.asset || a.stream != b.stream || a.t0 != b.t0 || a.t1 != b.t1 || a.pitch != b.pitch || a.map != b.map

    /**
     * [layer] with the param fields of [override] merged over it (ARCH §11.2 Transient: last write
     * wins; an empty `fx`, `anim` or `cmasks` clears the layer's value). Timing never changes.
     */
    fun mergeTransient(layer: PlanLayer, override: TransientLayer): PlanLayer = layer.copy(
        xf = override.xf ?: layer.xf,
        crop = override.crop ?: layer.crop,
        base = override.base ?: layer.base,
        fx = override.fx ?: layer.fx,
        anim = override.anim ?: layer.anim,
        cmasks = override.cmasks ?: layer.cmasks,
    )
}
