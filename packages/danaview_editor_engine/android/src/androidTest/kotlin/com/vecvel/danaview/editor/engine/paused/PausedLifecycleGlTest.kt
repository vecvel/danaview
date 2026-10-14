// OWNER: AND-17
//
// AC "GL resources released on dispose": the live GL object counts of the effects package
// (GlResources: textures, framebuffers, buffers, programs; every texture, target, program and quad
// of the renderer, its compositor, LayerRenderer pool and LUT textures goes through it) return to
// their baseline after prefetch -> render (all passes: look, LUT, blur, detail, place, solid) ->
// structural edit -> trim -> surface attach/detach -> dispose, over three cycles; the count is
// not zero while the renderer lives. LayerCompositorGl on its own (the AND-16 use) releases its
// pooled rasters and LUT textures and leaves the caller's programs alone.

package com.vecvel.danaview.editor.engine.paused

import android.graphics.PixelFormat
import android.media.ImageReader
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.effects.EffectFixtures
import com.vecvel.danaview.editor.engine.effects.GlResources
import com.vecvel.danaview.editor.engine.effects.GlTarget
import com.vecvel.danaview.editor.engine.effects.GlTestEnv
import com.vecvel.danaview.editor.engine.effects.RenderGeometry
import com.vecvel.danaview.editor.engine.effects.ShaderPrograms
import com.vecvel.danaview.editor.engine.effects.SourceTexture
import com.vecvel.danaview.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.preview.LayerCompositorGl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PausedLifecycleGlTest {
    @Test
    fun rendererReleasesEveryGlObjectOnDispose() {
        val baseline = GlResources.counts()
        repeat(3) { cycle ->
            val plan = PausedScenes.layered()
            val h = PausedHarness("and17_leak_$cycle", plan)
            val reader = ImageReader.newInstance(PausedPlans.W, PausedPlans.H, PixelFormat.RGBA_8888, 2)
            val thread = HandlerThread("and17-leak").apply { start() }
            reader.setOnImageAvailableListener({ r -> r.acquireLatestImage()?.close() }, Handler(thread.looper))
            try {
                h.prefetch(6)
                h.render()
                val live = GlResources.counts()
                Log.i(AND17_TAG, "cycle $cycle live GL objects: $live (baseline $baseline)")
                assertTrue("objects exist while rendering", live.total > baseline.total)
                await<Unit> { h.renderer.attachSurface(reader.surface, PausedPlans.W, PausedPlans.H, it) }
                h.setPlan(PausedPlans.plan(plan.layers + PausedPlans.media("x#v", 10005, 2, 0, PausedPlans.FRAMES, 40), rev = 2), setOf("x#v"))
                h.render()
                h.renderer.trim(CacheTrimLevelMsg.MEMORY_PRESSURE)
                h.render()
                await<Unit> { h.renderer.detachSurface(it) }
                h.render()
            } finally {
                h.close()
                reader.close()
                thread.quitSafely()
            }
            assertEquals("cycle $cycle: counts back to baseline", baseline, GlResources.counts())
        }
    }

    @Test
    fun compositorReleasesItsObjectsButNotTheCallersPrograms() {
        GlTestEnv().use { env ->
            env.run {
                val programs = ShaderPrograms.acquire(GlTestEnv.shaders).apply { compileAll() }
                val withPrograms = GlResources.counts()
                val compositor = LayerCompositorGl(programs, EffectFixtures.assets)
                val plan = PausedScenes.layered()
                val snap = ParamSnapshot.of(plan)
                val t = PausedPlans.grid.timeOfFrame(6)
                val src = GlTestEnv.uploadRgba8(ByteArray(64 * 36 * 4) { if (it % 4 == 3) -1 else (it % 251).toByte() }, 64, 36)
                val target = GlTarget.rgba8(PausedPlans.W, PausedPlans.H)
                val inputs = LayerCompositorGl.activeLayers(snap, t).map { (layer, params) ->
                    LayerCompositorGl.Input(layer, params, if (layer.asset == "counter") SourceTexture(src, 64, 36) else null)
                }
                val stats = compositor.compose(plan, RenderGeometry(PausedPlans.W, PausedPlans.H, PausedPlans.W, PausedPlans.H), inputs, target)
                assertEquals(3, stats.drawn)
                assertEquals(1, compositor.assetTextureCount)
                assertTrue(compositor.pooledTargets > 0)
                // A gated input without source is skipped, not drawn.
                assertEquals(0, compositor.compose(plan, RenderGeometry(PausedPlans.W, PausedPlans.H, PausedPlans.W, PausedPlans.H), inputs.map { LayerCompositorGl.Input(it.layer, it.params, null) }.filter { it.layer.asset == "counter" }, target).drawn)
                compositor.release()
                target.release()
                GlResources.deleteTexture(src)
                assertEquals("only the caller's programs remain", withPrograms, GlResources.counts())
                assertEquals(GLES20.GL_NO_ERROR, GLES20.glGetError())
                programs.release()
            }
        }
    }
}
