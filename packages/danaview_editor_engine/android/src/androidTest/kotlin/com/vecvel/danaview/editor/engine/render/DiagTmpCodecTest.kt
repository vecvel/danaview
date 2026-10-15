// TEMPORARY DIAGNOSTIC (AND-18 off-by-one investigation); delete before finishing.
package com.vecvel.danaview.editor.engine.render

import android.graphics.ImageFormat
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
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
        repeat(reps) { rep ->
            for ((a, b) in listOf(48 to 70, 120 to 132, 156 to 165, 0 to 96)) {
                val res = decode(light, codecName, a, b, pts)
                val wrong = res.filter { (k, got) -> k != got }
                val missing = (a until b).filter { k -> res.none { it.first == k } }
                if (wrong.isNotEmpty() || missing.isNotEmpty()) bad++
                log18("PCODEC rep $rep [$a,$b) $codecName: outputs ${res.size}, wrong ${wrong.size} ${wrong.take(6)}, missing ${missing.take(6)}")
            }
        }
        log18("PCODEC SUMMARY $codecName reps=$reps bad=$bad")
    }
}
