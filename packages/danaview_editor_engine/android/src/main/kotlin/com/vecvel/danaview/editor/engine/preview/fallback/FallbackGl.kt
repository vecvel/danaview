// OWNER: AND-16
//
// The contingency engine's GL (ARCH §13.3 "Frame clock", "Compositing"): its own EGL context (ES 3;
// the editor gate requires GLES 3) on danaview-gl, a 1×1 pbuffer while no window is attached, the
// window surface of the SurfaceProducer's Surface while the backend owns it, AND-09's
// ShaderPrograms and AND-17's LayerCompositorGl (same shaders and premultiplied source-over blend as
// the paused renderer and the Media3 effects), a canvas-render-size target that every frame is
// composed into and blitted onto the window with pts = P(k) (D-35), and the textures of image
// layers and paused-exact stills. danaview-gl is shared with AND-17's renderer, which makes its own
// context current per task, so every entry point here makes ours current first ([current]).

package com.vecvel.danaview.editor.engine.preview.fallback

import android.content.Context
import android.graphics.Bitmap
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.opengl.GLES30
import android.opengl.GLUtils
import android.view.Surface
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.effects.EffectAssets
import com.vecvel.danaview.editor.engine.effects.GlResources
import com.vecvel.danaview.editor.engine.effects.GlTarget
import com.vecvel.danaview.editor.engine.effects.RenderGeometry
import com.vecvel.danaview.editor.engine.effects.ShaderPrograms
import com.vecvel.danaview.editor.engine.effects.ShaderSources
import com.vecvel.danaview.editor.engine.effects.SourceTexture
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.preview.LayerCompositorGl
import com.vecvel.danaview.editor.engine.preview.PausedFrameRenderer
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** EGL, compositor and textures of the contingency engine (file header). danaview-gl only. */
internal class FallbackGl(appContext: Context, assets: EffectAssets) {
    val display: EGLDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
    private val config: EGLConfig
    private val context: EGLContext
    private val pbuffer: EGLSurface
    private var window: EGLSurface = EGL14.EGL_NO_SURFACE
    private var windowW = 0
    private var windowH = 0
    private var canvas: GlTarget? = null
    private var released = false

    val programs: ShaderPrograms
    val compositor: LayerCompositorGl

    /** Whether a window surface is attached. */
    val hasWindow: Boolean get() = window != EGL14.EGL_NO_SURFACE

    /** The last composed frame's size, or null. */
    val canvasSize: Pair<Int, Int>? get() = canvas?.let { it.width to it.height }

    init {
        val version = IntArray(2)
        if (!EGL14.eglInitialize(display, version, 0, version, 1)) throw gpu("eglInitialize")
        val attribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val n = IntArray(1)
        if (!EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, n, 0) || n[0] <= 0) throw gpu("no ES 3 config")
        config = configs[0]!!
        context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0)
        if (context == EGL14.EGL_NO_CONTEXT) throw gpu("eglCreateContext")
        pbuffer = EGL14.eglCreatePbufferSurface(display, config, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
        if (pbuffer == EGL14.EGL_NO_SURFACE) {
            EGL14.eglDestroyContext(display, context)
            throw gpu("pbuffer")
        }
        makeCurrent(pbuffer)
        programs = ShaderPrograms.acquire(ShaderSources.assetReader(appContext))
        compositor = LayerCompositorGl(programs, assets)
        // Compile every program now (≈ 0.5 s on the emulator), not on the first played frame.
        programs.compileAll()
        warmDraw()
    }

    /** One tiny solid frame through the place shader and the compositor blend. */
    private fun warmDraw() {
        val n = WARM_SIZE
        val target = GlTarget.rgba8(n, n)
        try {
            val plan = RenderPlan(
                rev = 0, target = PlanTarget.PREVIEW, canvas = PlanCanvas(n, n, 30), durUs = 1_000_000L,
                assets = emptyMap(), layers = emptyList(), audio = emptyList(),
            )
            val layer = PlanLayer(
                id = "warm", z = 0, t0 = 0, t1 = 1_000_000L, kind = PlanLayerKind.SOLID, color = 0x80FFFFFF.toInt(),
                base = PlanSize(n.toDouble(), n.toDouble()), xf = PlanTransform(cx = n / 2.0, cy = n / 2.0, r = 10.0),
            )
            compositor.compose(plan, RenderGeometry(n, n, n, n), listOf(LayerCompositorGl.Input(layer, ParamSnapshot.evaluate(layer, plan, 0), null)), target)
            GLES20.glFinish()
        } finally {
            target.release()
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        }
    }

    private fun gpu(what: String) = EngineException(EngineErrorCode.gpuUnavailable, "$what failed 0x${Integer.toHexString(EGL14.eglGetError())}")

    private fun makeCurrent(s: EGLSurface) {
        if (EGL14.eglGetCurrentContext() == context && EGL14.eglGetCurrentSurface(EGL14.EGL_DRAW) == s) return
        if (!EGL14.eglMakeCurrent(display, s, s, context)) throw gpu("eglMakeCurrent")
    }

    /** Makes the context current (on the window when attached) and runs [block]. */
    fun <T> current(block: () -> T): T {
        check(!released) { "GL released" }
        makeCurrent(if (hasWindow) window else pbuffer)
        return block()
    }

    /** Makes the context current (on the window when attached) for the GL calls that follow on this thread. */
    fun bind() {
        check(!released) { "GL released" }
        makeCurrent(if (hasWindow) window else pbuffer)
    }

    /** Draws on [surface] from now on. */
    fun attachWindow(surface: Surface, w: Int, h: Int) {
        detachWindow()
        val s = EGL14.eglCreateWindowSurface(display, config, surface, intArrayOf(EGL14.EGL_NONE), 0)
        if (s == null || s == EGL14.EGL_NO_SURFACE) {
            throw EngineException(EngineErrorCode.surfaceLost, "eglCreateWindowSurface failed 0x${Integer.toHexString(EGL14.eglGetError())}")
        }
        window = s
        windowW = w
        windowH = h
        makeCurrent(window)
    }

    /** Stops drawing on the window (its EGL surface is destroyed; the Surface stays the producer's). */
    fun detachWindow() {
        if (window == EGL14.EGL_NO_SURFACE) return
        makeCurrent(pbuffer)
        EGL14.eglDestroySurface(display, window)
        window = EGL14.EGL_NO_SURFACE
    }

    /** Composes [inputs] at [geometry] into the canvas target; returns the compositor stats. */
    fun compose(plan: RenderPlan, geometry: RenderGeometry, inputs: List<LayerCompositorGl.Input>): LayerCompositorGl.Stats = current {
        val c = canvasTarget(geometry.renderW, geometry.renderH)
        compositor.compose(plan, geometry, inputs, c)
    }

    /** Blits the canvas onto the window with pts P(k) (ns) and swaps; false without a window or canvas. */
    fun present(ptsUs: Long): Boolean = current {
        val c = canvas ?: return@current false
        if (!hasWindow) return@current false
        GLES30.glBindFramebuffer(GLES30.GL_READ_FRAMEBUFFER, c.framebuffer)
        GLES30.glBindFramebuffer(GLES30.GL_DRAW_FRAMEBUFFER, 0)
        val filter = if (c.width == windowW && c.height == windowH) GLES20.GL_NEAREST else GLES20.GL_LINEAR
        GLES30.glBlitFramebuffer(0, 0, c.width, c.height, 0, 0, windowW, windowH, GLES20.GL_COLOR_BUFFER_BIT, filter)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        EGLExt.eglPresentationTimeANDROID(display, window, ptsUs * 1000L)
        if (!EGL14.eglSwapBuffers(display, window)) {
            throw EngineException(EngineErrorCode.surfaceLost, "swap failed 0x${Integer.toHexString(EGL14.eglGetError())}")
        }
        true
    }

    private fun canvasTarget(w: Int, h: Int): GlTarget {
        val c = canvas
        if (c != null && c.width == w && c.height == h) return c
        c?.release()
        return GlTarget.rgba8(w, h).also { canvas = it }
    }

    /** RGBA (top-down) of the last composed frame. */
    fun capture(): PausedFrameRenderer.Captured = current {
        val c = canvas ?: throw EngineException(EngineErrorCode.internal, "nothing composed")
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, c.framebuffer)
        val buf = ByteBuffer.allocateDirect(c.width * c.height * 4).order(ByteOrder.nativeOrder())
        GLES20.glReadPixels(0, 0, c.width, c.height, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buf)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        val out = ByteArray(c.width * c.height * 4)
        val stride = c.width * 4
        for (y in 0 until c.height) {
            buf.position((c.height - 1 - y) * stride)
            buf.get(out, y * stride, stride)
        }
        PausedFrameRenderer.Captured(c.width, c.height, out)
    }

    /** An RGBA8 texture of [bitmap] (TOP_DOWN, premultiplied like Android bitmaps). */
    fun upload(bitmap: Bitmap): SourceTexture = current {
        val src = if (bitmap.config == Bitmap.Config.ARGB_8888) bitmap else bitmap.copy(Bitmap.Config.ARGB_8888, false)
        val id = GlResources.createTexture(src.width, src.height)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, id)
        GLUtils.texSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, src)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        val err = GLES20.glGetError()
        if (err != GLES20.GL_NO_ERROR) {
            GlResources.deleteTexture(id)
            throw EngineException(EngineErrorCode.gpuUnavailable, "texture upload failed 0x${Integer.toHexString(err)}")
        }
        SourceTexture(id, src.width, src.height, transform = SourceTexture.TOP_DOWN, premultiplied = src.hasAlpha() && src.isPremultiplied)
    }

    /** Deletes a texture made by [upload]. */
    fun delete(texture: SourceTexture) = current { GlResources.deleteTexture(texture.id) }

    private companion object {
        const val WARM_SIZE = 32
    }

    /** Releases every GL object and the context (the default display stays initialized: it is shared). */
    fun release() {
        if (released) return
        makeCurrent(pbuffer)
        canvas?.release()
        canvas = null
        compositor.release()
        programs.release()
        detachWindow()
        released = true
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        EGL14.eglDestroySurface(display, pbuffer)
        EGL14.eglDestroyContext(display, context)
    }
}
