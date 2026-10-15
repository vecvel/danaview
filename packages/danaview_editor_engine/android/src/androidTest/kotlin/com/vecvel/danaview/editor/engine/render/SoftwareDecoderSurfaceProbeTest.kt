// OWNER: AND-18
//
// MANUAL diagnostic (not part of the suite's pass count: it is skipped unless the instrumentation
// argument danaviewDecoderSurfaceProbe=true is given). It reproduces, without Media3 and without
// any engine code, the defect behind AND-18's intermittent stale render frames (and AND-08's
// CompositionExportTest stale inputs) on the API 35 emulator: frames that the software H.264
// decoder (c2.android.avc.decoder, which the instrumented tests select for exact frames) renders
// into a SurfaceTexture are sometimes sampled by GL with the pixels of an earlier output buffer
// (the barcode of an older frame, or none) under the correct timestamp. The same decodes read back
// through a CPU ImageReader were always exact, and the emulator's hardware decoder
// (c2.goldfish.h264.decoder) did not show it in Media3 renders; the queued buffers carry no
// acquire fence on the emulator, so a consumer has nothing to wait on.
//
// What it does: P decoders in parallel (plus CPU load in this process), each decoding short clips
// of ENG-05's 24 fps counter from a sync frame to end of stream into its own SurfaceTexture, at
// most 5 frames in flight like Media3's decoders on API 29+, the consumer slowed to 15 ms a frame
// like a loaded compositor; every frame is drawn on its own EGL context, read back with
// glReadPixels and its barcode compared with the frame its timestamp names. It fails on any wrong
// frame. The rate depends on the emulator's state (0 of 240 decodes on a fresh boot, 3-4 of 160
// after hours of instrumented runs), so this is evidence, not a deterministic test. On a real
// device (QA-04) it must pass. Run:
//   adb shell am instrument -w -e danaviewDecoderSurfaceProbe true \
//     -e class com.vecvel.danaview.editor.engine.render.SoftwareDecoderSurfaceProbeTest \
//     com.vecvel.danaview.editor.engine.test/androidx.test.runner.AndroidJUnitRunner
// Optional arguments: danaviewProbeCodec (default c2.android.avc.decoder), danaviewProbeReps (8).

package com.vecvel.danaview.editor.engine.render

import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.fallback.FallbackPlans
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class SoftwareDecoderSurfaceProbeTest {
    private val args = InstrumentationRegistry.getArguments()

    /** A SurfaceTexture consumer on its own GL thread that reads every frame's barcode back. */
    private class GlConsumer(private val w: Int, private val h: Int, private val pts: LongArray, private val delayMs: Long) {
        private val thread = HandlerThread("probe-gl").apply { start() }
        private val handler = Handler(thread.looper)
        val frames = CopyOnWriteArrayList<Pair<Int, Int?>>()
        val consumed = AtomicInteger()
        lateinit var surface: Surface
        private lateinit var st: SurfaceTexture
        private var display = EGL14.EGL_NO_DISPLAY
        private var context = EGL14.EGL_NO_CONTEXT
        private var pbuffer = EGL14.EGL_NO_SURFACE

        init {
            val ready = CountDownLatch(1)
            handler.post {
                setUp()
                ready.countDown()
            }
            ready.await()
        }

        private fun setUp() {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            val v = IntArray(2)
            EGL14.eglInitialize(display, v, 0, v, 1)
            val configs = arrayOfNulls<EGLConfig>(1)
            val n = IntArray(1)
            EGL14.eglChooseConfig(
                display,
                intArrayOf(
                    EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                    EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT, EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT, EGL14.EGL_NONE,
                ),
                0, configs, 0, 1, n, 0,
            )
            context = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
            pbuffer = EGL14.eglCreatePbufferSurface(display, configs[0], intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
            check(EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)) { "eglMakeCurrent" }
            val tex = IntArray(2)
            GLES20.glGenTextures(2, tex, 0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, tex[0])
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, tex[1])
            GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, w, h, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null)
            val fbo = IntArray(1)
            GLES20.glGenFramebuffers(1, fbo, 0)
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo[0])
            GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, tex[1], 0)
            fun shader(type: Int, src: String) = GLES20.glCreateShader(type).also { GLES20.glShaderSource(it, src); GLES20.glCompileShader(it) }
            val program = GLES20.glCreateProgram()
            GLES20.glAttachShader(program, shader(GLES20.GL_VERTEX_SHADER, "attribute vec2 p; uniform mat4 m; varying vec2 uv; void main() { uv = (m * vec4((p + 1.0) * 0.5, 0.0, 1.0)).xy; gl_Position = vec4(p, 0.0, 1.0); }"))
            GLES20.glAttachShader(program, shader(GLES20.GL_FRAGMENT_SHADER, "#extension GL_OES_EGL_image_external : require\nprecision mediump float; varying vec2 uv; uniform samplerExternalOES s; void main() { gl_FragColor = texture2D(s, uv); }"))
            GLES20.glLinkProgram(program)
            GLES20.glUseProgram(program)
            val quad = ByteBuffer.allocateDirect(32).order(ByteOrder.nativeOrder()).asFloatBuffer().put(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))
            quad.position(0)
            val loc = GLES20.glGetAttribLocation(program, "p")
            GLES20.glEnableVertexAttribArray(loc)
            GLES20.glVertexAttribPointer(loc, 2, GLES20.GL_FLOAT, false, 0, quad)
            val matrix = GLES20.glGetUniformLocation(program, "m")
            GLES20.glViewport(0, 0, w, h)
            st = SurfaceTexture(tex[0])
            val m = FloatArray(16)
            val readback = ByteBuffer.allocateDirect(w * h * 4)
            st.setOnFrameAvailableListener({
                st.updateTexImage()
                val ts = st.timestamp / 1000
                st.getTransformMatrix(m)
                GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
                GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, tex[0])
                GLES20.glUniformMatrix4fv(matrix, 1, false, m, 0)
                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
                readback.position(0)
                GLES20.glReadPixels(0, 0, w, h, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, readback)
                val raw = ByteArray(w * h * 4)
                readback.get(raw)
                // GL rows are bottom-up.
                val rows = ByteArray(raw.size)
                for (y in 0 until h) System.arraycopy(raw, (h - 1 - y) * w * 4, rows, y * w * 4, w * 4)
                frames += pts.indexOfFirst { kotlin.math.abs(it - ts) <= 1 } to FrameBarcode.decode(rows, w, h)
                if (delayMs > 0) Thread.sleep(delayMs)
                consumed.incrementAndGet()
            }, handler)
            surface = Surface(st)
        }

        fun release() {
            val done = CountDownLatch(1)
            handler.post {
                st.release()
                surface.release()
                EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
                EGL14.eglDestroySurface(display, pbuffer)
                EGL14.eglDestroyContext(display, context)
                done.countDown()
            }
            done.await()
            thread.quitSafely()
        }
    }

    /** Decodes frames [from, to) of [file] to end of stream with at most [maxPending] frames queued to the consumer. */
    private fun decode(file: File, codecName: String, from: Int, to: Int, pts: LongArray, maxPending: Int): List<Pair<Int, Int?>> {
        val ex = MediaExtractor()
        ex.setDataSource(file.absolutePath)
        val track = (0 until ex.trackCount).first { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)!!.startsWith("video/") }
        ex.selectTrack(track)
        val format = ex.getTrackFormat(track)
        val consumer = GlConsumer(format.getInteger(MediaFormat.KEY_WIDTH), format.getInteger(MediaFormat.KEY_HEIGHT), pts, CONSUMER_DELAY_MS)
        val codec = MediaCodec.createByCodecName(codecName)
        try {
            format.setInteger(MediaFormat.KEY_ALLOW_FRAME_DROP, 0)
            codec.configure(format, consumer.surface, null, 0)
            codec.start()
            ex.seekTo(pts[from], MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            var rendered = 0
            var held = -1
            var heldRender = false
            var heldEos = false
            while (!outputDone) {
                if (!inputDone) {
                    val i = codec.dequeueInputBuffer(1_000)
                    if (i >= 0) {
                        val t = ex.sampleTime
                        if (t < 0 || t > pts[to - 1]) {
                            codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(i, 0, ex.readSampleData(codec.getInputBuffer(i)!!, 0), t, 0)
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
                if (held >= 0 && (!heldRender || rendered - consumer.consumed.get() < maxPending)) {
                    codec.releaseOutputBuffer(held, heldRender)
                    if (heldRender) rendered++
                    if (heldEos) outputDone = true
                    held = -1
                } else if (held >= 0) {
                    Thread.sleep(1)
                }
            }
            val deadline = System.currentTimeMillis() + 5_000
            while (consumer.consumed.get() < rendered && System.currentTimeMillis() < deadline) Thread.sleep(5)
            return consumer.frames.toList()
        } finally {
            codec.release()
            ex.release()
            consumer.release()
        }
    }

    @Test
    fun softwareDecoderFramesSampledByGlAreExact() {
        assumeTrue("manual diagnostic: pass -e danaviewDecoderSurfaceProbe true", args.getString("danaviewDecoderSurfaceProbe") == "true")
        val codecName = args.getString("danaviewProbeCodec") ?: "c2.android.avc.decoder"
        val reps = args.getString("danaviewProbeReps")?.toInt() ?: 8
        val file = TestFixtures.copyToCache(FixtureTree.ENGINE, "media/${FallbackPlans.counterName(24)}")
        val pts = RenderedFile(file).pts.toLongArray()
        val stop = AtomicBoolean(false)
        val load = (0 until LOAD_THREADS).map { Thread { var x = 0L; while (!stop.get()) x = x * 31 + 7 }.apply { isDaemon = true; start() } }
        val wrong = CopyOnWriteArrayList<String>()
        val decodes = AtomicInteger()
        try {
            val workers = (0 until DECODERS).map { wi ->
                Thread {
                    repeat(reps) { rep ->
                        for ((a, b) in CLIPS) {
                            val frames = decode(file, codecName, a, b, pts, MAX_PENDING)
                            decodes.incrementAndGet()
                            val bad = frames.filter { (k, got) -> k != got } + (a until b).filter { k -> frames.none { it.first == k } }.map { it to -1 }
                            if (bad.isNotEmpty()) wrong += "decoder $wi rep $rep [$a, $b): (frame, barcode) ${bad.take(6)}"
                        }
                    }
                }.apply { start() }
            }
            workers.forEach { it.join() }
        } finally {
            stop.set(true)
            load.forEach { it.join(1_000) }
        }
        val line = "software decoder → SurfaceTexture → GL ($codecName, $DECODERS parallel, emulator unless run on a device): ${decodes.get()} decodes, ${wrong.size} with a wrong frame $wrong"
        log18(line)
        assertEquals(line, emptyList<String>(), wrong)
    }

    private companion object {
        const val DECODERS = 4
        const val LOAD_THREADS = 4
        const val MAX_PENDING = 5
        const val CONSUMER_DELAY_MS = 15L

        /** Source frame clips (each decoded from its sync frame to end of stream). */
        val CLIPS = listOf(48 to 70, 120 to 132, 156 to 165, 30 to 36, 100 to 106)
    }
}
