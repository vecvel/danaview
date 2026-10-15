// OWNER: AND-18
//
// RangeTouch: the native mirror of Dart's `patchTouchesRange` (ARCH §12.2 "Rendered ranges", the
// API-01 fake's reference rule and its contract test cases), the same rule applied to plan
// differences (what the swap observes), and transient overrides.

package com.vecvel.danaview.editor.engine.render

import com.vecvel.danaview.editor.engine.plan.AudioSeg
import com.vecvel.danaview.editor.engine.plan.Keyframes
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PatchSet
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import com.vecvel.danaview.editor.engine.plan.PlanTransient
import com.vecvel.danaview.editor.engine.plan.RenderPlanPatch
import com.vecvel.danaview.editor.engine.plan.TransientLayer
import com.vecvel.danaview.editor.engine.preview.render.RangeTouch
import com.vecvel.danaview.editor.engine.render.RenderPlans.FRAMES
import com.vecvel.danaview.editor.engine.render.RenderPlans.t
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RangeTouchTest {
    private val plan = RenderPlans.plan()
    private val dur = plan.durUs

    /** Frames [0, 30) and [60, end) like the Dart contract test. */
    private val r0 = 0L to t(30)
    private val r1 = t(60) to dur

    private fun patch(
        canvas: PlanCanvas? = null,
        durUs: Long? = null,
        upsert: List<PlanLayer> = emptyList(),
        remove: List<String> = emptyList(),
        assetUpserts: Map<String, PlanAsset> = emptyMap(),
        assetRemovals: List<String> = emptyList(),
        audio: PatchSet<AudioSeg> = PatchSet(),
    ) = RenderPlanPatch(
        from = 1, to = 2, canvas = canvas, durUs = durUs, assetUpserts = assetUpserts, assetRemovals = assetRemovals,
        layers = PatchSet(upsert, remove), audio = audio,
    )

    private fun touches(p: RenderPlanPatch, r: Pair<Long, Long>) = RangeTouch.patchTouches(plan, p, r.first, r.second)

    @Test
    fun patchRuleMirrorsTheDartReferenceCases() {
        // A layer changed inside r0 only.
        val a2 = plan.layer("a#v")!!.copy(xf = PlanTransform(cx = 100.0, cy = 100.0))
        assertTrue(touches(patch(upsert = listOf(a2)), r0))
        assertFalse(touches(patch(upsert = listOf(a2)), r1))
        // Removing the layer spanning everything touches both.
        assertTrue(touches(patch(remove = listOf("b#s")), r1))
        assertTrue(touches(patch(remove = listOf("b#s")), r0))
        // Moving a layer touches its old span as well as its new one.
        val moved = plan.layer("a#v")!!.copy(t0 = t(70), t1 = dur, map = listOf(MapSegment(t(70), dur, t(70), dur)))
        assertTrue(touches(patch(upsert = listOf(moved)), r0))
        assertTrue(touches(patch(upsert = listOf(moved)), r1))
        // Canvas changes touch every range; a longer duration only ranges past the old end.
        assertTrue(touches(patch(canvas = plan.canvas.copy(bg = 0xFF112233.toInt())), r0))
        assertFalse(touches(patch(durUs = dur * 2), r0))
        assertTrue(touches(patch(durUs = dur * 2), dur to dur * 2))
        assertTrue(touches(patch(durUs = t(65)), r1))
        assertFalse(touches(patch(durUs = t(65)), r0))
        // Assets the old plan had: a change or a removal touches every range; a new asset does not.
        val src2 = plan.assets.getValue("md_src").copy(fp = "src2")
        assertTrue(touches(patch(assetUpserts = mapOf("md_src" to src2)), r1))
        assertTrue(touches(patch(assetRemovals = listOf("md_other")), r0))
        assertFalse(touches(patch(assetUpserts = mapOf("md_new" to src2)), r0))
        assertFalse(touches(patch(assetUpserts = mapOf("md_src" to plan.assets.getValue("md_src"))), r0))
        // Audio never touches; an empty patch touches nothing.
        val seg = AudioSeg(id = "tone#a", asset = "md_tone", t0 = 0, t1 = dur, map = listOf(MapSegment(0, dur, 0, dur)), gain = Keyframes.of(0L to 0.5))
        assertFalse(touches(patch(audio = PatchSet(upsert = listOf(seg))), r0))
        assertFalse(touches(patch(), r0))
        // Edges are half-open: a layer ending exactly at the range start does not touch it.
        val edge = RenderPlans.solid("e#s", 50, 60, 40)
        assertFalse(touches(patch(upsert = listOf(edge)), r1))
        assertTrue(touches(patch(upsert = listOf(edge.copy(t1 = t(61)))), r1))
    }

    @Test
    fun changeRuleSeesTheDifferenceOfTwoPlans() {
        val a2 = plan.layer("a#v")!!.copy(xf = PlanTransform(cx = 100.0, cy = 100.0))
        val after = plan.copy(rev = 2, layers = plan.layers.map { if (it.id == "a#v") a2 else it })
        assertTrue(RangeTouch.changeTouches(plan, after, r0.first, r0.second))
        assertFalse(RangeTouch.changeTouches(plan, after, r1.first, r1.second))
        // The diff names exactly the changed layer.
        val d = RangeTouch.diff(plan, after)
        assertEquals(listOf("a#v"), d.layers.upsert.map { it.id })
        assertEquals(emptyList<String>(), d.layers.remove)
        assertEquals(null, d.canvas)
        assertEquals(null, d.durUs)
        // Same content under a new revision touches nothing (an identical re-send cannot change a pixel).
        assertFalse(RangeTouch.changeTouches(plan, plan.copy(rev = 9), r0.first, r0.second))
        // Removal, canvas, duration and asset changes through the diff.
        val removed = plan.copy(rev = 2, layers = plan.layers.filter { it.id != "c#v" })
        assertTrue(RangeTouch.changeTouches(plan, removed, r1.first, r1.second))
        assertFalse(RangeTouch.changeTouches(plan, removed, r0.first, r0.second))
        assertTrue(RangeTouch.changeTouches(plan, plan.copy(canvas = plan.canvas.copy(w = 1280, h = 720)), r1.first, r1.second))
        val shorter = RenderPlans.plan(frames = 65, layers = listOf(RenderPlans.media("a#v", 0, 40, 10, 0), RenderPlans.solid("b#s", 0, 65, 30)))
        assertTrue(RangeTouch.changeTouches(plan, shorter, r1.first, r1.second))
        val assetChanged = plan.copy(assets = plan.assets + ("md_other" to plan.assets.getValue("md_other").copy(fp = "x")))
        assertTrue(RangeTouch.changeTouches(plan, assetChanged, r0.first, r0.second))
        // Audio-only differences touch nothing.
        assertFalse(RangeTouch.changeTouches(plan, plan.copy(audio = emptyList()), r0.first, r0.second))
    }

    @Test
    fun transientsTouchOnlyRangesTheirLayersOverlap() {
        val snap = ParamSnapshot.of(plan)
        assertFalse(RangeTouch.transientTouches(snap, r0.first, r0.second))
        val dragged = snap.withTransient(PlanTransient(item = "c", layers = listOf(TransientLayer(id = "c#v", xf = PlanTransform(cx = 10.0, cy = 10.0)))))
        assertTrue(RangeTouch.transientTouches(dragged, r1.first, r1.second))
        assertFalse(RangeTouch.transientTouches(dragged, r0.first, r0.second))
        // A transient equal to the layer's own values changes nothing.
        val same = snap.withTransient(PlanTransient(item = "c", layers = listOf(TransientLayer(id = "c#v", xf = plan.layer("c#v")!!.xf))))
        assertFalse(RangeTouch.transientTouches(same, r1.first, r1.second))
        assertEquals(FRAMES, RenderPlans.grid.frameIndexOf(dur))
    }
}
