// OWNER: AND-09
//
// API-03's render-math vectors (test_fixtures/vectors/render_math.json, ARCH §11.6) run through
// the production GLSL on the emulator's GPU path: every row (chroma key, exposure,
// brightness/contrast, highlights/shadows, saturation, temperature/tint, grade, LUT, Gaussian blur,
// sharpen, vignette, item mask, canvas mask, place, composite, sprite reveal) is drawn on its
// 8 × 8 image by the ShaderPrograms pass that implements it and compared with the parity tolerance
// (mean |Δ| ≤ 1.5/255 and p99 ≤ 6/255 over all texels and channels, vectors/README.md "tol").
// Inputs are RGBA32F textures and outputs RGBA32F targets (EXT_color_buffer_float) so the check
// measures the shader math, not 8-bit storage. Stage rows whose formula has no clamp but which the
// GPU only runs inside the clamped grade (exposure, brightness/contrast, highlights/shadows,
// saturation) compare with clamp(out, 0, 1): the grade always ends with temperature/tint's clamp.
// Place-family rows run with antialiasing off (the reference has hard edges); the place rows
// sample a raster already at footprint size (one tap), as the reference row defines it.

package com.vecvel.danaview.editor.engine.effects

import android.opengl.GLES20
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.plan.CanvasMask
import com.vecvel.danaview.editor.engine.plan.PlanAdjust
import com.vecvel.danaview.editor.engine.plan.PlanChroma
import com.vecvel.danaview.editor.engine.plan.PlanMask
import com.vecvel.danaview.editor.engine.plan.PlanMaskShape
import com.vecvel.danaview.editor.engine.plan.PlanReader
import org.json.JSONObject
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor

@RunWith(AndroidJUnit4::class)
class RenderMathVectorsGlTest {
    private val json = JSONObject(TestFixtures.readText(FixtureTree.ENGINE_API, "vectors/render_math.json"))

    private class Row(val name: String, val stage: String, val stats: DoubleArray)

    private fun texels(r: JSONObject, key: String, w: Int, h: Int): FloatArray {
        val out = FloatArray(w * h * 4)
        if (r.has("${key}Image")) {
            val img = r.getJSONArray("${key}Image")
            for (i in 0 until w * h) {
                val t = img.getJSONArray(i)
                for (c in 0 until 4) out[i * 4 + c] = t.getDouble(c).toFloat()
            }
        } else {
            val t = r.getJSONArray(key)
            for (i in 0 until w * h) for (c in 0 until 4) out[i * 4 + c] = t.getDouble(c).toFloat()
        }
        return out
    }

    private fun premultiply(v: FloatArray): FloatArray = FloatArray(v.size) { i -> if (i % 4 == 3) v[i] else v[i] * v[i - i % 4 + 3] }

    private fun clamp01(v: FloatArray): FloatArray = FloatArray(v.size) { v[it].coerceIn(0f, 1f) }

    /** mean, p99, max of |a − b| over every texel and channel. */
    private fun stats(a: FloatArray, b: FloatArray): DoubleArray {
        val e = DoubleArray(a.size) { abs(a[it].toDouble() - b[it].toDouble()) }.sorted()
        val p99 = e[(ceil(e.size * 0.99).toInt() - 1).coerceIn(0, e.size - 1)]
        return doubleArrayOf(e.average(), p99, e.last())
    }

    private fun lut(name: String): LutTable {
        val l = json.getJSONObject("luts").getJSONObject(name)
        return if (l.has("file")) {
            TestFixtures.open(FixtureTree.ENGINE_API, "vectors/" + l.getString("file")).use { LutTable.decode(it.readBytes()) }
        } else {
            val rgb = l.getJSONArray("rgb")
            LutTable.fromFloats(l.getInt("n"), DoubleArray(rgb.length()) { rgb.getDouble(it) })
        }
    }

    private fun adj(p: JSONObject, vararg names: String): PlanAdjust {
        val v = DoubleArray(8)
        for (n in names) v[PlanAdjust.NAMES.indexOf(n)] = p.optDouble(n, 0.0)
        return PlanAdjust.of(v.toList())
    }

    private fun identityPlace(baseW: Double, baseH: Double, texW: Int, texH: Int, inverse: Affine = Affine(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)) = PlaceFrame(
        inverse = inverse, baseW = baseW, baseH = baseH, pxPerLocalX = texW / baseW, pxPerLocalY = texH / baseH,
        refRasterW = texW, refRasterH = texH, sharpenGain = 0.0, vignette = 0.0, aspect = baseW / baseH, mask = null, opacity = 1.0,
        canvasPerRenderX = 1.0, canvasPerRenderY = 1.0, canvasMasks = emptyList(), antialias = false, solid = null, revealShown = null,
    )

    private fun color(s: String): Int = PlanReader.decodeColor("${s}FF", "key") and 0xFFFFFF

    @Test
    fun everyRenderMathRowMatchesOnTheGpu() {
        val rows = json.getJSONArray("rows")
        val results = env.run {
            val programs = ShaderPrograms.acquire(GlTestEnv.shaders)
            check(programs.caps.isEs3 && programs.caps.floatColorBuffer) { "the vector test needs ES 3 with EXT_color_buffer_float" }
            val out = ArrayList<Row>()
            for (i in 0 until rows.length()) {
                val r = rows.getJSONObject(i)
                val w = r.getInt("w")
                val h = r.getInt("h")
                val p = r.getJSONObject("params")
                val stage = r.getString("stage")
                val straight = r.getString("space") == "straight"
                val input = texels(r, "in", w, h)
                var want = texels(r, "out", w, h)
                val target = GlTarget.rgba32f(w, h)
                val textures = ArrayList<Int>()
                val luts = ArrayList<LutTexture>()
                var sprite: SpriteTexture? = null
                var tmp: GlTarget? = null
                try {
                    fun srcTex(): Int = GlTestEnv.uploadRgbaF(input, w, h).also { textures += it }
                    fun look(chroma: PlanChroma? = null, a: PlanAdjust? = null, lutTex: LutTexture? = null, intensity: Double = 0.0) {
                        val frame = LookFrame(w, h, 0.0, 0.0, 1.0, 1.0, 1, 1, chroma?.let { LayerFrames.chroma(it) }, a, if (lutTex != null) "lut" else null, intensity, false)
                        target.bind()
                        programs.drawLook(SourceTexture(srcTex(), w, h, premultiplied = !straight), frame, lutTex)
                    }
                    var gotPremultiplied = true
                    when (stage) {
                        "chromaKey" -> look(chroma = PlanChroma(color(p.getString("key")), p.getDouble("sim"), p.getDouble("smooth"), p.getDouble("spill")))
                        "exposure" -> { look(a = adj(p, "exposure")); want = clamp01(want) }
                        "brightnessContrast" -> { look(a = adj(p, "brightness", "contrast")); want = clamp01(want) }
                        "highlightsShadows" -> { look(a = adj(p, "highlights", "shadows")); want = clamp01(want) }
                        "saturation" -> { look(a = adj(p, "saturation")); want = clamp01(want) }
                        "temperatureTint" -> look(a = adj(p, "temperature", "tint"))
                        "grade" -> look(a = adj(p.getJSONObject("adj"), *PlanAdjust.NAMES.toTypedArray()))
                        "lut" -> {
                            val t = LutTexture.upload(lut(p.getString("lut")), halfFloat = true).also { luts += it }
                            look(lutTex = t, intensity = p.getDouble("i"))
                        }
                        "gaussianBlur" -> {
                            val sigma = p.getDouble("sigma")
                            if (GaussianKernel.isSkipped(sigma)) {
                                target.bind()
                                programs.drawBlur(srcTex(), w, h, true, GaussianKernel.of(0.0))
                            } else {
                                val t = GlTarget.rgba32f(w, h).also { tmp = it }
                                t.bind()
                                programs.drawBlur(srcTex(), w, h, true, GaussianKernel.of(sigma))
                                target.bind()
                                programs.drawBlur(t.texture, w, h, false, GaussianKernel.of(sigma))
                            }
                        }
                        "sharpen", "vignette", "mask", "canvasMask", "place" -> {
                            gotPremultiplied = false
                            var frame = identityPlace(w.toDouble(), h.toDouble(), w, h)
                            when (stage) {
                                "sharpen" -> frame = frame.copy(sharpenGain = p.getDouble("amount") * 1.5)
                                "vignette" -> frame = frame.copy(vignette = p.getDouble("amount"), aspect = p.getDouble("aspect"))
                                "mask" -> {
                                    val b = p.getJSONArray("base")
                                    val bw = b.getDouble(0)
                                    val bh = b.getDouble(1)
                                    val m = p.getJSONObject("mask")
                                    val mask = PlanMask(
                                        if (m.getString("shape") == "rect") PlanMaskShape.RECT else PlanMaskShape.ELLIPSE,
                                        m.getDouble("cx"), m.getDouble("cy"), m.getDouble("w"), m.getDouble("h"), m.getDouble("r"),
                                        m.getDouble("corner"), m.getDouble("feather"), m.getDouble("op"), m.getBoolean("inv"),
                                    )
                                    frame = identityPlace(bw, bh, w, h, Affine(bw / w, 0.0, 0.0, bh / h, 0.0, 0.0)).copy(mask = LayerFrames.mask(mask, bw, bh))
                                }
                                "canvasMask" -> {
                                    val m = p.getJSONObject("cmask")
                                    val cm = CanvasMask(m.getDouble("cx"), m.getDouble("cy"), m.getDouble("w"), m.getDouble("h"), m.getDouble("r"), m.getDouble("feather"), m.getBoolean("inv"))
                                    frame = frame.copy(canvasMasks = listOf(LayerFrames.canvasMask(cm)))
                                }
                                "place" -> {
                                    val b = p.getJSONArray("base")
                                    val mArr = p.getJSONArray("M")
                                    val m = Affine(mArr.getDouble(0), mArr.getDouble(1), mArr.getDouble(2), mArr.getDouble(3), mArr.getDouble(4), mArr.getDouble(5))
                                    val bw = b.getDouble(0)
                                    val bh = b.getDouble(1)
                                    frame = identityPlace(bw, bh, w, h, m.inverse()!!).copy(opacity = p.getJSONObject("xf").getDouble("op"))
                                }
                            }
                            target.bind()
                            programs.drawPlace(srcTex(), w, h, frame, w, h, blend = false)
                        }
                        "composite" -> {
                            val dst = p.getJSONArray("dst")
                            target.bind()
                            GLES20.glClearColor(dst.getDouble(0).toFloat(), dst.getDouble(1).toFloat(), dst.getDouble(2).toFloat(), dst.getDouble(3).toFloat())
                            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
                            val solid = floatArrayOf(input[0], input[1], input[2], input[3])
                            programs.drawPlace(0, 1, 1, identityPlace(w.toDouble(), h.toDouble(), w, h).copy(solid = solid), w, h, blend = true)
                        }
                        "spriteReveal" -> {
                            val glyphs = p.getJSONArray("glyphs")
                            val rgba = ByteArray(w * h * 4) { (input[it].coerceIn(0f, 1f) * 255f + 0.5f).toInt().toByte() }
                            val img = VspriteImage(w, h, 1f, rgba, ShortArray(w * h) { glyphs.getInt(it).toShort() })
                            val s = SpriteTexture.upload(img, programs.caps.maxTextureSize).also { sprite = it }
                            val reveal = if (p.isNull("reveal")) null else floor(p.getDouble("reveal"))
                            target.bind()
                            programs.drawSpriteRaster(s, w, h, h, reveal)
                        }
                        else -> error("unknown stage $stage")
                    }
                    target.bind()
                    var got = GlTestEnv.readRgbaF(w, h)
                    if (!gotPremultiplied) got = premultiply(got)
                    val wantP = if (straight) premultiply(want) else want
                    out += Row(r.getString("name"), stage, stats(got, wantP))
                } finally {
                    for (t in textures) GlResources.deleteTexture(t)
                    for (l in luts) l.release()
                    sprite?.release()
                    tmp?.release()
                    target.release()
                }
            }
            programs.release()
            out
        }
        assertEquals("every row ran", rows.length(), results.size)
        val byStage = results.groupBy { it.stage }
        for ((stage, list) in byStage) {
            val worst = list.maxByOrNull { it.stats[2] }!!
            Log.i(TAG, "%s: %d rows, worst mean=%.4f/255 p99=%.3f/255 max=%.3f/255 (%s) [emulator SwiftShader]".format(
                stage, list.size, list.maxOf { it.stats[0] } * 255, list.maxOf { it.stats[1] } * 255, worst.stats[2] * 255, worst.name,
            ))
        }
        val failed = results.filter { !(it.stats[0] <= ParityStats.MEAN && it.stats[1] <= ParityStats.P99) }
        assertTrue(
            "rows outside the parity tolerance: " + failed.joinToString { "${it.stage}/${it.name} mean=%.2f p99=%.2f max=%.2f /255".format(it.stats[0] * 255, it.stats[1] * 255, it.stats[2] * 255) },
            failed.isEmpty(),
        )
        assertTrue("all 16 stages covered: ${byStage.keys}", byStage.size == 16)
    }

    /** The ES 2 fallback of the LUT texture (RGBA8 entries) stays inside the parity tolerance too. */
    @Test
    fun lutRowsWithAnRgba8Table() {
        val rows = json.getJSONArray("rows")
        val worst = env.run {
            val programs = ShaderPrograms.acquire(GlTestEnv.shaders)
            var worstMean = 0.0
            var worstP99 = 0.0
            for (i in 0 until rows.length()) {
                val r = rows.getJSONObject(i)
                if (r.getString("stage") != "lut") continue
                val p = r.getJSONObject("params")
                val input = texels(r, "in", 8, 8)
                val want = premultiply(texels(r, "out", 8, 8))
                val tex = GlTestEnv.uploadRgbaF(input, 8, 8)
                val l = LutTexture.upload(lut(p.getString("lut")), halfFloat = false)
                val target = GlTarget.rgba32f(8, 8)
                target.bind()
                programs.drawLook(SourceTexture(tex, 8, 8), LookFrame(8, 8, 0.0, 0.0, 1.0, 1.0, 1, 1, null, null, "lut", p.getDouble("i"), false), l)
                val s = stats(GlTestEnv.readRgbaF(8, 8), want)
                worstMean = maxOf(worstMean, s[0])
                worstP99 = maxOf(worstP99, s[1])
                target.release()
                l.release()
                GlResources.deleteTexture(tex)
            }
            programs.release()
            doubleArrayOf(worstMean, worstP99)
        }
        Log.i(TAG, "LUT RGBA8 fallback: worst mean=%.3f/255 p99=%.3f/255".format(worst[0] * 255, worst[1] * 255))
        assertTrue("RGBA8 LUT within parity: mean=${worst[0] * 255}/255 p99=${worst[1] * 255}/255", worst[0] <= ParityStats.MEAN && worst[1] <= ParityStats.P99)
    }

    /**
     * Regression (emulator GLES encoder, see ShaderSources): every pass samples the texture bound
     * for it even when other textures were created after it.
     */
    @Test
    fun passesSampleTheirOwnTextureAfterLaterUploads() {
        val results = env.run {
            val programs = ShaderPrograms.acquire(GlTestEnv.shaders)
            val target = GlTarget.rgba32f(8, 8)
            val a = GlTestEnv.uploadRgba8(ByteArray(256) { (if (it % 4 == 3) 255 else 100).toByte() }, 8, 8)
            val b = GlTestEnv.uploadRgba8(ByteArray(32) { (if (it % 4 == 3) 255 else 30).toByte() }, 4, 2)
            val lut = LutTexture.upload(LutTable.fromFloats(2, DoubleArray(24) { 0.0 }), programs.caps.isEs3)
            val c = GlTestEnv.uploadRgba8(ByteArray(256) { (if (it % 4 == 3) 255 else 200).toByte() }, 8, 8)
            val out = ArrayList<Float>()
            for (tex in listOf(a, c)) {
                target.bind()
                programs.drawLook(SourceTexture(tex, 8, 8), LookFrame(8, 8, 0.0, 0.0, 1.0, 1.0, 1, 1, null, null, null, 0.0, false), null)
                out += GlTestEnv.readRgbaF(8, 8)[0]
                programs.drawLook(SourceTexture(tex, 8, 8), LookFrame(8, 8, 0.0, 0.0, 1.0, 1.0, 1, 1, null, null, "lut", 0.5, false), lut)
                out += GlTestEnv.readRgbaF(8, 8)[0]
            }
            lut.release()
            for (t in listOf(a, b, c)) GlResources.deleteTexture(t)
            target.release()
            programs.release()
            out
        }
        // Without LUT: the source; with an all-black LUT at intensity 0.5: mix(c, 0, 0.5).
        assertEquals(100 / 255f, results[0], 1e-3f)
        assertEquals(50 / 255f, results[1], 1e-3f)
        assertEquals(200 / 255f, results[2], 1e-3f)
        assertEquals(100 / 255f, results[3], 1e-3f)
    }

    companion object {
        private const val TAG = "AND09.vectors"
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
