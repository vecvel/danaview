// OWNER: AND-09
//
// API-03's reference-renderer goldens (test_fixtures/images/goldens.json: 33 plans, 103 frames,
// incl. the 8× scale-keyframed text case api03_text_scale_8x) rendered by the production shaders
// on the emulator and compared with the ARCH §11.6 parity tolerance: mean |Δ| ≤ 1.5/255, 99th
// percentile ≤ 6/255, SSIM ≥ 0.98 (RGB, 7 × 7 windows), edge pixels excluded.
//
// Each frame: the plan (PlanReader, real android.util.JsonReader) is evaluated at
// tUs = timeOfFrame(k) (AND-08 ParamSnapshot.evaluate); layers draw bottom → top in (z, t0, id)
// order with LayerRenderer (look → blur → place, solid, sprite) onto the opaque bg with the
// compositor blend, at the golden's size. Sources are the manifest's decoded PNG frames (the video
// frame shown is the greatest PTS ≤ s + 500 µs, ARCH §11.5), images, sprites (premultiplied on load,
// 16-bit glyph maps) and .vlut tables. Edge pixels: pixels within 1 px of a hard geometric boundary
// of a drawn layer (its box, an item mask or canvas mask with zero feather), found by 4 × 4
// supersampling each pixel; the reference has no antialiasing and ours has a 1 px AA edge.
// Two raster sizings run: FOOTPRINT (round(base·|s|·renderScale), the reference's own rule; the
// paused-frame path) and MAX_SCALE (Media3 `configure`: the layer's largest animated scale, the
// place pass averaging the minified raster).

package com.vecvel.danaview.editor.engine.effects

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.plan.CanvasMask
import com.vecvel.danaview.editor.engine.plan.LayerParams
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanMaskShape
import com.vecvel.danaview.editor.engine.plan.PlanReader
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import org.json.JSONObject
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

@RunWith(AndroidJUnit4::class)
class ParityGoldensGlTest {
    private val manifest = JSONObject(TestFixtures.readText(FixtureTree.ENGINE_API, "images/goldens.json"))

    private class FrameResult(val golden: String, val k: Int, val stats: ParityStats)

    private fun bytes(path: String): ByteArray = TestFixtures.open(FixtureTree.ENGINE_API, "images/$path").use { it.readBytes() }

    private fun png(path: String): PngImage = PngDecoder.decode(bytes(path))

    /** Source time of a media layer at [t] (ARCH §11.5; hold = map[0].s0). */
    private fun sourceTime(layer: PlanLayer, t: Long): Double {
        if (layer.hold) return layer.map.first().s0.toDouble()
        val seg = layer.map.firstOrNull { t >= it.t0 && t < it.t1 } ?: layer.map.last()
        return seg.sourceAt(t.toDouble())
    }

    private fun run(sizing: RasterSizing): List<FrameResult> {
        val goldens = manifest.getJSONArray("goldens")
        return env.run {
            val programs = ShaderPrograms.acquire(GlTestEnv.shaders)
            val renderer = LayerRenderer(programs)
            val results = ArrayList<FrameResult>()
            for (g in 0 until goldens.length()) {
                val golden = goldens.getJSONObject(g)
                val name = golden.getString("name")
                val plan: RenderPlan = PlanReader.readPlan(bytes(golden.getString("plan")))
                val size = golden.getJSONArray("size")
                val w = size.getInt(0)
                val h = size.getInt(1)
                val geometry = RenderGeometry(plan.canvas.w, plan.canvas.h, w, h)
                val sources = golden.getJSONObject("sources")
                val frames = golden.getJSONArray("frames")
                val luts = HashMap<String, LutTexture>()
                val sprites = HashMap<String, SpriteTexture>()
                val target = GlTarget.rgba8(w, h)
                try {
                    for (f in 0 until frames.length()) {
                        val fr = frames.getJSONObject(f)
                        val k = fr.getInt("k")
                        val t = fr.getLong("tUs")
                        assertEquals("$name k=$k frame time", plan.canvas.outputGrid.timeOfFrame(k.toLong()), t)
                        target.bind()
                        programs.clearOpaque(plan.canvas.bg)
                        val edgeFrames = ArrayList<Pair<LayerParams, PlaceFrame>>()
                        for (layer in plan.layers.sortedWith(PlanValidator::compareLayers)) {
                            if (!layer.covers(t)) continue
                            val p = ParamSnapshot.evaluate(layer, plan, t)
                            // Like the reference: a layer at opacity 0 (or scale 0) draws nothing and reads no source.
                            if (LayerFrames.place(p, geometry, programs.caps.maxTextureSize) == null) continue
                            val asset = layer.asset?.let { plan.assets[it] }
                            var srcTex = 0
                            var srcW = 0
                            var srcH = 0
                            var sprite: SpriteTexture? = null
                            try {
                                when (layer.kind) {
                                    PlanLayerKind.MEDIA, PlanLayerKind.IMAGE -> {
                                        val src = sources.getJSONObject(layer.asset!!)
                                        val pngPath = if (src.getString("kind") == "video") {
                                            val fps = src.getInt("fps")
                                            val j = max(0, floor((sourceTime(layer, t) + 500.0) * fps / 1e6).toInt())
                                            val list = src.getJSONObject("frames")
                                            check(list.has("$j")) { "$name k=$k: source frame $j of ${layer.asset} not in the manifest" }
                                            list.getString("$j")
                                        } else {
                                            src.getString("png")
                                        }
                                        val img = png(pngPath)
                                        srcW = img.width
                                        srcH = img.height
                                        srcTex = GlTestEnv.uploadRgba8(img.toRgba8(), srcW, srcH)
                                    }
                                    PlanLayerKind.SPRITE -> {
                                        sprite = sprites.getOrPut(layer.asset!!) {
                                            val src = sources.getJSONObject(layer.asset!!)
                                            val img = png(src.getString("png"))
                                            val rgba = img.toRgba8()
                                            for (i in 0 until img.width * img.height) {
                                                val a = rgba[i * 4 + 3].toInt() and 0xFF
                                                for (c in 0 until 3) rgba[i * 4 + c] = (((rgba[i * 4 + c].toInt() and 0xFF) * a + 127) / 255).toByte()
                                            }
                                            val glyphs = if (src.isNull("glyphs")) null else png(src.getString("glyphs")).samples.let { s -> ShortArray(s.size) { s[it].toShort() } }
                                            SpriteTexture.upload(VspriteImage(img.width, img.height, asset!!.sscale!!.toFloat(), rgba, glyphs), programs.caps.maxTextureSize)
                                        }
                                    }
                                    PlanLayerKind.SOLID -> Unit
                                }
                                val fixed = if ((layer.kind == PlanLayerKind.MEDIA || layer.kind == PlanLayerKind.IMAGE) && sizing == RasterSizing.MAX_SCALE) {
                                    LayerFrames.rasterSize(RasterSizing.MAX_SCALE, p.base, max(ParamSnapshot.maxScale(layer), abs(p.xf.s)), p.crop, srcW, srcH, geometry, programs.caps.maxTextureSize)
                                } else {
                                    null
                                }
                                val frame = LayerFrames.frame(
                                    p, geometry, programs.caps.maxTextureSize, srcW, srcH, sizing, ParamSnapshot.maxScale(layer), fixed,
                                    reveal = asset?.reveal == true,
                                ) ?: continue
                                val lutAsset = frame.look?.lutAsset
                                val lut = lutAsset?.let { id ->
                                    luts.getOrPut(id) {
                                        val src = sources.getJSONObject(id)
                                        LutTexture.upload(LutTable.decode(bytes(src.getString("vlut"))), programs.caps.isEs3)
                                    }
                                }
                                val source = if (srcTex != 0) SourceTexture(srcTex, srcW, srcH) else null
                                renderer.draw(frame, source, lut, sprite, target, w, h, blend = true)
                                edgeFrames += p to frame.place
                            } finally {
                                if (srcTex != 0) GlResources.deleteTexture(srcTex)
                            }
                        }
                        target.bind()
                        val got = ParityMetrics.unit(GlTestEnv.readRgba8(w, h))
                        val want = png(fr.getString("png"))
                        check(want.width == w && want.height == h && want.channels == 3) { "$name golden size" }
                        val wantUnit = DoubleArray(want.samples.size) { want.samples[it] / 255.0 }
                        val edges = edgeMask(edgeFrames, w, h)
                        val stats = ParityMetrics.compare(got, wantUnit, 3, w, h, edges)
                        results += FrameResult(name, k, stats)
                        if (dump && !stats.withinParity()) dumpFrame("${sizing}_${name}_f$k", got, wantUnit, edges, w, h)
                    }
                } finally {
                    target.release()
                    for (l in luts.values) l.release()
                    for (s in sprites.values) s.release()
                }
            }
            renderer.release()
            programs.release()
            results
        }
    }

    /** Instrumentation argument `danaviewDumpGoldens=true`: write failing frames for inspection. */
    private val dump: Boolean =
        androidx.test.platform.app.InstrumentationRegistry.getArguments().getString("danaviewDumpGoldens") == "true"

    /** Writes got | want | 8× |diff| (edges blue) side by side, 4× enlarged, to the app's cache. */
    private fun dumpFrame(label: String, got: DoubleArray, want: DoubleArray, edges: BooleanArray, w: Int, h: Int) {
        val z = 4
        val bmp = android.graphics.Bitmap.createBitmap(w * 3 * z, h * z, android.graphics.Bitmap.Config.ARGB_8888)
        fun b(v: Double) = (v.coerceIn(0.0, 1.0) * 255 + 0.5).toInt()
        for (y in 0 until h) for (x in 0 until w) {
            val i = y * w + x
            val g = android.graphics.Color.rgb(b(got[i * 4]), b(got[i * 4 + 1]), b(got[i * 4 + 2]))
            val wv = android.graphics.Color.rgb(b(want[i * 3]), b(want[i * 3 + 1]), b(want[i * 3 + 2]))
            val d = (0 until 3).maxOf { abs(got[i * 4 + it] - want[i * 3 + it]) }
            val dv = if (edges[i]) android.graphics.Color.rgb(0, 0, 90) else android.graphics.Color.rgb(b(d * 8), b(d * 8), b(d * 8))
            for (yy in 0 until z) for (xx in 0 until z) {
                bmp.setPixel(x * z + xx, y * z + yy, g)
                bmp.setPixel((w + x) * z + xx, y * z + yy, wv)
                bmp.setPixel((2 * w + x) * z + xx, y * z + yy, dv)
            }
        }
        val dir = java.io.File(TestFixtures.targetContext.cacheDir, "and09_goldens").apply { mkdirs() }
        java.io.FileOutputStream(java.io.File(dir, "$label.png")).use { bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        bmp.recycle()
    }

    /** Pixels within 1 px of a hard boundary of a drawn layer (file header). */
    private fun edgeMask(layers: List<Pair<LayerParams, PlaceFrame>>, w: Int, h: Int): BooleanArray {
        val edge = BooleanArray(w * h)
        val n = 4
        for ((p, place) in layers) {
            val inv = place.inverse
            val mask = place.mask?.takeIf { it.feather == 0.0 && it.op > 0 }
            val cmasks = p.cmasks.filter { it.feather == 0.0 }
            for (y in 0 until h) for (x in 0 until w) {
                var first: Int? = null
                var varies = false
                for (sy in 0 until n) for (sx in 0 until n) {
                    val px = x + (sx + 0.5) / n
                    val py = y + (sy + 0.5) / n
                    val (lx, ly) = inv.apply(px, py)
                    var bits = if (lx >= 0 && lx < place.baseW && ly >= 0 && ly < place.baseH) 1 else 0
                    if (mask != null) {
                        val dx = lx - mask.cx
                        val dy = ly - mask.cy
                        val ux = mask.cos * dx + mask.sin * dy
                        val uy = -mask.sin * dx + mask.cos * dy
                        val sd = if (mask.shape == PlanMaskShape.RECT) roundedBox(ux, uy, mask.hx, mask.hy, mask.radius) else ellipse(ux, uy, mask.hx, mask.hy)
                        if (sd < 0) bits = bits or 2
                    }
                    cmasks.forEachIndexed { i, cm -> if (canvasInside(cm, px * place.canvasPerRenderX, py * place.canvasPerRenderY)) bits = bits or (4 shl i) }
                    if (first == null) first = bits else if (first != bits) varies = true
                }
                if (varies) {
                    for (yy in max(0, y - 1)..min(h - 1, y + 1)) for (xx in max(0, x - 1)..min(w - 1, x + 1)) edge[yy * w + xx] = true
                }
            }
        }
        return edge
    }

    private fun roundedBox(px: Double, py: Double, hx: Double, hy: Double, r: Double): Double {
        val qx = abs(px) - hx + r
        val qy = abs(py) - hy + r
        return hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r
    }

    private fun ellipse(px: Double, py: Double, hx: Double, hy: Double): Double =
        if (!(hx > 0 && hy > 0)) Double.POSITIVE_INFINITY else (sqrt((px / hx) * (px / hx) + (py / hy) * (py / hy)) - 1) * min(hx, hy)

    private fun canvasInside(m: CanvasMask, x: Double, y: Double): Boolean {
        val (c, s) = LayerFrames.cosSinDeg(m.r)
        val dx = x - m.cx
        val dy = y - m.cy
        return roundedBox(c * dx + s * dy, -s * dx + c * dy, m.w / 2, m.h / 2, 0.0) < 0
    }

    private fun verify(sizing: RasterSizing) {
        val results = run(sizing)
        assertEquals("every golden frame rendered", 103, results.size)
        for (r in results) Log.i(TAG, "$sizing ${r.golden} f${r.k}: ${r.stats} [emulator]")
        val worst = results.maxByOrNull { it.stats.mean }!!
        val worstP99 = results.maxByOrNull { it.stats.p99 }!!
        val worstSsim = results.minByOrNull { it.stats.ssim }!!
        Log.i(TAG, "$sizing summary: ${results.size} frames; worst mean ${worst.golden} f${worst.k} ${worst.stats}; worst p99 ${worstP99.golden} f${worstP99.k} ${worstP99.stats}; worst ssim ${worstSsim.golden} f${worstSsim.k} ${worstSsim.stats}")
        val failed = results.filter { !it.stats.withinParity() }
        assertTrue("$sizing frames outside the parity tolerance: " + failed.joinToString { "${it.golden} f${it.k} ${it.stats}" }, failed.isEmpty())
        assertTrue("the 8× scale-keyframed case ran", results.count { it.golden == "api03_text_scale_8x" } == 5)
    }

    @Test
    fun goldensMatchWithFootprintRasters() = verify(RasterSizing.FOOTPRINT)

    @Test
    fun goldensMatchWithMedia3MaxScaleRasters() = verify(RasterSizing.MAX_SCALE)

    companion object {
        private const val TAG = "AND09.goldens"
        private lateinit var env: GlTestEnv

        @BeforeClass
        @JvmStatic
        fun setUp() {
            env = GlTestEnv()
        }

        @AfterClass
        @JvmStatic
        fun tearDown() {
            env.close()
        }
    }
}
