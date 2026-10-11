// OWNER: AND-09
//
// JVM checks of the uniform math (LayerFrames) against API-03's vectors:
// - transform.json: the placement matrix M of every case and its corner/centre points, and the
//   inverse the place shader uses (render px → base-local px, with the render scale);
// - render_math.json scalars: blur σ in canvas / render px, radius ⌈3σ⌉, the skip rule and the
//   normalized Gaussian weights;
// - raster sizing (footprint / max-scale / source), footprint taps, chroma and mask uniforms.

package com.vecvel.danaview.editor.engine.effects

import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.JvmFixtures
import com.vecvel.danaview.editor.engine.plan.LayerParams
import com.vecvel.danaview.editor.engine.plan.PlanChroma
import com.vecvel.danaview.editor.engine.plan.PlanCrop
import com.vecvel.danaview.editor.engine.plan.PlanDetail
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanMask
import com.vecvel.danaview.editor.engine.plan.PlanMaskShape
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class LayerFramesTest {
    private fun vectors(name: String) = JSONObject(JvmFixtures.file(FixtureTree.ENGINE_API, "vectors/$name").readText())

    private fun params(
        xf: PlanTransform = PlanTransform(),
        base: PlanSize = PlanSize(1920.0, 1080.0),
        kind: PlanLayerKind = PlanLayerKind.MEDIA,
        detail: PlanDetail? = null,
        crop: PlanCrop = PlanCrop.FULL,
        chroma: PlanChroma? = null,
        mask: PlanMask? = null,
        color: Int? = null,
    ) = LayerParams(
        id = "it_a#v", kind = kind, t = 0, xf = xf, base = base, crop = crop, adj = null, detail = detail, lut = null,
        chroma = chroma, mask = mask, reveal = null, cmasks = emptyList(), color = color,
    )

    @Test
    fun placementMatchesTransformVectors() {
        val cases = vectors("transform.json").getJSONArray("cases")
        assertTrue(cases.length() >= 10)
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val name = c.getString("name")
            val canvas = c.getJSONArray("canvas")
            val base = c.getJSONArray("base").let { PlanSize(it.getDouble(0), it.getDouble(1)) }
            val x = c.getJSONObject("xf")
            val xf = PlanTransform(x.getDouble("cx"), x.getDouble("cy"), x.getDouble("s"), x.getDouble("r"), x.getBoolean("fx"), x.getBoolean("fy"))
            val m = LayerFrames.placement(xf, base, canvas.getInt(0), canvas.getInt(1))
            val want = c.getJSONArray("M")
            val got = m.toArray()
            for (j in 0 until 6) assertEquals("$name M[$j]", want.getDouble(j), got[j], 1e-6)
            val inv = assertNotNullAndGet(m.inverse(), name)
            val points = c.getJSONArray("points")
            for (p in 0 until points.length()) {
                val pt = points.getJSONObject(p)
                val local = pt.getJSONArray("local")
                val canvasPt = pt.getJSONArray("canvas")
                val (cx, cy) = m.apply(local.getDouble(0), local.getDouble(1))
                assertEquals("$name point $p x", canvasPt.getDouble(0), cx, 1e-6)
                assertEquals("$name point $p y", canvasPt.getDouble(1), cy, 1e-6)
                val (lx, ly) = inv.apply(canvasPt.getDouble(0), canvasPt.getDouble(1))
                assertEquals("$name inverse $p x", local.getDouble(0), lx, 1e-6)
                assertEquals("$name inverse $p y", local.getDouble(1), ly, 1e-6)
            }
        }
    }

    private fun <T> assertNotNullAndGet(v: T?, what: String): T {
        assertNotNull("$what: singular", v)
        return v!!
    }

    @Test
    fun placeInverseIncludesTheRenderScale() {
        val geometry = RenderGeometry(1920, 1080, 96, 54)
        val p = params(xf = PlanTransform(cx = 600.0, cy = 300.0, s = 0.5, r = 30.0, fx = true))
        val place = LayerFrames.place(p, geometry, 4096)!!
        val m = LayerFrames.placement(p.xf, p.base, 1920, 1080)
        // Render pixel centre (10.5, 7.5) is canvas (210, 150).
        val (lx, ly) = place.inverse.apply(10.5, 7.5)
        val (cx, cy) = m.apply(lx, ly)
        assertEquals(10.5 / 0.05, cx, 1e-6)
        assertEquals(7.5 / 0.05, cy, 1e-6)
        assertEquals(0.5 * 0.05, place.pxPerLocalX, 1e-12)
        assertEquals(48, place.refRasterW) // round(1920·0.5·0.05)
        assertEquals(27, place.refRasterH)
        assertEquals(20.0, place.canvasPerRenderX, 1e-12)
    }

    @Test
    fun nothingIsDrawnForZeroOpacityScaleOrBase() {
        val g = RenderGeometry(1920, 1080, 1920, 1080)
        assertNull(LayerFrames.place(params(xf = PlanTransform(op = 0.0)), g, 4096))
        assertNull(LayerFrames.place(params(xf = PlanTransform(s = 0.0)), g, 4096))
        assertNull(LayerFrames.place(params(base = PlanSize(0.0, 10.0)), g, 4096))
        assertNotNull(LayerFrames.place(params(), g, 4096))
    }

    @Test
    fun blurSigmaScalarsMatch() {
        val rows = vectors("render_math.json").getJSONObject("scalars").getJSONArray("blurSigma")
        for (i in 0 until rows.length()) {
            val r = rows.getJSONObject(i)
            val canvas = r.getJSONArray("canvas")
            val sc = GaussianKernel.sigmaCanvasPx(r.getDouble("blur"), canvas.getInt(0), canvas.getInt(1))
            assertEquals("row $i σ canvas", r.getDouble("sigmaCanvasPx"), sc, 1e-6)
            val sr = sc * r.getDouble("renderScale")
            assertEquals("row $i σ render", r.getDouble("sigmaRenderPx"), sr, 1e-6)
            assertEquals("row $i radius", r.getInt("radiusRender"), GaussianKernel.of(sr).radius)
            assertEquals("row $i skipped", r.getBoolean("skippedRender"), GaussianKernel.isSkipped(sr))
            val ss = sc / r.getDouble("canvasPxPerSourcePx")
            assertEquals("row $i radius source", r.getInt("radiusSource"), GaussianKernel.of(ss).radius)
        }
    }

    @Test
    fun gaussianWeightsMatch() {
        val rows = vectors("render_math.json").getJSONObject("scalars").getJSONArray("gaussianKernel")
        for (i in 0 until rows.length()) {
            val r = rows.getJSONObject(i)
            val k = GaussianKernel.of(r.getDouble("sigma"))
            assertEquals(r.getInt("radius"), k.radius)
            assertEquals(1, k.step)
            val want = r.getJSONArray("weights")
            val got = k.weights()
            assertEquals(want.length(), got.size)
            for (j in got.indices) assertEquals("σ=${k.sigma} w[$j]", want.getDouble(j), got[j], 1e-8)
        }
    }

    @Test
    fun largeKernelsStepToStayWithinSixtyFourTapsPerSide() {
        val k = GaussianKernel.of(32.4) // 1080p blur 1.0: σ = 0.03·1080
        assertEquals(98, k.radius)
        assertEquals(2, k.step)
        assertTrue(k.radius / k.step <= GaussianKernel.MAX_TAPS_PER_SIDE)
        assertEquals(1.0, k.weights().sum(), 1e-9)
        assertEquals(0, GaussianKernel.of(0.0).radius)
    }

    @Test
    fun rasterSizingFollowsTheThreeRules() {
        val g = RenderGeometry(1920, 1080, 96, 54)
        val base = PlanSize(1920.0, 1080.0)
        assertEquals(Pair(96, 54), LayerFrames.rasterSize(RasterSizing.FOOTPRINT, base, 1.0, PlanCrop.FULL, 128, 72, g, 4096))
        assertEquals(Pair(48, 27), LayerFrames.rasterSize(RasterSizing.FOOTPRINT, base, -0.5, PlanCrop.FULL, 128, 72, g, 4096))
        // Max scale 8: the largest footprint round(1920·8·0.05) = 768, also above a 128 px source
        // (sharpen runs at render resolution, so the look pass upsamples like the reference).
        assertEquals(Pair(768, 432), LayerFrames.rasterSize(RasterSizing.MAX_SCALE, base, 8.0, PlanCrop.FULL, 128, 72, g, 4096))
        // A 4K source on a 1080p export is downscaled first: 1920·1·1 < 3840.
        val full = RenderGeometry(1920, 1080, 1920, 1080)
        assertEquals(Pair(1920, 1080), LayerFrames.rasterSize(RasterSizing.MAX_SCALE, base, 1.0, PlanCrop.FULL, 3840, 2160, full, 4096))
        assertEquals(Pair(3840, 2160), LayerFrames.rasterSize(RasterSizing.MAX_SCALE, base, 2.0, PlanCrop.FULL, 3840, 2160, full, 4096))
        // 4096 (API-03 maxLayerRasterSide) caps an 8× zoom of a 1080p layer.
        assertEquals(Pair(4096, 4096), LayerFrames.rasterSize(RasterSizing.MAX_SCALE, base, 8.0, PlanCrop.FULL, 3840, 2160, full, 16384))
        // Each frame of a Media3 chain draws its own footprint into the top-left of that texture.
        val p = LayerFrames.place(params(PlanTransform(s = 2.0), base), full, 4096)!!
        assertEquals(Pair(3840, 2160), LayerFrames.chainRaster(p, 4096, 4096))
        assertEquals(Pair(3000, 2160), LayerFrames.chainRaster(p, 3000, 4096))
        // maxTextureSize caps every side.
        assertEquals(Pair(2048, 2048), LayerFrames.rasterSize(RasterSizing.MAX_SCALE, PlanSize(4000.0, 4000.0), 1.0, PlanCrop.FULL, 4000, 4000, RenderGeometry(4000, 4000, 4000, 4000), 2048))
        val crop = PlanCrop(0.25, 0.0, 0.75, 0.5)
        assertEquals(Pair(960, 1080), LayerFrames.rasterSize(RasterSizing.SOURCE, base, 1.0, crop, 1920, 2160, full, 4096))
    }

    @Test
    fun footprintTaps() {
        assertEquals(1, LayerFrames.taps(0.3))
        assertEquals(1, LayerFrames.taps(1.0))
        assertEquals(2, LayerFrames.taps(1.0001))
        assertEquals(2, LayerFrames.taps(2.0))
        assertEquals(8, LayerFrames.taps(53.3))
        val p = params(base = PlanSize(1920.0, 1080.0))
        val look = LayerFrames.look(p, 1920, 1080, 96, 54)
        assertEquals(20.0, look.stepX, 1e-12)
        assertEquals(8, look.tapsX)
        val cropped = LayerFrames.look(params(crop = PlanCrop(0.5, 0.25, 1.0, 0.75)), 128, 72, 96, 54)
        assertEquals(64.0, cropped.cropX0, 1e-12)
        assertEquals(18.0, cropped.cropY0, 1e-12)
    }

    @Test
    fun croppedLookStepsAndTaps() {
        val cropped = LayerFrames.look(params(crop = PlanCrop(0.5, 0.25, 1.0, 0.75)), 128, 72, 96, 54)
        assertEquals(64.0 / 96, cropped.stepX, 1e-12)
        assertEquals(36.0 / 54, cropped.stepY, 1e-12)
        assertEquals(1, cropped.tapsX)
        assertEquals(1, cropped.tapsY)
    }

    @Test
    fun chromaUniformsOfTheGreenKey() {
        val u = LayerFrames.chroma(PlanChroma(0x00B140, sim = 0.4, smooth = 0.1, spill = 0.5))
        val r = 0.0
        val g = 0xB1 / 255.0
        val b = 0x40 / 255.0
        val y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        assertEquals((b - y) / 1.8556, u.keyCb, 1e-12)
        assertEquals((r - y) / 1.5748, u.keyCr, 1e-12)
        assertEquals(0.1, u.edge0, 1e-12)
        assertEquals(0.125, u.edge1, 1e-12)
        assertEquals(1.0, u.dirCb * u.dirCb + u.dirCr * u.dirCr, 1e-12)
        assertTrue(u.spillOn)
        assertEquals(0.101, LayerFrames.chroma(PlanChroma(0x00B140, sim = 0.4, smooth = 0.0, spill = 0.0)).edge1, 1e-12)
        val grey = LayerFrames.chroma(PlanChroma(0x808080, spill = 0.5))
        assertTrue("a grey key has no spill direction", !grey.spillOn)
    }

    @Test
    fun maskUniformsAreInBasePx() {
        val m = LayerFrames.mask(PlanMask(PlanMaskShape.RECT, cx = 0.5, cy = 0.5, w = 0.6, h = 0.4, r = 90.0, corner = 0.2, feather = 0.1), 16.0, 9.0)
        assertEquals(8.0, m.cx, 1e-12)
        assertEquals(4.5, m.cy, 1e-12)
        assertEquals(4.8, m.hx, 1e-12)
        assertEquals(1.8, m.hy, 1e-12)
        assertEquals(0.0, m.cos, 0.0)
        assertEquals(1.0, m.sin, 0.0)
        assertEquals(0.2 * 3.6, m.radius, 1e-12)
        assertEquals(0.1 * 0.25 * 3.6, m.feather, 1e-12)
    }

    @Test
    fun blurIsConvertedToTheLookRaster() {
        val g = RenderGeometry(1280, 720, 1280, 720)
        val p = params(base = PlanSize(1280.0, 720.0), xf = PlanTransform(s = 0.5), detail = PlanDetail(blur = 0.5))
        val place = LayerFrames.place(p, g, 4096)!!
        // σ canvas = 0.5·0.03·720 = 10.8; reference raster = 640 px wide; a 1280 px look raster is 2× finer.
        val blur = LayerFrames.blur(p, place, 1280, 720, g, 1280, 720)!!
        assertEquals(21.6, blur.sigmaX, 1e-9)
        assertEquals(21.6, blur.sigmaY, 1e-9)
        val tiny = params(base = PlanSize(1280.0, 720.0), detail = PlanDetail(blur = 0.01))
        assertNull("σ < 0.5 is skipped", LayerFrames.blur(tiny, LayerFrames.place(tiny, g, 4096)!!, 1280, 720, g, 1280, 720))
    }

    @Test
    fun solidsCarryPremultipliedColourAndSkipEffects() {
        val g = RenderGeometry(100, 100, 100, 100)
        val p = params(kind = PlanLayerKind.SOLID, color = 0x80FF0000.toInt(), detail = PlanDetail(sharpen = 1.0, vignette = 1.0),
            mask = PlanMask(PlanMaskShape.ELLIPSE))
        val f = LayerFrames.frame(p, g, 4096)!!
        assertNull(f.look)
        val solid = f.place.solid!!
        assertEquals(128 / 255f, solid[3], 1e-6f)
        assertEquals(128 / 255f, solid[0], 1e-6f)
        assertEquals(0.0, f.place.sharpenGain, 0.0)
        assertNull(f.place.mask)
        assertTrue(abs(f.place.vignette) == 0.0)
    }
}
