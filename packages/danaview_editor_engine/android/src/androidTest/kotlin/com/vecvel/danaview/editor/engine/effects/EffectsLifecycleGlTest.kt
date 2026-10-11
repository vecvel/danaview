// OWNER: AND-09
//
// Lifecycle, cost and thread checks of the GL effects on the emulator (ARCH §13.3 "GL effects",
// AND-09 acceptance criteria):
// - gated frame: when the binding resolves no layer (a gap or a gated frame) each Media3 pass
//   (look, blur, place, sprite) is exactly one glClear and zero draws, and the output is fully
//   transparent; its GPU cost is measured against the full chain with GL timer queries
//   (GL_EXT_disjoint_timer_query), or glFinish-bounded wall time where the emulator lacks them;
// - GL leak test: repeated acquire → draw (look + LUT + blur + detail + place, sprite with reveal,
//   solid, through both LayerRenderer and the Media3 passes) → release cycles return every GL
//   object count to its baseline, released names are no longer GL objects, and the per-context
//   ShaderPrograms is reference counted;
// - only the owning GL thread touches GL: acquire off a GL thread, and any use of a GL object from
//   another thread (even one named danaview-gl), throw IllegalStateException;
// - 1080p compose timing (3 layers: graded + LUT full frame, masked + sharpened PiP, revealed
//   title) recorded as EMULATOR numbers; the ≤ 8 ms mid-device budget is QA-04's device check.

package com.vecvel.danaview.editor.engine.effects

import android.opengl.GLES20
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.HandlerLane
import com.vecvel.danaview.editor.engine.core.LaneSpec
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class EffectsLifecycleGlTest {
    private val fxPlan: RenderPlan = EffectFixtures.plan("effects_every_static_key")
    private val fxLayer: PlanLayer = fxPlan.layers.single { it.id == "it_fx0000000001#v" }
    private val spritePlan: RenderPlan = EffectFixtures.plan("sprites_export_reveal")
    private val titleLayer: PlanLayer = spritePlan.layers.single { it.id == "it_title000001#v" }
    private val solidPlan: RenderPlan = EffectFixtures.plan("image_solid_layers")

    private fun bound(plan: RenderPlan, layer: PlanLayer, t: Long) = BoundLayer(ParamSnapshot.evaluate(layer, plan, t), layer, plan)

    /** The Media3 chain of the fx layer on explicit targets. */
    private class Chain(val programs: ShaderPrograms, val geometry: RenderGeometry, lookW: Int, lookH: Int) {
        val look = GlTarget.rgba8(lookW, lookH)
        val blurred = GlTarget.rgba8(lookW, lookH)
        val out = GlTarget.rgba8(geometry.renderW, geometry.renderH)
        val tmp = ScratchTarget()
        val detail = ScratchTarget()
        val spriteRaster = ScratchTarget()

        fun run(b: BoundLayer?, src: Triple<Int, Int, Int>, textures: GlAssetTextures) {
            look.bind()
            EffectPasses.look(programs, b, RasterSizing.MAX_SCALE, LayerFrameOptions(), geometry, textures::lut, src.first, src.second, src.third, look.width, look.height)
            blurred.bind()
            EffectPasses.blur(programs, b, geometry, look.texture, look.width, look.height, tmp)
            out.bind()
            EffectPasses.place(programs, b, geometry, LayerFrameOptions(), blurred.texture, blurred.width, blurred.height, detail)
        }

        fun release() {
            look.release(); blurred.release(); out.release(); tmp.release(); detail.release(); spriteRaster.release()
        }
    }

    private fun median(v: List<Long>): Long = v.sorted()[v.size / 2]

    private fun timeNs(caps: GlCaps, block: () -> Unit): Pair<Long, Boolean> {
        val gpu = GlTimerQuery.measureNs(caps, block)
        return if (gpu != null) Pair(gpu, true) else Pair(GlTimerQuery.finishedWallNs(block), false)
    }

    @Test
    fun aGatedFrameCostsOneClearPerEffectAndNoSampling() = env.run {
        val programs = ShaderPrograms.acquire(GlTestEnv.shaders)
        val textures = GlAssetTextures(EffectFixtures.assets, programs.caps)
        val geometry = RenderGeometry(1920, 1080, 1920, 1080)
        val src = EffectFixtures.uploadSource("frame_counter_1080p30_1920x1080_f00015.png")
        val b = bound(fxPlan, fxLayer, 500_000)
        val (lw, lh) = EffectPasses.lookOutputSize(b, ParamSnapshot.maxScale(fxLayer), RasterSizing.MAX_SCALE, LayerFrameOptions(), src.second, src.third, geometry, programs.caps.maxTextureSize)
        val chain = Chain(programs, geometry, lw, lh)
        try {
            // The bindings' early exit: a gap item never resolves, and neither does a frame the sequence gates.
            assertEquals(null, LayerBinding.NONE.resolve(500_000))
            chain.run(b, src, textures) // warm up: compile, LUT upload, scratch targets
            val clears0 = programs.stats.clearCount
            val draws0 = programs.stats.drawCount
            chain.run(null, src, textures)
            assertEquals("look, blur and place each clear once", 3, programs.stats.clearCount - clears0)
            assertEquals("a gated frame samples nothing", 0, programs.stats.drawCount - draws0)
            chain.out.bind()
            val pixels = GlTestEnv.readRgba8(geometry.renderW, geometry.renderH)
            assertTrue("gated output is transparent", pixels.all { it.toInt() == 0 })
            // The sprite effect gates the same way.
            val c1 = programs.stats.clearCount
            val d1 = programs.stats.drawCount
            chain.out.bind()
            EffectPasses.sprite(programs, null, geometry, { error("no sprite may be loaded") }, chain.spriteRaster)
            assertEquals(1, programs.stats.clearCount - c1)
            assertEquals(0, programs.stats.drawCount - d1)
            // A full frame draws: look, blur H + V, detail, place.
            val d2 = programs.stats.drawCount
            chain.run(b, src, textures)
            assertEquals(5, programs.stats.drawCount - d2)

            val gated = ArrayList<Long>()
            val full = ArrayList<Long>()
            var timer = false
            repeat(15) {
                val g = timeNs(programs.caps) { chain.run(null, src, textures) }
                val f = timeNs(programs.caps) { chain.run(b, src, textures) }
                gated += g.first
                full += f.first
                timer = g.second
            }
            val how = if (timer) "GL timer query" else "glFinish wall time (no GL_EXT_disjoint_timer_query)"
            Log.i(TAG, "1080p fx layer chain [emulator, $how]: gated median %.3f ms, full median %.3f ms (look raster ${lw}x$lh)".format(median(gated) / 1e6, median(full) / 1e6))
            assertTrue("a gated frame is cheaper than a drawn one", median(gated) < median(full))
        } finally {
            chain.release()
            textures.release()
            GlResources.deleteTexture(src.first)
            programs.release()
        }
    }

    @Test
    fun repeatedCyclesLeakNoGlObjects() = env.run {
        val baseline = GlResources.counts()
        val deadTextures = ArrayList<Int>()
        val deadPrograms = ArrayList<Int>()
        val deadFramebuffers = ArrayList<Int>()
        repeat(3) { cycle ->
            val programs = ShaderPrograms.acquire(GlTestEnv.shaders)
            // Reference counted per EGL context.
            val again = ShaderPrograms.acquire(GlTestEnv.shaders)
            assertSame(programs, again)
            again.release()
            programs.checkThread() // still alive after one release
            programs.compileAll()
            for (p in ShaderSources.Program.values()) {
                if (p.externalTexture && !programs.caps.isEs3) continue
                deadPrograms += programs.program(p).id
            }
            val renderer = LayerRenderer(programs)
            val chainEmu = Media3ChainEmulation()
            val textures = GlAssetTextures(EffectFixtures.assets, programs.caps)
            val geometry = RenderGeometry(1920, 1080, 480, 270)
            val target = GlTarget.rgba8(480, 270)
            deadTextures += target.texture
            deadFramebuffers += target.framebuffer
            val src = EffectFixtures.uploadSource("frame_counter_1080p30_1920x1080_f00015.png")
            deadTextures += src.first
            try {
                // Media layer: look + LUT + blur + detail + place, both paths.
                val b = bound(fxPlan, fxLayer, 500_000)
                val frame = assertNotNullAndGet(LayerFrames.frame(b.params, geometry, programs.caps.maxTextureSize, src.second, src.third))
                val lutAsset = assertNotNullAndGet(frame.look?.lutAsset?.let { fxPlan.assets[it] })
                val lut = textures.lut(lutAsset)
                deadTextures += lut.texture
                target.bind()
                programs.clearOpaque(0xFF000000.toInt())
                renderer.draw(frame, SourceTexture(src.first, src.second, src.third), lut, null, target, 480, 270, blend = true)
                chainEmu.draw(programs, fxLayer, LayerBinding.fixed(b.params, fxLayer, fxPlan), 0, geometry, src.first, src.second, src.third, null, textures::lut, null, 480, 270)
                // Sprite with reveal, both paths.
                val sb = bound(spritePlan, titleLayer, 1_000_000)
                val spriteAsset = spritePlan.assets.getValue(titleLayer.asset!!)
                val sprite = textures.sprite(spriteAsset)
                deadTextures += sprite.color
                if (sprite.hasGlyphs) deadTextures += sprite.glyphs
                val sGeom = RenderGeometry(spritePlan.canvas.w, spritePlan.canvas.h, 480, 270)
                val sFrame = assertNotNullAndGet(LayerFrames.frame(sb.params, sGeom, programs.caps.maxTextureSize, reveal = spriteAsset.reveal == true))
                renderer.draw(sFrame, null, null, sprite, target, 480, 270, blend = true)
                chainEmu.draw(programs, titleLayer, LayerBinding.fixed(sb.params, titleLayer, spritePlan), 0, sGeom, 0, 0, 0, sprite, textures::lut, null, 480, 270)
                // Solids.
                for (layer in solidPlan.layers.filter { it.kind == com.vecvel.danaview.editor.engine.plan.PlanLayerKind.SOLID }) {
                    val p = ParamSnapshot.evaluate(layer, solidPlan, layer.t0)
                    val g = RenderGeometry(solidPlan.canvas.w, solidPlan.canvas.h, 480, 270)
                    LayerFrames.frame(p, g, programs.caps.maxTextureSize)?.let { renderer.draw(it, null, null, null, target, 480, 270, blend = true) }
                }
                assertEquals("cycle $cycle draws without GL errors", GLES20.GL_NO_ERROR, GLES20.glGetError())
                assertTrue("pooled rasters were used", renderer.allocated > 0)
            } finally {
                GlResources.deleteTexture(src.first)
                target.release()
                textures.release()
                chainEmu.release()
                renderer.release()
                programs.release()
            }
            assertEquals("cycle $cycle: every GL object released", baseline, GlResources.counts())
            // The next acquire builds a fresh instance.
            val fresh = ShaderPrograms.acquire(GlTestEnv.shaders)
            assertNotSame(programs, fresh)
            fresh.release()
        }
        for (id in deadPrograms) assertFalse("program $id deleted", GLES20.glIsProgram(id))
        for (id in deadTextures) assertFalse("texture $id deleted", GLES20.glIsTexture(id))
        for (id in deadFramebuffers) assertFalse("framebuffer $id deleted", GLES20.glIsFramebuffer(id))
        assertEquals(baseline, GlResources.counts())
    }

    @Test
    fun onlyTheOwningGlThreadTouchesGl() {
        // Off the GL lane (the instrumentation thread): refused before any GL call.
        val offLane = runCatching { ShaderPrograms.acquire(GlTestEnv.shaders) }
        assertTrue(offLane.exceptionOrNull() is IllegalStateException)
        val owned = env.run {
            val programs = ShaderPrograms.acquire(GlTestEnv.shaders)
            Triple(programs, GlTarget.rgba8(4, 4), LayerRenderer(programs))
        }
        val (programs, target, renderer) = owned
        try {
            assertEquals(LaneSpec.GL.threadName, programs.threadName)
            // Another thread with the engine GL lane's name is still not the owner.
            val impostor = HandlerLane(LaneSpec.GL)
            try {
                val failures = AtomicReference<List<Throwable?>>()
                val latch = CountDownLatch(1)
                impostor.execute {
                    failures.set(
                        listOf(
                            runCatching { programs.clearTransparent() }.exceptionOrNull(),
                            runCatching { programs.program(ShaderSources.Program.PLACE) }.exceptionOrNull(),
                            runCatching { target.bind() }.exceptionOrNull(),
                            runCatching { renderer.release() }.exceptionOrNull(),
                            runCatching { programs.release() }.exceptionOrNull(),
                        ),
                    )
                    latch.countDown()
                }
                assertTrue(latch.await(10, TimeUnit.SECONDS))
                for (f in failures.get()) assertTrue("refused: $f", f is IllegalStateException)
            } finally {
                impostor.quit()
            }
            // The instrumentation thread too.
            assertTrue(runCatching { programs.clearTransparent() }.exceptionOrNull() is IllegalStateException)
        } finally {
            env.run {
                renderer.release()
                target.release()
                programs.release()
            }
        }
    }

    @Test
    fun compose1080pIsMeasuredOnTheEmulator() = env.run {
        val programs = ShaderPrograms.acquire(GlTestEnv.shaders)
        val renderer = LayerRenderer(programs)
        val textures = GlAssetTextures(EffectFixtures.assets, programs.caps)
        val geometry = RenderGeometry(1920, 1080, 1920, 1080)
        val target = GlTarget.rgba8(1920, 1080)
        val src = EffectFixtures.uploadSource("frame_counter_1080p30_1920x1080_f00015.png")
        val src2 = EffectFixtures.uploadSource("3f9a0c_1920x1080_f00000.png")
        try {
            // Base: the fx layer's look (grade + LUT + chroma) full frame, no transform.
            val fx = bound(fxPlan, fxLayer, 500_000).params
            val base = fx.copy(xf = fx.xf.copy(cx = 960.0, cy = 540.0, s = 1.0, r = 0.0, fx = false, fy = false, op = 1.0), base = com.vecvel.danaview.editor.engine.plan.PlanSize(1920.0, 1080.0), crop = com.vecvel.danaview.editor.engine.plan.PlanCrop.FULL, detail = null, mask = null)
            // PiP: masked, sharpened, vignetted, rotated, at 40 %.
            val pip = fx.copy(id = "pip", xf = fx.xf.copy(cx = 1400.0, cy = 700.0, s = 0.4, r = 8.0, fx = false, fy = false, op = 1.0), base = com.vecvel.danaview.editor.engine.plan.PlanSize(1920.0, 1080.0), chroma = null, lut = null, detail = fx.detail?.copy(blur = 0.0))
            val title = bound(spritePlan, titleLayer, 1_000_000)
            val spriteAsset = spritePlan.assets.getValue(titleLayer.asset!!)
            val sprite = textures.sprite(spriteAsset)
            val frames = listOf(
                assertNotNullAndGet(LayerFrames.frame(base, geometry, programs.caps.maxTextureSize, src.second, src.third)) to src,
                assertNotNullAndGet(LayerFrames.frame(pip, geometry, programs.caps.maxTextureSize, src2.second, src2.third)) to src2,
            )
            val titleFrame = assertNotNullAndGet(LayerFrames.frame(title.params, geometry, programs.caps.maxTextureSize, reveal = spriteAsset.reveal == true))
            val lut = frames[0].first.look?.lutAsset?.let { fxPlan.assets[it] }?.let { textures.lut(it) }
            fun compose() {
                target.bind()
                programs.clearOpaque(0xFF000000.toInt())
                for ((f, s) in frames) renderer.draw(f, SourceTexture(s.first, s.second, s.third), if (f === frames[0].first) lut else null, null, target, 1920, 1080, blend = true)
                renderer.draw(titleFrame, null, null, sprite, target, 1920, 1080, blend = true)
            }
            compose() // warm up
            val times = ArrayList<Long>()
            var timer = false
            repeat(20) {
                val (ns, gpu) = timeNs(programs.caps) { compose() }
                times += ns
                timer = gpu
            }
            target.bind()
            val px = GlTestEnv.readRgba8(1920, 1080)
            val nonBlack = (0 until 1920 * 1080).count { i -> (px[i * 4].toInt() and 0xFF) + (px[i * 4 + 1].toInt() and 0xFF) + (px[i * 4 + 2].toInt() and 0xFF) > 30 }
            assertTrue("the composed frame has content ($nonBlack px)", nonBlack > 1920 * 1080 / 4)
            val sorted = times.sorted()
            val how = if (timer) "GL timer query" else "glFinish wall time (no GL_EXT_disjoint_timer_query)"
            Log.i(TAG, "1080p compose, 3 layers [emulator, $how, GL ${programs.caps.majorVersion}]: p50 %.2f ms, p90 %.2f ms, max %.2f ms over ${times.size} frames; device budget 8 ms is QA-04's".format(sorted[sorted.size / 2] / 1e6, sorted[(sorted.size * 9) / 10] / 1e6, sorted.last() / 1e6))
            assertEquals(20, times.size)
            assertTrue(times.all { it > 0 })
        } finally {
            GlResources.deleteTexture(src.first)
            GlResources.deleteTexture(src2.first)
            target.release()
            textures.release()
            renderer.release()
            programs.release()
        }
    }

    private fun <T> assertNotNullAndGet(v: T?): T {
        assertNotNull(v)
        return v!!
    }

    companion object {
        private const val TAG = "AND09.lifecycle"
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
