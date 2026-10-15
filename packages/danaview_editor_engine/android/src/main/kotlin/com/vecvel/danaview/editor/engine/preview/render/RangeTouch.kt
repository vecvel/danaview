// OWNER: AND-18
//
// When a plan change touches a rendered range (ARCH §12.2 "Rendered ranges", D-45 'Contract'). The
// reference rule is the Dart `patchTouchesRange` (API-01 fake, `testing.dart`), mirrored here in
// [patchTouches]: a removed or upserted layer whose old or new span overlaps the range, a canvas
// change (every range), a duration change when the range ends after the shorter duration, a changed
// or removed asset the old plan had (every range); audio changes never touch a range.
//
// The engine does not see patches as such (PreviewSession applies them and publishes a new
// ParamSnapshot), so the rendered-range swap observes plan CHANGES: [changeTouches] applies the same
// rule to the difference of two plans (the "patch" is every layer that was added, removed or changed
// and every asset that was changed or removed). A patch that re-sends an identical layer is
// invisible in the difference; it cannot change a pixel, so keeping the range is safe. Transient
// overrides (a drag in progress, not a patch) also touch a range when an overridden layer overlaps
// it ([transientTouches]): a stale render must never play while the live picture differs.
// Pure (JVM-tested); spans are plan microseconds, half-open [startUs, endUs).

package com.vecvel.danaview.editor.engine.preview.render

import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PatchSet
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.plan.RenderPlanPatch

/** The touch rule of rendered ranges (file header). */
object RangeTouch {
    private fun overlaps(t0: Long, t1: Long, startUs: Long, endUs: Long): Boolean = t0 < endUs && startUs < t1

    /** Dart `patchTouchesRange(before, patch, [startUs, endUs))`. */
    fun patchTouches(before: RenderPlan, patch: RenderPlanPatch, startUs: Long, endUs: Long): Boolean {
        if (patch.canvas != null) return true
        val dur = patch.durUs
        if (dur != null && dur != before.durUs && endUs > minOf(dur, before.durUs)) return true
        if (patch.assetRemovals.any { before.assets.containsKey(it) }) return true
        for ((id, asset) in patch.assetUpserts) {
            val old = before.assets[id]
            if (old != null && old != asset) return true
        }
        val old = before.layers.associateBy { it.id }
        for (id in patch.layers.remove) {
            val l = old[id] ?: continue
            if (overlaps(l.t0, l.t1, startUs, endUs)) return true
        }
        for (l in patch.layers.upsert) {
            if (overlaps(l.t0, l.t1, startUs, endUs)) return true
            val o = old[l.id]
            if (o != null && overlaps(o.t0, o.t1, startUs, endUs)) return true
        }
        return false
    }

    /** The same rule applied to the change [before] → [after] (file header). */
    fun changeTouches(before: RenderPlan, after: RenderPlan, startUs: Long, endUs: Long): Boolean =
        patchTouches(before, diff(before, after), startUs, endUs)

    /** The patch equivalent of [before] → [after]: changed fields, changed/added/removed layers and assets. */
    fun diff(before: RenderPlan, after: RenderPlan): RenderPlanPatch {
        val oldLayers = before.layers.associateBy { it.id }
        val newLayers = after.layers.associateBy { it.id }
        val upserts = ArrayList<PlanLayer>()
        for (l in after.layers) if (oldLayers[l.id] != l) upserts += l
        val removed = before.layers.map { it.id }.filter { it !in newLayers }
        val assetUpserts = after.assets.filter { (id, a) -> before.assets[id] != a }
        val assetRemovals = before.assets.keys.filter { it !in after.assets }
        return RenderPlanPatch(
            from = before.rev,
            to = after.rev,
            canvas = if (after.canvas != before.canvas) after.canvas else null,
            durUs = if (after.durUs != before.durUs) after.durUs else null,
            assetUpserts = assetUpserts,
            assetRemovals = assetRemovals,
            layers = PatchSet(upserts, removed),
        )
    }

    /** Whether a transient override of [snap] changes a layer that overlaps [startUs, endUs). */
    fun transientTouches(snap: ParamSnapshot, startUs: Long, endUs: Long): Boolean {
        if (snap.transients.isEmpty()) return false
        for (tr in snap.transients.values) {
            for (tl in tr.layers) {
                val l = snap.plan.layer(tl.id) ?: continue
                if (!overlaps(l.t0, l.t1, startUs, endUs)) continue
                if (snap.layer(tl.id) != l) return true
            }
        }
        return false
    }
}
