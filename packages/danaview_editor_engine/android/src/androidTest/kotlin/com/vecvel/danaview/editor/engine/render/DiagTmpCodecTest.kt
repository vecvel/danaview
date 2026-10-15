// TEMPORARY DIAGNOSTIC (AND-18 off-by-one investigation); delete before finishing.
package com.vecvel.danaview.editor.engine.render

import android.graphics.ImageFormat
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.opengl.GLES20
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.fallback.FallbackPlans
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import org.junit.Test
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList

class DiagTmpCodecTest {
    private val args = InstrumentationRegistry.getArguments()

    /** Decodes source frames [from, to) of [file] with [codecName] into a YUV ImageReader; returns (frame, barcode) per output. */
    private fun decode(file: File, codecName: String, from: Int, to: Int, pts: List<Long>): List<Pair<Int, Int?>> {
        val ex = MediaExtractor()
        ex.setDataSource(file.absolutePath)
        val track = (0 until ex.trackCount).first { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)!!.startsWith("video/") }
        ex.selectTrack(track)
        val fmt = ex.getTrackFormat(track)
        val w = fmt.getInteger(MediaFormat.KEY_WIDTH)
        val h = fmt.getInteger(MediaFormat.KEY_HEIGHT)
        val thread = HandlerThread("diag-reader").apply { start() }
        val reader = ImageReader.newInstance(w, h, ImageFormat.YUV_420_888, 8)
        val out = CopyOnWriteArrayList<Pair<Int, Int?>>()
        reader.setOnImageAvailableListener({ r ->
            val img = r.acquireNextImage() ?: return@setOnImageAvailableListener
            try {
                val y = img.planes[0]
                val buf = y.buffer
                val rgba = ByteArray(w * h * 4)
                for (row in 0 until h) for (x in 0 until w) {
                    val v = buf.get(row * y.rowStride + x * y.pixelStride)
                    val p = (row * w + x) * 4
                    rgba[p] = v; rgba[p + 1] = v; rgba[p + 2] = v; rgba[p + 3] = -1
                }
                val t = img.timestamp / 1000
                val k = pts.indexOfFirst { kotlin.math.abs(it - t) <= 1 }
                out += k to FrameBarcode.decode(rgba, w, h)
            } finally {
                img.close()
            }
        }, Handler(thread.looper))
        val codec = MediaCodec.createByCodecName(codecName)
        fmt.setInteger("allow-frame-drop", 0)
        codec.configure(fmt, reader.surface, null, 0)
        codec.start()
        ex.seekTo(pts[from], MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        val endUs = pts[to - 1]
        var inputDone = false
        var outputDone = false
        val info = MediaCodec.BufferInfo()
        var released = 0
        while (!outputDone) {
            if (!inputDone) {
                val i = codec.dequeueInputBuffer(2_000)
                if (i >= 0) {
                    val t = ex.sampleTime
                    if (t < 0 || t > endUs) {
                        codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        val n = ex.readSampleData(codec.getInputBuffer(i)!!, 0)
                        codec.queueInputBuffer(i, 0, n, t, 0)
                        ex.advance()
                    }
                }
            }
            val o = codec.dequeueOutputBuffer(info, 2_000)
            if (o >= 0) {
                val render = info.size > 0 && info.presentationTimeUs >= pts[from]
                codec.releaseOutputBuffer(o, render)
                if (render) released++
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
            }
        }
        val deadline = System.currentTimeMillis() + 3_000
        while (out.size < released && System.currentTimeMillis() < deadline) Thread.sleep(5)
        codec.stop()
        codec.release()
        ex.release()
        reader.close()
        thread.quitSafely()
        return out.toList()
    }

    /** As [decode], into a SurfaceTexture drawn with GL and read back (Media3's consumer), at most [maxPending] frames in flight. */
    private fun decodeGl(file: File, codecName: String, from: Int, to: Int, pts: List<Long>, maxPending: Int): List<Pair<Int, Int?>> {
        val ex = MediaExtractor()
        ex.setDataSource(file.absolutePath)
        val track = (0 until ex.trackCount).first { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)!!.startsWith("video/") }
        ex.selectTrack(track)
        val fmt = ex.getTrackFormat(track)
        val w = fmt.getInteger(MediaFormat.KEY_WIDTH)
        val h = fmt.getInteger(MediaFormat.KEY_HEIGHT)
        val thread = HandlerThread("diag-gl").apply { start() }
        val handler = Handler(thread.looper)
        val out = CopyOnWriteArrayList<Pair<Int, Int?>>()
        val consumed = java.util.concurrent.atomic.AtomicInteger()
        lateinit var st: android.graphics.SurfaceTexture
        lateinit var surface: android.view.Surface
        var display = android.opengl.EGL14.EGL_NO_DISPLAY
        var ctx = android.opengl.EGL14.EGL_NO_CONTEXT
        var pb = android.opengl.EGL14.EGL_NO_SURFACE
        var prog = 0
        var fbo = 0
        val latch = java.util.concurrent.CountDownLatch(1)
        handler.post {
            display = android.opengl.EGL14.eglGetDisplay(android.opengl.EGL14.EGL_DEFAULT_DISPLAY)
            val v = IntArray(2)
            android.opengl.EGL14.eglInitialize(display, v, 0, v, 1)
            val cfgs = arrayOfNulls<android.opengl.EGLConfig>(1)
            val n = IntArray(1)
            android.opengl.EGL14.eglChooseConfig(display, intArrayOf(android.opengl.EGL14.EGL_RED_SIZE, 8, android.opengl.EGL14.EGL_GREEN_SIZE, 8, android.opengl.EGL14.EGL_BLUE_SIZE, 8, android.opengl.EGL14.EGL_ALPHA_SIZE, 8, android.opengl.EGL14.EGL_RENDERABLE_TYPE, android.opengl.EGL14.EGL_OPENGL_ES2_BIT, android.opengl.EGL14.EGL_SURFACE_TYPE, android.opengl.EGL14.EGL_PBUFFER_BIT, android.opengl.EGL14.EGL_NONE), 0, cfgs, 0, 1, n, 0)
            ctx = android.opengl.EGL14.eglCreateContext(display, cfgs[0], android.opengl.EGL14.EGL_NO_CONTEXT, intArrayOf(android.opengl.EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, android.opengl.EGL14.EGL_NONE), 0)
            pb = android.opengl.EGL14.eglCreatePbufferSurface(display, cfgs[0], intArrayOf(android.opengl.EGL14.EGL_WIDTH, 1, android.opengl.EGL14.EGL_HEIGHT, 1, android.opengl.EGL14.EGL_NONE), 0)
            android.opengl.EGL14.eglMakeCurrent(display, pb, pb, ctx)
            val t = IntArray(1)
            GLES20.glGenTextures(1, t, 0)
            GLES20.glBindTexture(android.opengl.GLES11Ext.GL_TEXTURE_EXTERNAL_OES, t[0])
            GLES20.glTexParameteri(android.opengl.GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(android.opengl.GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            val ft = IntArray(1)
            GLES20.glGenTextures(1, ft, 0)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, ft[0])
            GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, w, h, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null)
            val fb = IntArray(1)
            GLES20.glGenFramebuffers(1, fb, 0)
            fbo = fb[0]
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
            GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, ft[0], 0)
            fun sh(type: Int, src: String) = GLES20.glCreateShader(type).also { GLES20.glShaderSource(it, src); GLES20.glCompileShader(it) }
            prog = GLES20.glCreateProgram()
            GLES20.glAttachShader(prog, sh(GLES20.GL_VERTEX_SHADER, "attribute vec2 p; uniform mat4 m; varying vec2 uv; void main(){ uv = (m * vec4((p + 1.0) * 0.5, 0.0, 1.0)).xy; gl_Position = vec4(p, 0.0, 1.0); }"))
            GLES20.glAttachShader(prog, sh(GLES20.GL_FRAGMENT_SHADER, "#extension GL_OES_EGL_image_external : require\nprecision mediump float; varying vec2 uv; uniform samplerExternalOES s; void main(){ gl_FragColor = texture2D(s, uv); }"))
            GLES20.glLinkProgram(prog)
            st = android.graphics.SurfaceTexture(t[0])
            st.setOnFrameAvailableListener({
                st.updateTexImage()
                val ts = st.timestamp / 1000
                val m = FloatArray(16)
                st.getTransformMatrix(m)
                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
                GLES20.glViewport(0, 0, w, h)
                GLES20.glUseProgram(prog)
                GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
                GLES20.glBindTexture(android.opengl.GLES11Ext.GL_TEXTURE_EXTERNAL_OES, t[0])
                GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(prog, "m"), 1, false, m, 0)
                val quad = java.nio.ByteBuffer.allocateDirect(32).order(java.nio.ByteOrder.nativeOrder()).asFloatBuffer().put(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)).also { it.position(0) }
                val loc = GLES20.glGetAttribLocation(prog, "p")
                GLES20.glEnableVertexAttribArray(loc)
                GLES20.glVertexAttribPointer(loc, 2, GLES20.GL_FLOAT, false, 0, quad)
                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
                val buf = java.nio.ByteBuffer.allocateDirect(w * h * 4)
                GLES20.glReadPixels(0, 0, w, h, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buf)
                val raw = ByteArray(w * h * 4)
                buf.get(raw)
                val up = ByteArray(raw.size)
                for (y in 0 until h) System.arraycopy(raw, (h - 1 - y) * w * 4, up, y * w * 4, w * 4)
                val k = pts.indexOfFirst { kotlin.math.abs(it - ts) <= 1 }
                out += k to (FrameBarcode.decode(up, w, h) ?: FrameBarcode.decode(raw, w, h)?.let { -it })
                (args.getString("probeSlowMs")?.toLong() ?: 0L).let { if (it > 0) Thread.sleep(it) }
                consumed.incrementAndGet()
            }, handler)
            surface = android.view.Surface(st)
            latch.countDown()
        }
        latch.await()
        val codec = MediaCodec.createByCodecName(codecName)
        fmt.setInteger("allow-frame-drop", 0)
        codec.configure(fmt, surface, null, 0)
        codec.start()
        ex.seekTo(pts[from], MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        val endUs = pts[to - 1]
        var inputDone = false
        var outputDone = false
        val info = MediaCodec.BufferInfo()
        var released = 0
        var held = -1
        var heldRender = false
        var heldEos = false
        while (!outputDone) {
            if (!inputDone) {
                val i = codec.dequeueInputBuffer(1_000)
                if (i >= 0) {
                    val t = ex.sampleTime
                    if (t < 0 || t > endUs) {
                        codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                    } else {
                        val n = ex.readSampleData(codec.getInputBuffer(i)!!, 0)
                        codec.queueInputBuffer(i, 0, n, t, 0)
                        ex.advance()
                    }
                }
            }
            if (held < 0) {
                val o = codec.dequeueOutputBuffer(info, 1_000)
                if (o >= 0) {
                    held = o
                    heldRender = info.size > 0 && info.presentationTimeUs >= pts[from]
                    heldEos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                }
            }
            if (held >= 0 && (!heldRender || released - consumed.get() < maxPending)) {
                codec.releaseOutputBuffer(held, heldRender)
                if (heldRender) released++
                if (heldEos) outputDone = true
                held = -1
            } else if (held >= 0) {
                Thread.sleep(1)
            }
        }
        val deadline = System.currentTimeMillis() + 3_000
        while (consumed.get() < released && System.currentTimeMillis() < deadline) Thread.sleep(5)
        codec.stop()
        codec.release()
        ex.release()
        val done = java.util.concurrent.CountDownLatch(1)
        handler.post {
            st.release()
            surface.release()
            android.opengl.EGL14.eglMakeCurrent(display, android.opengl.EGL14.EGL_NO_SURFACE, android.opengl.EGL14.EGL_NO_SURFACE, android.opengl.EGL14.EGL_NO_CONTEXT)
            android.opengl.EGL14.eglDestroySurface(display, pb)
            android.opengl.EGL14.eglDestroyContext(display, ctx)
            done.countDown()
        }
        done.await()
        thread.quitSafely()
        return out.toList()
    }

    @Test
    fun probe() {
        val fps = 24
        val reps = args.getString("probeReps")?.toInt() ?: 10
        val codecName = args.getString("probeCodec") ?: "c2.android.avc.decoder"
        val frames = (fps * 8).toLong()
        val base = FallbackPlans.plan(fps, frames, listOf(FallbackPlans.mainLayer(fps, frames, offset = 0)))
        var lightF: File? = null
        RangeHarness("pcodec_light", base, emptyList()).use { lh -> lightF = lh.rig.render(RangeCut.cut(base, 0, frames), "pcodec_light").first }
        val light = lightF!!
        val pts = RenderedFile(light).pts
        var bad = 0
        val par = args.getString("probeParallel")?.toInt() ?: 1
        val spin = args.getString("probeSpin")?.toInt() ?: 0
        val stop = java.util.concurrent.atomic.AtomicBoolean(false)
        val spinners = (0 until spin).map { Thread { var x = 0L; while (!stop.get()) { x = x * 31 + 7 } }.apply { isDaemon = true; start() } }
        val badCount = java.util.concurrent.atomic.AtomicInteger()
        val workers = (0 until par).map { wi ->
            Thread {
                repeat(reps) { rep ->
                    for ((a, b) in listOf(48 to 70, 120 to 132, 156 to 165, 30 to 36, 100 to 106)) {
                        val res = if (args.getString("probeGl") == "1") decodeGl(light, codecName, a, b, pts, args.getString("probePending")?.toInt() ?: 5) else decode(light, codecName, a, b, pts)
                        val wrong = res.filter { (k, got) -> k != got }
                        val missing = (a until b).filter { k -> res.none { it.first == k } }
                        if (wrong.isNotEmpty() || missing.isNotEmpty()) {
                            badCount.incrementAndGet()
                            log18("PCODEC w$wi rep $rep [$a,$b) $codecName: outputs ${res.size} ${res.map { it.first }}, wrong ${wrong.size} ${wrong.take(6)}, missing ${missing.take(6)}")
                        }
                    }
                }
            }.apply { start() }
        }
        workers.forEach { it.join() }
        stop.set(true)
        bad = badCount.get()
        log18("PCODEC SUMMARY $codecName reps=$reps par=$par spin=$spin bad=$bad")
    }
}
