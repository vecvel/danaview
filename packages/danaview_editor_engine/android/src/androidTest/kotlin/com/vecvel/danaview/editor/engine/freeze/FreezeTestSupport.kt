@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-06
//
// Support for the AND-06 instrumented tests: an engine context with its own roots and event
// capture, a cancellable JobControl, the D-04 frame times of ENG-05's fixtures, and the colour
// reference of `sampleColor`: the same frame decoded by the platform software H.264 decoder into
// YUV 4:2:0 (video range) and converted with the BT.709 matrix (gamma-encoded R'G'B', colour
// management off, ARCH §13), 3x3 averaged around the point (the iOS IOS-06 reference method).

package com.vecvel.danaview.editor.engine.freeze

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import androidx.annotation.OptIn
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.inspector.MediaExtractorCompat
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineEventSink
import com.vecvel.danaview.editor.engine.core.EngineThreads
import com.vecvel.danaview.editor.engine.core.JobControl
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventMsg
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import com.vecvel.danaview.editor.engine.support.decode
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import java.io.File
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.min

/** A JobControl the test can cancel. */
class FreezeControl(override val jobId: String = "freeze-test") : JobControl {
    private val cancelled = AtomicBoolean(false)
    @Volatile var lastProgress = 0.0
    override val isCancelled: Boolean get() = cancelled.get()
    override fun reportProgress(fraction: Double) {
        lastProgress = fraction
    }

    fun cancel() = cancelled.set(true)
}

/** An engine context with roots under the app's cache/files dirs, plus its events. */
class FreezeEngine(name: String) {
    val ctx: EngineContext
    val paths: Paths
    val events: MutableList<EngineEventMsg> = Collections.synchronizedList(ArrayList())
    private val sink = EngineEventSink { events.add(it) }

    init {
        val app = TestFixtures.targetContext.applicationContext
        ctx = EngineContext(app, EngineThreads.android())
        val cache = File(app.cacheDir, "$name/danaview/editor")
        val support = File(app.filesDir, "$name/danaview/editor")
        cache.deleteRecursively()
        support.parentFile?.deleteRecursively()
        paths = Paths.fromDart(cache.absolutePath, support.absolutePath)
        ctx.installRoots(paths)
        InstrumentationRegistry.getInstrumentation().runOnMainSync { ctx.events.attach(sink) }
    }

    fun close() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync { ctx.events.detach(sink) }
        ctx.threads.shutdown()
    }

    /** A still path below projects/<id>/assets/stills/. */
    fun still(name: String): File = File(paths.projects, "p1/assets/stills/$name.png")

    /** The job's final event (done or failure). */
    fun awaitTerminal(jobId: String, timeoutMs: Long = 120_000): EngineEventMsg {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            synchronized(events) {
                events.lastOrNull { it.jobId == jobId && (it.kind == EngineEventKindMsg.JOB_DONE || it.kind == EngineEventKindMsg.FAILURE) }
            }?.let { return it }
            Thread.sleep(20)
        }
        fail("job did not end within $timeoutMs ms")
        error("unreachable")
    }

    /** Starts [request] through the registry and returns the job id. */
    fun start(request: com.vecvel.danaview.editor.engine.pigeon.JobRequestMsg): String {
        val latch = CountDownLatch(1)
        var id: Result<String>? = null
        ctx.jobs.start(request) {
            id = it
            latch.countDown()
        }
        assertTrue(latch.await(10, TimeUnit.SECONDS))
        return id!!.getOrThrow()
    }
}

object FreezeFixtures {
    /** A fixture copied to the app cache. */
    fun file(name: String): File = TestFixtures.copyToCache(FixtureTree.ENGINE, "media/$name")

    /** P(k) of a CFR fixture: floor(k * 1e6 / fps) (timescale ticks floored to µs, edit list applied). */
    fun pts(k: Int, fps: Int): Long = Math.floorDiv(k * 1_000_000L, fps.toLong())

    /** The plan grid time timeOfFrame(k) = ceil(k * 1e6 / fps) (ARCH §5). */
    fun timeOfFrame(k: Int, fps: Int): Long = Math.floorDiv(k * 1_000_000L + fps - 1, fps.toLong())

    /** The barcode of a PNG still. */
    fun barcode(png: File): Int? {
        val bitmap = BitmapFactory.decodeFile(png.absolutePath) ?: return null
        try {
            return FrameBarcode.decode(bitmap)
        } finally {
            bitmap.recycle()
        }
    }

    /** The PNG's size. */
    fun size(png: File): Pair<Int, Int> {
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(png.absolutePath, o)
        return Pair(o.outWidth, o.outHeight)
    }

    /** Presentation ticks of vfr_720p.mp4 (manifest, timescale 600). */
    fun vfrTicks(): LongArray {
        val manifest = org.json.JSONObject(TestFixtures.readText(FixtureTree.ENGINE, "media/manifest.json"))
        val files = manifest.get("files")
        val entry = when (files) {
            is org.json.JSONArray -> (0 until files.length()).map { files.getJSONObject(it) }.first { it.optString("name") == "vfr_720p.mp4" || it.optString("file") == "vfr_720p.mp4" }
            is org.json.JSONObject -> files.getJSONObject("vfr_720p.mp4")
            else -> error("unexpected manifest layout")
        }
        val ticks = entry.getJSONObject("video").getJSONArray("ptsTicks")
        return LongArray(ticks.length()) { ticks.getLong(it) }
    }
}

/** Mean absolute difference per channel (0..255) of two same-size bitmaps. */
fun meanAbsDiff(a: Bitmap, b: Bitmap): Double {
    check(a.width == b.width && a.height == b.height) { "sizes differ: ${a.width}x${a.height} vs ${b.width}x${b.height}" }
    val pa = IntArray(a.width * a.height)
    val pb = IntArray(b.width * b.height)
    a.getPixels(pa, 0, a.width, 0, 0, a.width, a.height)
    b.getPixels(pb, 0, b.width, 0, 0, b.width, b.height)
    var sum = 0L
    for (i in pa.indices) {
        for (s in intArrayOf(16, 8, 0)) sum += kotlin.math.abs(((pa[i] shr s) and 0xFF) - ((pb[i] shr s) and 0xFF))
    }
    return sum.toDouble() / (pa.size * 3)
}

/** The sampleColor reference (file header). */
object YuvReference {
    class Frame(val width: Int, val height: Int, val y: ByteArray, val u: ByteArray, val v: ByteArray) {
        /** Video-range R'G'B' (0..1, clamped) of pixel ([x], [y]) with the BT.709 (or, [bt601], BT.601) matrix. */
        fun rgb(px: Int, py: Int, bt601: Boolean = false): DoubleArray {
            val yy = (y[py * width + px].toInt() and 0xFF) - 16.0
            val cb = (u[(py / 2) * (width / 2) + px / 2].toInt() and 0xFF) - 128.0
            val cr = (v[(py / 2) * (width / 2) + px / 2].toInt() and 0xFF) - 128.0
            val yn = yy / 219.0
            val cbn = cb / 224.0
            val crn = cr / 224.0
            if (bt601) {
                return doubleArrayOf(
                    (yn + 1.402 * crn).coerceIn(0.0, 1.0),
                    (yn - 0.344136 * cbn - 0.714136 * crn).coerceIn(0.0, 1.0),
                    (yn + 1.772 * cbn).coerceIn(0.0, 1.0),
                )
            }
            return doubleArrayOf(
                (yn + 1.5748 * crn).coerceIn(0.0, 1.0),
                (yn - 0.1873 * cbn - 0.4681 * crn).coerceIn(0.0, 1.0),
                (yn + 1.8556 * cbn).coerceIn(0.0, 1.0),
            )
        }

        /** 3x3 average of [rgb] around normalized ([nx], [ny]) (same window rule as the cache). */
        fun average(nx: Double, ny: Double, bt601: Boolean = false): DoubleArray {
            val cx = min(width - 1, max(0, Math.floor(nx * width).toInt()))
            val cy = min(height - 1, max(0, Math.floor(ny * height).toInt()))
            val x0 = min(max(0, cx - 1), width - 3)
            val y0 = min(max(0, cy - 1), height - 3)
            val sum = DoubleArray(3)
            for (dy in 0 until 3) for (dx in 0 until 3) {
                val c = rgb(x0 + dx, y0 + dy, bt601)
                for (i in 0 until 3) sum[i] += c[i]
            }
            return DoubleArray(3) { sum[it] / 9 }
        }

        /** The whole frame as ARGB (for the barcode check of the reference itself). */
        fun argb(): IntArray = IntArray(width * height) { i ->
            val c = rgb(i % width, i / width)
            (0xFF shl 24) or ((c[0] * 255 + 0.5).toInt() shl 16) or ((c[1] * 255 + 0.5).toInt() shl 8) or (c[2] * 255 + 0.5).toInt()
        }
    }

    /** Decodes the frame of [file] presented at [ptsUs] with the platform software H.264 decoder. */
    fun decode(file: File, ptsUs: Long): Frame {
        val extractor = MediaExtractorCompat(TestFixtures.targetContext)
        extractor.setDataSource(file.absolutePath)
        val track = (0 until extractor.trackCount).first { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)!!.startsWith("video/") }
        val format = extractor.getTrackFormat(track)
        extractor.selectTrack(track)
        extractor.seekTo(ptsUs, MediaExtractorCompat.SEEK_TO_PREVIOUS_SYNC)
        val mime = format.getString(MediaFormat.KEY_MIME)!!
        val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.first { info ->
            !info.isEncoder && info.isSoftwareOnly && info.supportedTypes.any { it.equals(mime, true) }
        }.name
        val codec = MediaCodec.createByCodecName(name)
        codec.configure(format, null, null, 0)
        codec.start()
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        try {
            val deadline = System.currentTimeMillis() + 30_000
            while (System.currentTimeMillis() < deadline) {
                if (!inputDone) {
                    val i = codec.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        val buf = codec.getInputBuffer(i)!!
                        val n = extractor.readSampleData(buf, 0)
                        if (n < 0) {
                            codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(i, 0, n, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val o = codec.dequeueOutputBuffer(info, 10_000)
                if (o >= 0) {
                    if (info.presentationTimeUs == ptsUs && info.size > 0) {
                        val image = codec.getOutputImage(o)!!
                        val crop = image.cropRect
                        val w = crop.width()
                        val h = crop.height()
                        fun plane(index: Int, pw: Int, ph: Int, ox: Int, oy: Int): ByteArray {
                            val p = image.planes[index]
                            val out = ByteArray(pw * ph)
                            val buf = p.buffer
                            for (yy in 0 until ph) for (xx in 0 until pw) {
                                out[yy * pw + xx] = buf.get((oy + yy) * p.rowStride + (ox + xx) * p.pixelStride)
                            }
                            return out
                        }
                        val frame = Frame(w, h, plane(0, w, h, crop.left, crop.top), plane(1, w / 2, h / 2, crop.left / 2, crop.top / 2), plane(2, w / 2, h / 2, crop.left / 2, crop.top / 2))
                        image.close()
                        codec.releaseOutputBuffer(o, false)
                        return frame
                    }
                    codec.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
            }
            error("frame at $ptsUs µs not decoded")
        } finally {
            codec.stop()
            codec.release()
            extractor.release()
        }
    }

    /** The barcode of the reference frame (checks that the reference is the right frame). */
    fun barcode(frame: Frame): Int? = FrameBarcode.decodeArgb(frame.argb(), frame.width, frame.height)
}
