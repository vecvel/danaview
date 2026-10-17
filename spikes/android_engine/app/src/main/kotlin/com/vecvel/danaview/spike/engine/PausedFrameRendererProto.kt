@file:OptIn(UnstableApi::class, ExperimentalApi::class)

package com.vecvel.danaview.spike.engine

import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.opengl.GLUtils
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import androidx.media3.common.MediaItem
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.inspector.frame.FrameExtractor
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * AND-01 prototype of AND-17's `PausedFrameRenderer` (ARCH §13.3 "Paused edits", D-36): while
 * paused, the player surface is detached and our own GL pass draws the frame at the playhead from
 * EXACT source frames ([FrameExtractor] with [SeekParameters.EXACT]) with the same place shader
 * as the Media3 effect ([PlaceShaders]) and the compositor's straight-alpha blend
 * (`glBlendFuncSeparate(SRC_ALPHA, ONE_MINUS_SRC_ALPHA, ONE, ONE_MINUS_SRC_ALPHA)`), bottom
 * sequence first, over the background solid.
 */
class PausedFrameRendererProto(
    private val context: Context,
    private val plan: SpikePlan,
    private val store: ParamStore,
) : AutoCloseable {
    data class Prefetch(val k: Long, val layers: Int, val wallMs: Double, val framePtsMs: Map<String, Long>)

    private val thread = HandlerThread("danaview-gl-paused").apply { start() }
    private val handler = Handler(thread.looper)
    private val extractors = ConcurrentHashMap<String, FrameExtractor>()

    /** Source bitmaps of the layers active at the prefetched frame, by layer id. */
    private val frames = ConcurrentHashMap<String, Bitmap>()
    private var prefetchedK = -1L

    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var config: EGLConfig? = null
    private var surface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var program: GlProgram? = null
    private val textures = HashMap<String, Int>()

    private fun <T> onGl(block: () -> T): T {
        val r = AtomicReference<Any?>()
        val f = AtomicReference<Throwable?>()
        val latch = CountDownLatch(1)
        handler.post {
            try {
                r.set(block())
            } catch (t: Throwable) {
                f.set(t)
            } finally {
                latch.countDown()
            }
        }
        check(latch.await(30, TimeUnit.SECONDS)) { "gl thread blocked" }
        f.get()?.let { throw it }
        @Suppress("UNCHECKED_CAST")
        return r.get() as T
    }

    private fun extractor(uri: String): FrameExtractor = extractors.getOrPut(uri) {
        // FrameExtractor must be built and used from a looper thread; its futures complete on it.
        FrameExtractor.Builder(context, MediaItem.fromUri(Uri.parse(uri)))
            .setSeekParameters(SeekParameters.EXACT)
            .build()
    }

    /**
     * Fetches the rule frame (ARCH §11.5) of every layer active at output frame [k]. FrameExtractor
     * takes milliseconds and shows the first frame with pts ≥ position, so the request is the rule
     * frame's PTS floored to ms.
     */
    fun prefetch(k: Long): Prefetch {
        val started = System.nanoTime()
        val t = GridTime.timeOfFrame(k, plan.fps)
        val active = activeLayers(t)
        val pts = HashMap<String, Long>()
        frames.clear()
        for (l in active) {
            val s = l.srcStartUs + ((t - GridTime.timeOfFrame(l.k0, plan.gridFps)) * l.speed.toDouble()).toLong()
            val rule = SpikeCompositionMapper.Companion.SourceFrameTimes.ruleFramePts(context, l.uri, s)
            val frame = onGl { extractor(l.uri) }.getFrame(rule / 1000).get(20, TimeUnit.SECONDS)
            val bmp = if (frame.bitmap.config == Bitmap.Config.HARDWARE) frame.bitmap.copy(Bitmap.Config.ARGB_8888, false) else frame.bitmap
            frames[l.id] = bmp
            pts[l.id] = frame.presentationTimeMs
        }
        prefetchedK = k
        return Prefetch(k, active.size, (System.nanoTime() - started) / 1e6, pts)
    }

    private fun activeLayers(t: Long): List<SpikeLayer> = plan.layers.filter {
        t >= GridTime.timeOfFrame(it.k0, plan.gridFps) && t < GridTime.timeOfFrame(it.k1, plan.gridFps)
    }

    /** Creates the EGL context and a window surface on [target] (the player surface must be detached). */
    fun attach(target: Surface) = onGl {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        check(EGL14.eglInitialize(display, version, 0, version, 1))
        val attribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val n = IntArray(1)
        check(EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, n, 0) && n[0] > 0) { "no EGL config" }
        config = configs[0]
        eglContext = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0)
        check(eglContext != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed 0x${Integer.toHexString(EGL14.eglGetError())}" }
        surface = EGL14.eglCreateWindowSurface(display, config, target, intArrayOf(EGL14.EGL_NONE), 0)
        check(surface != EGL14.EGL_NO_SURFACE) { "eglCreateWindowSurface failed 0x${Integer.toHexString(EGL14.eglGetError())}" }
        check(EGL14.eglMakeCurrent(display, surface, surface, eglContext))
        program = PlaceShaders.create()
    }

    /** Destroys the window surface so the player can reconnect to the same Surface. */
    fun detach() = onGl {
        if (display == EGL14.EGL_NO_DISPLAY) return@onGl
        for (tex in textures.values) GLES20.glDeleteTextures(1, intArrayOf(tex), 0)
        textures.clear()
        program?.delete()
        program = null
        EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
        if (surface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, surface)
        EGL14.eglDestroyContext(display, eglContext)
        EGL14.eglTerminate(display)
        surface = EGL14.EGL_NO_SURFACE
        eglContext = EGL14.EGL_NO_CONTEXT
        display = EGL14.EGL_NO_DISPLAY
    }

    /**
     * Draws output frame [k] with the current [store] params and swaps; returns the GL time in ms.
     * Uses the prefetched bitmaps (re-uploaded only when the layer set changes).
     */
    fun render(k: Long): Double = onGl {
        check(k == prefetchedK) { "frame $k not prefetched ($prefetchedK)" }
        val started = System.nanoTime()
        val p = program!!
        GLES20.glViewport(0, 0, plan.canvasW, plan.canvasH)
        val bg = plan.bgRgb()
        GLES20.glDisable(GLES20.GL_BLEND)
        GLES20.glClearColor(bg[0], bg[1], bg[2], 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        GLES20.glEnable(GLES20.GL_BLEND)
        android.opengl.GLES30.glBlendFuncSeparate(
            GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA, GLES20.GL_ONE, GLES20.GL_ONE_MINUS_SRC_ALPHA,
        )
        val pts = GridTime.platformTimeOfFrame(k, plan.fps)
        // Bottom sequence first; sequence 1 is the top (ARCH §13.3 "Sequence stack").
        for (seq in plan.visualSequenceCount downTo 1) {
            val params = store.activeAt(seq, pts, plan.fps) ?: continue
            val bmp = frames[params.id] ?: continue
            val tex = textures.getOrPut(params.id) {
                val ids = IntArray(1)
                GLES20.glGenTextures(1, ids, 0)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, ids[0])
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
                GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bmp, 0)
                ids[0]
            }
            PlaceShaders.draw(p, tex, params, plan.canvasW, plan.canvasH, flipY = true)
        }
        EGLExt.eglPresentationTimeANDROID(display, surface, pts * 1000)
        check(EGL14.eglSwapBuffers(display, surface)) { "swap failed 0x${Integer.toHexString(EGL14.eglGetError())}" }
        (System.nanoTime() - started) / 1e6
    }

    /** Drops cached textures (after a structural edit changes the layer set). */
    fun invalidateTextures() = onGl {
        for (tex in textures.values) GLES20.glDeleteTextures(1, intArrayOf(tex), 0)
        textures.clear()
    }

    override fun close() {
        try {
            detach()
            onGl { extractors.values.forEach { it.close() } }
        } finally {
            thread.quitSafely()
        }
    }
}
