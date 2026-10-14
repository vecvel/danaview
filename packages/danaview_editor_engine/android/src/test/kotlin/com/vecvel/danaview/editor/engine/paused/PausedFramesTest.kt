// OWNER: AND-17
//
// Pure parts of the paused frame (PausedFrames, LayerCompositorGl.activeLayers, PausedEditingMode):
// - source time at a frame time (ARCH §11.5): linear on the containing map segment, hold = s0,
//   speed segments, clamped outside the map;
// - which layers are drawn at timeOfFrame(k) (half-open [t0, t1)) and in which order (z, t0, id),
//   with transients merged and evaluated at the frame time (D-35);
// - fetch requests: proxies, images, solids/sprites need none, full size up to 1080p, a
//   power-of-two fraction above it that still covers the largest animated footprint;
// - editing modes: matte flag on the item's `#v` layer only; cropSource keeps the crop region of
//   the source exactly where the cropped layer drew it (rotation, scale and flips included).

package com.vecvel.danaview.editor.engine.paused

import com.vecvel.danaview.editor.engine.effects.LayerFrames
import com.vecvel.danaview.editor.engine.effects.RenderGeometry
import com.vecvel.danaview.editor.engine.pigeon.EditingModeKindMsg
import com.vecvel.danaview.editor.engine.pigeon.EditingModeMsg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.Keyframes
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanCrop
import com.vecvel.danaview.editor.engine.plan.PlanEffects
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanMask
import com.vecvel.danaview.editor.engine.plan.PlanMaskShape
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import com.vecvel.danaview.editor.engine.plan.PlanTransient
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.plan.TransientLayer
import com.vecvel.danaview.editor.engine.preview.LayerCompositorGl
import com.vecvel.danaview.editor.engine.preview.PausedEditingMode
import com.vecvel.danaview.editor.engine.preview.PausedFrameRequest
import com.vecvel.danaview.editor.engine.preview.PausedFrames
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class PausedFramesTest {
    private val grid = FrameGrid.of(30)

    private fun media(id: String, z: Int, k0: Long, k1: Long, s0: Long, rate: Double = 1.0, asset: String = "v1", hold: Boolean = false): PlanLayer {
        val t0 = grid.timeOfFrame(k0)
        val t1 = grid.timeOfFrame(k1)
        return PlanLayer(
            id = id, z = z, seq = 0, t0 = t0, t1 = t1, kind = PlanLayerKind.MEDIA, asset = asset, hold = hold,
            map = listOf(MapSegment(t0, t1, s0, s0 + Math.round((t1 - t0) * rate))),
        )
    }

    private fun plan(layers: List<PlanLayer>, assets: Map<String, PlanAsset> = ASSETS) = RenderPlan(
        rev = 3, target = PlanTarget.PREVIEW, canvas = PlanCanvas(1920, 1080, 30), durUs = grid.timeOfFrame(300),
        assets = assets, layers = layers, audio = emptyList(),
    )

    @Test
    fun sourceTimeFollowsTheMapAtTheFrameTime() {
        val l = media("a#v", 10, 30, 90, 2_000_000)
        val t = grid.timeOfFrame(45)
        assertEquals(2_000_000 + (t - grid.timeOfFrame(30)), PausedFrames.sourceTimeUs(l, t))
        // 2× speed doubles the source distance.
        val fast = media("b#v", 10, 30, 90, 0, rate = 2.0)
        assertEquals((2 * (t - grid.timeOfFrame(30))).toDouble(), PausedFrames.sourceTimeUs(fast, t).toDouble(), 1.0)
        // hold shows s0 throughout.
        assertEquals(2_000_000L, PausedFrames.sourceTimeUs(media("h#v", 10, 30, 90, 2_000_000, hold = true), t))
        // Two segments: the second one's own mapping.
        val t0 = grid.timeOfFrame(0)
        val tm = grid.timeOfFrame(30)
        val t1 = grid.timeOfFrame(60)
        val two = PlanLayer(
            id = "c#v", z = 10, seq = 0, t0 = t0, t1 = t1, kind = PlanLayerKind.MEDIA, asset = "v1",
            map = listOf(MapSegment(t0, tm, 5_000_000, 6_000_000), MapSegment(tm, t1, 9_000_000, 11_000_000)),
        )
        val t40 = grid.timeOfFrame(40)
        assertEquals((9_000_000 + 2 * (t40 - tm)).toDouble(), PausedFrames.sourceTimeUs(two, t40).toDouble(), 1.0)
        assertEquals(5_000_000L, PausedFrames.sourceTimeUs(two, t0))
        // Clamped past the end.
        assertEquals(11_000_000L, PausedFrames.sourceTimeUs(two, t1 + 10_000))
    }

    @Test
    fun activeLayersAreHalfOpenSortedAndEvaluatedAtTheFrameTime() {
        val bottom = media("main#v", 10, 0, 60, 0)
        val top = media("pip#v", 10010, 30, 90, 0).copy(seq = 1, anim = mapOf("xf.op" to Keyframes.of(grid.timeOfFrame(30) to 0.0, grid.timeOfFrame(40) to 1.0)))
        val later = media("in#v", 10, 50, 120, 0)
        val p = plan(listOf(top, later, bottom))
        val snap = ParamSnapshot.of(p)
        assertEquals(listOf("main#v"), LayerCompositorGl.activeLayers(snap, grid.timeOfFrame(29)).map { it.first.id })
        // Same z: the later t0 draws on top (ARCH §11.4).
        val at55 = LayerCompositorGl.activeLayers(snap, grid.timeOfFrame(55))
        assertEquals(listOf("main#v", "in#v", "pip#v"), at55.map { it.first.id })
        // Half-open: main ends at frame 60.
        assertEquals(listOf("in#v", "pip#v"), LayerCompositorGl.activeLayers(snap, grid.timeOfFrame(60)).map { it.first.id })
        // Opacity evaluated at timeOfFrame(35): halfway.
        val op = LayerCompositorGl.activeLayers(snap, grid.timeOfFrame(35)).first { it.first.id == "pip#v" }.second.xf.op
        assertEquals(0.5, op, 1e-3)
        // A transient replaces the layer's params; dropping it restores them.
        val withT = snap.withTransient(PlanTransient(item = "pip", layers = listOf(TransientLayer("pip#v", xf = PlanTransform(s = 0.5)))))
        val tl = LayerCompositorGl.activeLayers(withT, grid.timeOfFrame(55)).first { it.first.id == "pip#v" }
        assertEquals(0.5, tl.second.xf.s, 0.0)
        assertEquals(1.0, LayerCompositorGl.activeLayers(withT.withoutTransient("pip"), grid.timeOfFrame(55)).first { it.first.id == "pip#v" }.second.xf.s, 0.0)
    }

    @Test
    fun requestsUseProxiesImagesAndNothingForSolids() {
        val geometry = RenderGeometry(1920, 1080, 960, 540)
        val m = media("a#v", 10, 0, 60, 1_000_000)
        val p = plan(listOf(m))
        val snap = ParamSnapshot.of(p)
        val t = grid.timeOfFrame(10)
        val params = snap.paramsAt(m.id, t)!!
        val r = PausedFrames.request(p, m, params, t, useProxies = false, geometry = geometry)!!
        assertEquals(PausedFrameRequest(PlanAssetKind.VIDEO, "file:///m/v1.mp4", "fp1", 1_000_000 + t, null), r)
        val proxied = PausedFrames.request(p, m, params, t, useProxies = true, geometry = geometry)!!
        assertEquals("file:///m/v1_proxy.mp4", proxied.uri)
        assertEquals("fp1#proxy", proxied.fingerprint)
        // No proxy: the original even with proxies on.
        val m2 = m.copy(asset = "v2")
        assertEquals("file:///m/v2.mp4", PausedFrames.request(p, m2, params, t, true, geometry)!!.uri)
        val img = PlanLayer(id = "i#v", z = 10010, t0 = 0, t1 = grid.timeOfFrame(60), kind = PlanLayerKind.IMAGE, asset = "img")
        val ir = PausedFrames.request(p, img, snap.paramsAt(m.id, t)!!.copy(kind = PlanLayerKind.IMAGE, id = "i#v"), t, false, geometry)!!
        assertEquals(PlanAssetKind.IMAGE, ir.kind)
        assertEquals(0L, ir.sourceTimeUs)
        val solid = PlanLayer(id = "s", z = 5, t0 = 0, t1 = 100, kind = PlanLayerKind.SOLID, color = -1)
        assertNull(PausedFrames.request(p, solid, params.copy(kind = PlanLayerKind.SOLID), t, false, geometry))
        val missing = m.copy(asset = "nope")
        assertNull(PausedFrames.request(p, missing, params, t, false, geometry))
    }

    @Test
    fun largeSourcesAreFetchedAtAFractionCoveringTheFootprint() {
        val geometry = RenderGeometry(1920, 1080, 1920, 1080)
        val params4k = ParamSnapshot.of(plan(listOf(media("a#v", 10, 0, 60, 0, asset = "uhd")))).paramsAt("a#v", 0)!!
        val uhd = PausedFrames.displaySize(ASSETS.getValue("uhd"))
        assertEquals(3840 to 2160, uhd)
        // Up to 1080p: full size, whatever the layer needs.
        assertNull(PausedFrames.maxLongSide(params4k.copy(xf = PlanTransform(s = 0.1)), 0.1, 1920 to 1080, geometry))
        // Full-screen 4K on a 1080p canvas needs half: 1920.
        assertEquals(1920, PausedFrames.maxLongSide(params4k, 1.0, uhd, geometry))
        // A quarter-size PiP needs 1/8: 480.
        assertEquals(480, PausedFrames.maxLongSide(params4k.copy(xf = PlanTransform(s = 0.12)), 0.12, uhd, geometry))
        // An animated zoom to 2× keeps the full size (no softening, ARCH §13.3).
        assertNull(PausedFrames.maxLongSide(params4k.copy(xf = PlanTransform(s = 0.25)), 2.0, uhd, geometry))
        // A crop to the left half needs twice the source px.
        assertNull(PausedFrames.maxLongSide(params4k.copy(crop = PlanCrop(0.0, 0.0, 0.5, 1.0)), 1.0, uhd, geometry))
        // Half render size halves the need.
        assertEquals(960, PausedFrames.maxLongSide(params4k, 1.0, uhd, RenderGeometry(1920, 1080, 960, 540)))
        // A rotated source swaps its display size.
        assertEquals(2160 to 3840, PausedFrames.displaySize(ASSETS.getValue("uhd").copy(rot = 90)))
        // Every bound covers the footprint.
        for (s in doubleArrayOf(0.05, 0.13, 0.26, 0.4, 0.5, 0.51, 0.9)) {
            val p = params4k.copy(xf = PlanTransform(s = s))
            val bound = PausedFrames.maxLongSide(p, s, uhd, geometry) ?: 3840
            assertTrue("s=$s bound=$bound", bound / 3840.0 * 3840 >= 1920 * s - 1e-6)
        }
    }

    @Test
    fun matteTargetsTheItemsVideoLayerOnly() {
        val p = ParamSnapshot.of(plan(listOf(media("it1#v", 10, 0, 60, 0)))).paramsAt("it1#v", 0)!!
        val mode = PausedEditingMode.Matte("it1")
        assertTrue(PausedFrames.applyMode(mode, p).second.matte)
        assertFalse(PausedFrames.applyMode(mode, p.copy(id = "it1#bd")).second.matte)
        assertFalse(PausedFrames.applyMode(mode, p.copy(id = "it2#v")).second.matte)
        val normal = PausedFrames.applyMode(PausedEditingMode.Normal, p)
        assertSame(p, normal.first)
        assertFalse(normal.second.matte)
        assertEquals(PausedEditingMode.Matte("x"), PausedEditingMode.of(EditingModeMsg(EditingModeKindMsg.MATTE, "x")))
        assertEquals(PausedEditingMode.CropSource("x"), PausedEditingMode.of(EditingModeMsg(EditingModeKindMsg.CROP_SOURCE, "x")))
        assertEquals(PausedEditingMode.Normal, PausedEditingMode.of(EditingModeMsg(EditingModeKindMsg.NORMAL, null)))
    }

    @Test
    fun cropSourceKeepsTheCropRegionInPlace() {
        val crop = PlanCrop(0.1, 0.2, 0.6, 0.9)
        for (xf in listOf(
            PlanTransform(cx = 900.0, cy = 500.0, s = 0.7, r = 0.0),
            PlanTransform(cx = 700.0, cy = 300.0, s = 1.3, r = 33.0),
            PlanTransform(cx = 1000.0, cy = 600.0, s = 0.5, r = 270.0, fx = true),
            PlanTransform(cx = 960.0, cy = 540.0, s = 2.0, r = -10.0, fy = true),
        )) {
            val layer = media("c#v", 10, 0, 60, 0).copy(
                base = PlanSize(800.0, 450.0), crop = crop, xf = xf,
                fx = PlanEffects(mask = PlanMask(PlanMaskShape.ELLIPSE)),
            )
            val p = ParamSnapshot.of(plan(listOf(layer))).paramsAt("c#v", 0)!!
            val (u, options) = PausedFrames.applyMode(PausedEditingMode.CropSource("c"), p)
            assertFalse(options.matte)
            assertEquals(PlanCrop.FULL, u.crop)
            assertNull(u.mask)
            val before = LayerFrames.placement(p.xf, p.base, 1920, 1080)
            val after = LayerFrames.placement(u.xf, u.base, 1920, 1080)
            // The cropped box's corners (base-local) and the crop rectangle in the full source (full-local) land on the same canvas px.
            for ((lx, ly) in listOf(0.0 to 0.0, 1.0 to 0.0, 0.0 to 1.0, 1.0 to 1.0, 0.5 to 0.5)) {
                val (bx, by) = before.apply(lx * p.base.w, ly * p.base.h)
                val fx = (crop.l + lx * (crop.r - crop.l)) * u.base.w
                val fy = (crop.t + ly * (crop.b - crop.t)) * u.base.h
                val (ax, ay) = after.apply(fx, fy)
                assertTrue("$xf corner ($lx,$ly): $bx,$by vs $ax,$ay", abs(ax - bx) < 1e-6 && abs(ay - by) < 1e-6)
            }
        }
        // A full crop is unchanged.
        val p = ParamSnapshot.of(plan(listOf(media("c#v", 10, 0, 60, 0)))).paramsAt("c#v", 0)!!
        assertSame(p, PausedFrames.uncropped(p))
    }

    private companion object {
        val ASSETS = mapOf(
            "v1" to PlanAsset(PlanAssetKind.VIDEO, "file:///m/v1.mp4", fp = "fp1", proxyUri = "file:///m/v1_proxy.mp4", w = 1920, h = 1080),
            "v2" to PlanAsset(PlanAssetKind.VIDEO, "file:///m/v2.mp4", fp = "fp2", w = 1280, h = 720),
            "uhd" to PlanAsset(PlanAssetKind.VIDEO, "file:///m/uhd.mp4", fp = "fp3", w = 3840, h = 2160),
            "img" to PlanAsset(PlanAssetKind.IMAGE, "file:///m/a.png", fp = "fpi", w = 400, h = 300),
        )
    }
}
