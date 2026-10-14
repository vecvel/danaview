// OWNER: AND-17
//
// AC "pixels of the paused frame match the player's composed frame for the same plan within the
// ARCH §11.6 parity tolerance". AND-01 reported a NO-GO for CompositionPlayer preview, so the
// composed reference is the Transformer export of the same plan (AND-08 mapper + AND-09 effect
// chain), read back before the encoder (PausedReference). The plan has a full-screen graded main
// layer (slot 0), a rotated, LUT-graded, blurred, vignetted, ellipse-masked, 85 % opaque PiP on a
// secondary slot (seq 1), a translucent solid band, and a coloured background; frames 2, 6 and 11
// are compared with no pixel excluded (stricter than §11.6, which excludes edge pixels). A second
// plan places alpha.png (translucent margins, a 50 % rectangle, a radial alpha disc) over the main
// layer. The main layer's barcode in the paused frame names the rule frame (ARCH §11.5).

package com.vecvel.danaview.editor.engine.paused

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.plan.PlanAdjust
import com.vecvel.danaview.editor.engine.plan.PlanDetail
import com.vecvel.danaview.editor.engine.plan.PlanEffects
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanLut
import com.vecvel.danaview.editor.engine.plan.PlanMask
import com.vecvel.danaview.editor.engine.plan.PlanMaskShape
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import com.vecvel.danaview.editor.engine.support.FrameBarcodeRegion
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PausedParityTest {
    @Test
    fun pausedFrameMatchesTheExportedComposedFrame() {
        val plan = PausedScenes.layered()
        val ks = setOf(2L, 6L, 11L)
        val reference = PausedReference.composedFrames(plan, ks, "parity_layered")
        PausedHarness("and17_parity", plan).use { h ->
            for (k in ks.sorted()) {
                val pre = h.prefetch(k)
                assertEquals("picture layers at $k", if (k >= 1) 2 else 1, pre.pictures)
                val r = h.render()
                assertEquals("frame", k, r.k)
                assertEquals("nothing missing", 0, r.missing)
                assertEquals("prefetched frames are reused", 0, r.fetched)
                val got = h.capture()
                assertEquals(PausedPlans.W, got.width)
                assertEquals(PausedPlans.H, got.height)
                val stats = PausedReference.parity(got.rgba, reference.getValue(k), got.width, got.height)
                Log.i(AND17_TAG, "parity layered k=$k: $stats (prefetch ${"%.1f".format(pre.wallMs)} ms, render ${"%.1f".format(r.glMs)} ms GL, emulator)")
                assertTrue("k=$k $stats", stats.withinParity())
                // The main layer shows the rule frame of its source time: source frame 10 + k.
                val band = FrameBarcodeRegion(0, 0, got.width, got.height)
                assertEquals("barcode k=$k", (10 + k).toInt(), FrameBarcode.decode(got.rgba, got.width, got.height, region = band))
            }
        }
    }

    @Test
    fun translucentImageLayerMatchesTheExport() {
        val plan = PausedScenes.withImage()
        val ks = setOf(4L)
        val reference = PausedReference.composedFrames(plan, ks, "parity_image")
        PausedHarness("and17_parity_image", plan).use { h ->
            h.prefetch(4)
            val r = h.render()
            assertEquals(0, r.missing)
            assertEquals(2, r.drawn)
            val got = h.capture()
            val stats = PausedReference.parity(got.rgba, reference.getValue(4), got.width, got.height)
            Log.i(AND17_TAG, "parity image k=4: $stats (emulator)")
            assertTrue("image $stats", stats.withinParity())
        }
    }
}

/** The AND-17 test scenes. */
object PausedScenes {
    /** Main (slot 0) + secondary PiP (slot 1) + translucent solid band. */
    fun layered(pipFx: PlanEffects = PIP_FX, rev: Long = 1): RenderPlan = PausedPlans.plan(
        listOf(
            PausedPlans.media(
                "main#v", 10, 0, 0, PausedPlans.FRAMES, 10,
                fx = PlanEffects(adj = PlanAdjust(contrast = 0.15, saturation = -0.25), detail = PlanDetail(sharpen = 0.3)),
            ),
            pip(pipFx),
            PlanLayer(
                id = "band#v", z = 20010, t0 = PausedPlans.grid.timeOfFrame(3), t1 = PausedPlans.grid.timeOfFrame(PausedPlans.FRAMES),
                kind = PlanLayerKind.SOLID, color = 0x99FF8800.toInt(), base = PlanSize(160.0, 90.0),
                xf = PlanTransform(cx = 110.0, cy = 290.0, r = -8.0),
            ),
        ),
        rev = rev,
    )

    val PIP_FX = PlanEffects(
        adj = PlanAdjust(exposure = 0.2, tint = 0.3),
        detail = PlanDetail(blur = 0.1, vignette = 0.4),
        lut = PlanLut("lut", 0.7),
        mask = PlanMask(PlanMaskShape.ELLIPSE, w = 0.92, h = 0.92, feather = 0.15),
    )

    fun pip(fx: PlanEffects = PIP_FX, sourceFrame: Long = 100): PlanLayer = PausedPlans.media(
        "pip#v", 10010, 1, 1, PausedPlans.FRAMES, sourceFrame,
        xf = PlanTransform(cx = 470.0, cy = 250.0, s = 0.4, r = 12.0, op = 0.85),
        fx = fx,
    )

    /** Main + alpha.png placed over it. */
    fun withImage(): RenderPlan = PausedPlans.plan(
        listOf(
            PausedPlans.media("main#v", 10, 0, 0, PausedPlans.FRAMES, 10),
            PlanLayer(
                id = "img#v", z = 10020, t0 = 0, t1 = PausedPlans.grid.timeOfFrame(PausedPlans.FRAMES), kind = PlanLayerKind.IMAGE,
                asset = "alpha", base = PlanSize(512.0, 512.0), xf = PlanTransform(cx = 380.0, cy = 190.0, s = 0.6, r = 20.0),
            ),
        ),
    )
}
