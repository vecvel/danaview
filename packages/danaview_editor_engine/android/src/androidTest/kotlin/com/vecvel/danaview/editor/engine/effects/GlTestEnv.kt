// OWNER: AND-09
//
// Instrumented test support for the GL effects: an offscreen EGL context (ES 3, else ES 2, 1×1
// pbuffer) current on a real `danaview-gl` lane (EngineThreads' HandlerLane for LaneSpec.GL, the
// only thread the effects package accepts besides Media3's), blocking execution on it, texture
// upload of top-down pixel rows (flipped to the GL orientation every effect texture uses) and
// readback to top-down rows. Pixel comparison metrics (mean / p99 absolute error, SSIM) for the
// ARCH §11.6 parity tolerance live in [ParityMetrics].

package com.vecvel.danaview.editor.engine.effects

import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES20
import com.vecvel.danaview.editor.engine.core.HandlerLane
import com.vecvel.danaview.editor.engine.core.LaneSpec
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.ceil

/** An EGL context on a danaview-gl lane (file header). Close it after the test. */
class GlTestEnv : AutoCloseable {
    val lane = HandlerLane(LaneSpec.GL)
    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var surface: EGLSurface = EGL14.EGL_NO_SURFACE

    /** Context major version obtained (3 or 2). */
    var contextVersion: Int = 0
        private set

    init {
        run {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            val v = IntArray(2)
            check(EGL14.eglInitialize(display, v, 0, v, 1)) { "eglInitialize" }
            fun choose(renderable: Int): EGLConfig? {
                val attribs = intArrayOf(
                    EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                    EGL14.EGL_RENDERABLE_TYPE, renderable, EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT, EGL14.EGL_NONE,
                )
                val configs = arrayOfNulls<EGLConfig>(1)
                val n = IntArray(1)
                return if (EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, n, 0) && n[0] > 0) configs[0] else null
            }
            var config = choose(EGLExt.EGL_OPENGL_ES3_BIT_KHR)
            contextVersion = 3
            if (config != null) {
                context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0)
            }
            if (config == null || context == EGL14.EGL_NO_CONTEXT) {
                config = checkNotNull(choose(EGL14.EGL_OPENGL_ES2_BIT)) { "no EGL config" }
                context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
                contextVersion = 2
            }
            check(context != EGL14.EGL_NO_CONTEXT) { "eglCreateContext 0x${Integer.toHexString(EGL14.eglGetError())}" }
            surface = EGL14.eglCreatePbufferSurface(display, config, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
            check(surface != EGL14.EGL_NO_SURFACE) { "pbuffer" }
            check(EGL14.eglMakeCurrent(display, surface, surface, context)) { "eglMakeCurrent" }
        }
    }

    /** Runs [block] on the GL lane and returns its result (rethrows its failure). */
    fun <T> run(block: () -> T): T {
        val result = AtomicReference<Any?>()
        val failure = AtomicReference<Throwable?>()
        val latch = CountDownLatch(1)
        lane.execute {
            try {
                result.set(block())
            } catch (t: Throwable) {
                failure.set(t)
            } finally {
                latch.countDown()
            }
        }
        check(latch.await(300, TimeUnit.SECONDS)) { "GL lane blocked" }
        failure.get()?.let { throw it }
        @Suppress("UNCHECKED_CAST")
        return result.get() as T
    }

    override fun close() {
        run {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            EGL14.eglDestroySurface(display, surface)
            EGL14.eglDestroyContext(display, context)
            EGL14.eglTerminate(display)
        }
        lane.quit()
    }

    companion object {
        /** Shader reader over the target app's assets (the library's danaview_shaders/). */
        val shaders: (String) -> String get() = ShaderSources.assetReader(TestFixtures.targetContext)

        /** An RGBA8 texture of top-down rows [rgba] (flipped to GL order). */
        fun uploadRgba8(rgba: ByteArray, w: Int, h: Int, filter: Int = GLES20.GL_LINEAR): Int {
            val buf = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder())
            for (y in h - 1 downTo 0) buf.put(rgba, y * w * 4, w * 4)
            buf.position(0)
            return GlResources.createTexture(w, h, pixels = buf, filter = filter)
        }

        /** An RGBA32F texture of top-down rows [rgba] (4 floats per texel). */
        fun uploadRgbaF(rgba: FloatArray, w: Int, h: Int): Int {
            val buf = ByteBuffer.allocateDirect(w * h * 16).order(ByteOrder.nativeOrder())
            val fb = buf.asFloatBuffer()
            for (y in h - 1 downTo 0) fb.put(rgba, y * w * 4, w * 4)
            return GlResources.createTexture(w, h, android.opengl.GLES30.GL_RGBA32F, GLES20.GL_RGBA, GLES20.GL_FLOAT, buf, GLES20.GL_LINEAR)
        }

        /** RGBA8 of the bound framebuffer ([w] × [h]), top-down rows. */
        fun readRgba8(w: Int, h: Int): ByteArray {
            val buf = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder())
            GLES20.glReadPixels(0, 0, w, h, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buf)
            val out = ByteArray(w * h * 4)
            for (y in 0 until h) {
                buf.position((h - 1 - y) * w * 4)
                buf.get(out, y * w * 4, w * 4)
            }
            return out
        }

        /** RGBA floats of the bound RGBA32F framebuffer, top-down rows. */
        fun readRgbaF(w: Int, h: Int): FloatArray {
            val buf = ByteBuffer.allocateDirect(w * h * 16).order(ByteOrder.nativeOrder())
            GLES20.glReadPixels(0, 0, w, h, GLES20.GL_RGBA, GLES20.GL_FLOAT, buf)
            val fb = buf.asFloatBuffer()
            val out = FloatArray(w * h * 4)
            for (y in 0 until h) {
                fb.position((h - 1 - y) * w * 4)
                fb.get(out, y * w * 4, w * 4)
            }
            return out
        }
    }
}

/** Error statistics of one comparison (values in [0, 1] units). */
data class ParityStats(val mean: Double, val p99: Double, val max: Double, val ssim: Double, val pixels: Int, val excluded: Int) {
    /** ARCH §11.6: mean ≤ 1.5/255, p99 ≤ 6/255, SSIM ≥ 0.98. */
    fun withinParity(): Boolean = mean <= MEAN && p99 <= P99 && ssim >= SSIM

    override fun toString(): String =
        "mean=%.3f/255 p99=%.2f/255 max=%.1f/255 ssim=%.4f px=%d excluded=%d".format(mean * 255, p99 * 255, max * 255, ssim, pixels, excluded)

    companion object {
        const val MEAN = 1.5 / 255
        const val P99 = 6.0 / 255
        const val SSIM = 0.98
    }
}

/** Parity metrics (file header). */
object ParityMetrics {
    /**
     * Compares RGB of [got] (RGBA, 4 values per px) and [want] (RGB or RGBA per [wantChannels]) over
     * pixels where [excluded] is false: mean and 99th percentile of the per-channel absolute error,
     * and mean SSIM over 7 × 7 windows of each channel free of excluded pixels.
     */
    fun compare(got: DoubleArray, want: DoubleArray, wantChannels: Int, w: Int, h: Int, excluded: BooleanArray): ParityStats {
        val errs = ArrayList<Double>()
        var sum = 0.0
        var max = 0.0
        for (i in 0 until w * h) {
            if (excluded[i]) continue
            for (c in 0 until 3) {
                val e = kotlin.math.abs(got[i * 4 + c] - want[i * wantChannels + c])
                errs += e
                sum += e
                if (e > max) max = e
            }
        }
        if (errs.isEmpty()) return ParityStats(0.0, 0.0, 0.0, 1.0, 0, w * h)
        errs.sort()
        val p99 = errs[minOf(errs.size - 1, ceil(errs.size * 0.99).toInt() - 1).coerceAtLeast(0)]
        return ParityStats(sum / errs.size, p99, max, ssim(got, want, wantChannels, w, h, excluded), errs.size / 3, excluded.count { it })
    }

    private fun ssim(a: DoubleArray, b: DoubleArray, bc: Int, w: Int, h: Int, excluded: BooleanArray): Double {
        val win = minOf(7, w, h)
        val c1 = (0.01 * 255) * (0.01 * 255)
        val c2 = (0.03 * 255) * (0.03 * 255)
        var total = 0.0
        var n = 0
        for (c in 0 until 3) for (y0 in 0..h - win) for (x0 in 0..w - win) {
            var skip = false
            var ma = 0.0
            var mb = 0.0
            for (y in y0 until y0 + win) for (x in x0 until x0 + win) {
                val i = y * w + x
                if (excluded[i]) { skip = true }
                ma += a[i * 4 + c] * 255
                mb += b[i * bc + c] * 255
            }
            if (skip) continue
            val k = (win * win).toDouble()
            ma /= k
            mb /= k
            var va = 0.0
            var vb = 0.0
            var cov = 0.0
            for (y in y0 until y0 + win) for (x in x0 until x0 + win) {
                val i = y * w + x
                val da = a[i * 4 + c] * 255 - ma
                val db = b[i * bc + c] * 255 - mb
                va += da * da
                vb += db * db
                cov += da * db
            }
            va /= k - 1
            vb /= k - 1
            cov /= k - 1
            total += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
            n++
        }
        return if (n == 0) 1.0 else total / n
    }

    /** Bytes (0..255) to [0, 1]. */
    fun unit(bytes: ByteArray): DoubleArray = DoubleArray(bytes.size) { (bytes[it].toInt() and 0xFF) / 255.0 }
}
