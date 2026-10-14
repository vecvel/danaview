// OWNER: AND-17
//
// AC "pixels of the paused frame match the player's composed frame for the same plan within the
// ARCH §11.6 parity tolerance". AND-01 reported a NO-GO for CompositionPlayer preview, so the
// composed reference is the Transformer export of the same plan (AND-08 mapper + AND-09 effect
// chain), read back before the encoder (PausedReference). The plan has a full-screen graded main
// layer (slot 0), a rotated, LUT-graded, blurred, vignetted, ellipse-masked, 85 % opaque PiP on a
// secondary slot (seq 1), a translucent solid band, and a coloured background; frames 2, 6 and 11
// are compared with no pixel excluded (stricter than §11.6, which excludes edge pixels). The main
// layer's barcode in the paused frame names the rule frame (ARCH §11.5). A second plan places
// alpha.png (translucent margins, a 50 % rectangle, a radial alpha disc) over the main layer: the
// paused frame is checked analytically for straight alpha, and against the export on every pixel
// whose image alpha is 0 or 1 (the export path mishandles translucent image texels, see the test).

package com.vecvel.danaview.editor.engine.paused

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.effects.ParityMetrics
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
import com.vecvel.danaview.editor.engine.preview.PausedEditingMode
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import com.vecvel.danaview.editor.engine.support.FrameBarcodeRegion
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs

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

    /**
     * alpha.png over the main layer. The paused frame follows ARCH §11.6 (straight alpha): checked
     * analytically on the 50 % green rectangle over the background. The Transformer export of the
     * same plan double-applies the alpha of translucent image texels (Media3 uploads the
     * premultiplied Android bitmap and AND-09's look pass reads it as straight: measured green-rect
     * pixel (29, 82, 51) against the correct (42, 139, 70)), a defect of the export path reported
     * in the AND-17 hand-off; parity with the export is therefore checked on every pixel whose image
     * alpha is 0 or 1 (found with the matte editing mode), translucent texels excluded.
     */
    @Test
    fun translucentImageLayerMatchesTheExportOnOpaqueTexels() {
        val plan = PausedScenes.withImage()
        val ks = setOf(4L)
        val reference = PausedReference.composedFrames(plan, ks, "parity_image")
        PausedHarness("and17_parity_image", plan).use { h ->
            h.prefetch(4)
            val r = h.render()
            assertEquals(0, r.missing)
            assertEquals(2, r.drawn)
            val got = h.capture()
            h.renderer.setEditingMode(PausedEditingMode.Matte("img"))
            h.render()
            val matte = h.capture()
            val w = got.width
            val hgt = got.height
            val translucent = BooleanArray(w * hgt) { i ->
                val r0 = matte.rgba[i * 4].toInt() and 0xFF
                val g0 = matte.rgba[i * 4 + 1].toInt() and 0xFF
                val b0 = matte.rgba[i * 4 + 2].toInt() and 0xFF
                abs(r0 - g0) <= 1 && abs(g0 - b0) <= 1 && r0 in 3..252
            }
            val excluded = BooleanArray(w * hgt)
            for (y in 0 until hgt) for (x in 0 until w) {
                if (!translucent[y * w + x]) continue
                for (dy in -1..1) for (dx in -1..1) {
                    val xx = x + dx
                    val yy = y + dy
                    if (xx in 0 until w && yy in 0 until hgt) excluded[yy * w + xx] = true
                }
            }
            val stats = ParityMetrics.compare(ParityMetrics.unit(got.rgba), ParityMetrics.unit(reference.getValue(4)), 4, w, hgt, excluded)
            val all = PausedReference.parity(got.rgba, reference.getValue(4), w, hgt)
            Log.i(AND17_TAG, "parity image k=4, translucent texels excluded: $stats; all pixels: $all (emulator)")
            assertTrue("image $stats", stats.withinParity())
            assertTrue("most pixels compared", stats.excluded < w * hgt / 4)
        }
        // Straight-alpha check: alpha.png alone over the background, scale 0.5 at the canvas centre.
        val alone = PausedPlans.plan(
            listOf(
                PlanLayer(
                    id = "img#v", z = 10020, t0 = 0, t1 = PausedPlans.grid.timeOfFrame(PausedPlans.FRAMES), kind = PlanLayerKind.IMAGE,
                    asset = "alpha", base = PlanSize(512.0, 512.0), xf = PlanTransform(cx = 320.0, cy = 180.0, s = 0.5),
                ),
            ),
        )
        PausedHarness("and17_image_alpha", alone).use { h ->
            h.prefetch(4)
            h.render()
            val got = h.capture()
            // Texel (144, 360) of alpha.png is (52, 229, 76, 128): canvas (264, 232) over bg (32, 48, 64).
            val a = 128 / 255.0
            val want = listOf(52 to 32, 229 to 48, 76 to 64).map { (c, bg) -> c * a + bg * (1 - a) }
            for (c in 0 until 3) {
                val v = got.rgba[(232 * got.width + 264) * 4 + c].toInt() and 0xFF
                assertEquals("straight alpha channel $c", want[c], v.toDouble(), 1.5)
            }
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
