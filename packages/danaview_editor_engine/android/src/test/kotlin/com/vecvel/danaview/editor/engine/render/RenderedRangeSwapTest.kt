// OWNER: AND-18
//
// RenderedRangeSwap on the JVM (no backend): message → frame conversion (D-35 nearest frame,
// `file://` URIs), the hook's ranges after a set, drops by patches / plan changes / transients
// until the next set (ARCH §12.2 "Rendered ranges"), the per-frame validity check with its single
// drop notice, the source-frame snapshot being ignored, boundary counters, and the power-state
// charging rule.

package com.vecvel.danaview.editor.engine.render

import com.vecvel.danaview.editor.engine.pigeon.RenderedRangeMsg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import com.vecvel.danaview.editor.engine.plan.PlanTransient
import com.vecvel.danaview.editor.engine.plan.TransientLayer
import com.vecvel.danaview.editor.engine.preview.PreviewSession
import com.vecvel.danaview.editor.engine.preview.fallback.RenderedRange
import com.vecvel.danaview.editor.engine.preview.render.PowerStates
import com.vecvel.danaview.editor.engine.preview.render.RenderRanges
import com.vecvel.danaview.editor.engine.preview.render.RenderedRangeSwap
import com.vecvel.danaview.editor.engine.render.RenderPlans.t
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicReference

class RenderedRangeSwapTest {
    private val plan = RenderPlans.plan()
    private val snapshot = AtomicReference(ParamSnapshot.of(plan))
    private val swap = RenderedRangeSwap(snapshot)

    private fun msg(k0: Long, k1: Long, name: String) = RenderedRangeMsg(t(k0), t(k1), "file:///c/danaview/editor/renders/$name.mp4", "h-$name")

    /** r0 = frames [0, 30), r1 = [60, 100) (the layers of RenderPlans.plan: a [0, 40), b all, c [60, 100)). */
    private fun install() {
        swap.set(RenderRanges.entries(listOf(msg(0, 30, "r0"), msg(60, 100, "r1")), RenderPlans.grid), snapshot.get())
    }

    private fun firsts(): List<Long> = swap.ranges(plan.rev).map { it.first }

    @Test
    fun messagesBecomeFrameRangesOnTheGrid() {
        val g = FrameGrid.of(30)
        val e = RenderRanges.entries(
            listOf(
                RenderedRangeMsg(t(60), t(100), "/abs/r1.mp4", "h1"),
                // Off-grid by a few µs (platform rounding): nearest frame.
                RenderedRangeMsg(t(10) - 3, t(20) + 4, "file:///abs/r0.mp4", "h0"),
                // Shorter than one frame: never plays.
                RenderedRangeMsg(t(30), t(30) + 10_000, "file:///abs/rx.mp4", "hx"),
            ),
            g,
        )
        assertEquals(listOf(RenderedRange(10, 20, "file:///abs/r0.mp4"), RenderedRange(60, 100, "file:///abs/r1.mp4")), e.map { it.range })
        assertEquals(listOf("h0", "h1"), e.map { it.hash })
        assertEquals(t(10) - 3, e[0].startUs)
        assertEquals("file:///abs/x.mp4", RenderRanges.fileUri("/abs/x.mp4"))
        assertEquals("file:///abs/x.mp4", RenderRanges.fileUri("file:///abs/x.mp4"))
    }

    @Test
    fun rangesAreServedUntilAChangeTouchesThem() {
        install()
        assertEquals(listOf(0L, 60L), firsts())
        // A param patch of "a" (frames 0..40) touches r0 only.
        val a2 = plan.layer("a#v")!!.copy(xf = PlanTransform(cx = 1.0, cy = 2.0))
        val p2 = plan.copy(rev = 2, layers = plan.layers.map { if (it.id == "a#v") a2 else it })
        snapshot.set(snapshot.get().withPlan(p2, setOf("a#v")))
        assertTrue(swap.refresh())
        assertEquals(listOf(60L), firsts())
        assertEquals(1, swap.stats().dropped)
        // Reverting the layer does not bring r0 back: dropped until the next set.
        snapshot.set(snapshot.get().withPlan(plan.copy(rev = 3), setOf("a#v")))
        assertFalse(swap.refresh())
        assertEquals(listOf(60L), firsts())
        // A change outside every range keeps them; the next set restores both.
        install()
        val extra = PlanLayer(id = "x#s", z = 50, t0 = t(40), t1 = t(55), kind = PlanLayerKind.SOLID, color = -1, base = PlanSize(10.0, 10.0))
        snapshot.set(snapshot.get().withPlan(plan.copy(rev = 4, layers = plan.layers + extra), setOf("x#s")))
        assertFalse(swap.refresh())
        assertEquals(listOf(0L, 60L), firsts())
    }

    @Test
    fun everyPlaybackFrameChecksValidityAndADropIsReportedOnce() {
        install()
        val (r0, r1) = swap.current.map { it.range }
        var drops = 0
        swap.onDropped = { drops++ }
        assertTrue(swap.isValid(r0))
        assertTrue(swap.isValid(r1))
        // A param patch of "a" (inside r0) published while a range frame is due: no poll ran, the
        // very next per-frame check already refuses r0 and keeps r1.
        val a2 = plan.layer("a#v")!!.copy(xf = PlanTransform(cx = 1.0, cy = 2.0))
        snapshot.set(snapshot.get().withPlan(plan.copy(rev = 2, layers = plan.layers.map { if (it.id == "a#v") a2 else it }), setOf("a#v")))
        assertFalse(swap.isValid(r0))
        assertTrue(swap.isValid(r1))
        assertFalse(swap.isValid(r0))
        assertEquals("one drop, reported once (the binding rebuilds once)", 1, drops)
        assertFalse(swap.refresh())
        assertEquals(1, drops)
        // A range that was never set is not valid either.
        assertFalse(swap.isValid(RenderedRange(30, 60, "file:///c/danaview/editor/renders/other.mp4")))
    }

    @Test
    fun theHookChecksBeforeAStructuralRebuildReadsIt() {
        install()
        // No poll ran: ranges() itself refreshes (the backend's rebuild never reinstalls a touched range).
        val removed = plan.copy(rev = 2, layers = plan.layers.filter { it.id != "c#v" })
        snapshot.set(snapshot.get().withPlan(removed, setOf("c#v")))
        assertEquals(listOf(0L), firsts())
    }

    @Test
    fun canvasAndAssetChangesDropEveryRange() {
        install()
        snapshot.set(snapshot.get().withPlan(plan.copy(rev = 2, canvas = plan.canvas.copy(bg = 0xFF112233.toInt()))))
        assertTrue(swap.refresh())
        assertTrue(swap.isEmpty)
        install()
        val assets = plan.assets + ("md_src" to PlanAsset(PlanAssetKind.VIDEO, "file:///fixtures/relinked.mp4", fp = "src", w = 1280, h = 720))
        snapshot.set(snapshot.get().withPlan(plan.copy(rev = 3, assets = assets)))
        assertTrue(swap.refresh())
        assertEquals(emptyList<Long>(), firsts())
    }

    @Test
    fun transientsDropTheRangesTheirLayersOverlap() {
        install()
        snapshot.set(snapshot.get().withTransient(PlanTransient(item = "c", layers = listOf(TransientLayer(id = "c#v", xf = PlanTransform(cx = 5.0, cy = 5.0))))))
        assertTrue(swap.refresh())
        assertEquals(listOf(0L), firsts())
    }

    @Test
    fun aSourceFrameSnapshotIsNotAPlanChange() {
        install()
        val timeline = snapshot.get()
        val sourceFrame = plan.copy(
            rev = 0,
            layers = listOf(PlanLayer(id = PreviewSession.SOURCE_FRAME_LAYER, z = 0, t0 = 0, t1 = t(1), kind = PlanLayerKind.IMAGE, asset = "md_src", base = PlanSize(640.0, 360.0))),
            audio = emptyList(),
        )
        snapshot.set(ParamSnapshot.of(sourceFrame))
        assertTrue(RenderedRangeSwap.isSourceFrame(snapshot.get()))
        assertFalse(swap.refresh())
        assertEquals(listOf(0L, 60L), firsts())
        // Back to the timeline unchanged: still valid.
        snapshot.set(timeline)
        assertFalse(swap.refresh())
        assertEquals(listOf(0L, 60L), firsts())
    }

    @Test
    fun boundariesAreCounted() {
        install()
        val r1 = swap.current[1].range
        swap.onBoundary(60, r1)
        swap.onBoundary(100, null)
        val s = swap.stats()
        assertEquals(1, s.entered)
        assertEquals(1, s.left)
        assertEquals(100L, s.lastBoundary)
        assertNull(s.current)
    }

    @Test
    fun chargingFollowsTheBatteryStatusOrThePlug() {
        // BatteryManager: STATUS_CHARGING 2, STATUS_FULL 5, STATUS_DISCHARGING 3; PLUGGED_AC 1, USB 2.
        assertTrue(PowerStates.charging(status = 2, plugged = 0))
        assertTrue(PowerStates.charging(status = 5, plugged = 0))
        assertTrue(PowerStates.charging(status = 3, plugged = 2))
        assertFalse(PowerStates.charging(status = 3, plugged = 0))
        assertFalse(PowerStates.charging(status = -1, plugged = 0))
        assertFalse(PowerStates.charging(null))
    }
}
