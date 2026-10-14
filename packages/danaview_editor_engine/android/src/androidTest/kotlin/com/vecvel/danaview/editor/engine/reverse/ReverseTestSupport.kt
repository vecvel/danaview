@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-07
//
// Support for the AND-07 instrumented tests: an engine context with its own roots and events, a
// cancellable JobControl, software-first decoders for the intermediate Transformer (the x86_64
// emulator's goldfish H.264 decoder drops a B-frame of the ENG-05 fixtures, AND-05/AND-08), output
// inspection (video PTS with edit lists applied, barcodes of every frame, track facts, decoded
// PCM through AND-04's PcmDecoder) and samplers of the work directory and the process memory.

package com.vecvel.danaview.editor.engine.reverse

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.os.Debug
import androidx.annotation.OptIn
import androidx.media3.common.util.Clock
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSourceBitmapLoader
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.inspector.MediaExtractorCompat
import androidx.media3.transformer.AssetLoader
import androidx.media3.transformer.DefaultAssetLoaderFactory
import androidx.media3.transformer.DefaultDecoderFactory
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineEventSink
import com.vecvel.danaview.editor.engine.core.EngineThreads
import com.vecvel.danaview.editor.engine.core.JobControl
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.media.PcmDecoder
import com.vecvel.danaview.editor.engine.media.ReverseMath
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventMsg
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import com.vecvel.danaview.editor.engine.support.decode
import org.junit.Assert.fail
import java.io.File
import java.util.Collections
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.abs

/** A JobControl the test can cancel. */
class ReverseControl(override val jobId: String = "reverse-test") : JobControl {
    private val cancelled = AtomicBoolean(false)
    @Volatile var lastProgress = 0.0
    override val isCancelled: Boolean get() = cancelled.get()
    override fun reportProgress(fraction: Double) {
        lastProgress = fraction
    }

    fun cancel() = cancelled.set(true)
}

/** An engine context with roots under the app's cache/files dirs, plus its events. */
class ReverseEngine(name: String) {
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

    /** A rendition path below derived/. */
    fun output(name: String): File = File(paths.derived, "$name.mp4")

    /** Reverse work directories left in work/. */
    fun workLeftovers(): List<String> = paths.work.list()?.filter { it.startsWith("reverse-") }.orEmpty()

    /** The job's final event (done or failure). */
    fun awaitTerminal(jobId: String, timeoutMs: Long = 300_000): EngineEventMsg {
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

    /** The highest progress reported for [jobId]. */
    fun progress(jobId: String): Double = synchronized(events) {
        events.filter { it.jobId == jobId && it.kind == EngineEventKindMsg.PROGRESS }.maxOfOrNull { it.progress ?: 0.0 } ?: 0.0
    }
}

object ReverseDecoders {
    /** A Transformer asset loader whose decoder list puts software decoders first. */
    fun softwareFirst(context: Context): AssetLoader.Factory = DefaultAssetLoaderFactory(
        context,
        DefaultDecoderFactory.Builder(context)
            .setMediaCodecSelector { mime, secure, tunneling ->
                MediaCodecUtil.getDecoderInfos(mime, secure, tunneling).sortedBy { if (it.softwareOnly) 0 else 1 }
            }
            .build(),
        Clock.DEFAULT,
        DefaultMediaSourceFactory(context),
        DataSourceBitmapLoader.Builder(context).build(),
    )
}

/** Facts of a rendition or a fixture. */
class Clip(val file: File) {
    /** Video presentation times (µs, edit lists applied), ascending. */
    val videoPts: LongArray
    val videoDurationUs: Long
    val width: Int
    val height: Int
    val rotation: Int
    val audioMime: String?
    val videoMime: String

    init {
        val ex = MediaExtractorCompat(TestFixtures.targetContext)
        try {
            ex.setDataSource(file.absolutePath)
            val formats = (0 until ex.trackCount).map { ex.getTrackFormat(it) }
            val v = formats.indexOfFirst { it.getString(MediaFormat.KEY_MIME)!!.startsWith("video/") }
            val vf = formats[v]
            videoMime = vf.getString(MediaFormat.KEY_MIME)!!
            width = vf.getInteger(MediaFormat.KEY_WIDTH)
            height = vf.getInteger(MediaFormat.KEY_HEIGHT)
            rotation = if (vf.containsKey(MediaFormat.KEY_ROTATION)) vf.getInteger(MediaFormat.KEY_ROTATION) else 0
            videoDurationUs = if (vf.containsKey(MediaFormat.KEY_DURATION)) vf.getLong(MediaFormat.KEY_DURATION) else -1
            audioMime = formats.firstOrNull { it.getString(MediaFormat.KEY_MIME)!!.startsWith("audio/") }?.getString(MediaFormat.KEY_MIME)
            ex.selectTrack(v)
            val pts = ArrayList<Long>()
            while (true) {
                val t = ex.sampleTime
                if (t < 0) break
                pts += t
                if (!ex.advance()) break
            }
            videoPts = pts.sorted().toLongArray()
        } finally {
            ex.release()
        }
    }

    /** The barcode of every video frame in presentation order (null = unreadable). */
    fun barcodes(): List<Int?> {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(file.absolutePath)
            val out = ArrayList<Int?>()
            var i = 0
            while (i < videoPts.size) {
                val n = minOf(10, videoPts.size - i)
                for (b in r.getFramesAtIndex(i, n)) {
                    out += FrameBarcode.decode(b)
                    b.recycle()
                }
                i += n
            }
            return out
        } finally {
            r.release()
        }
    }

    /** One displayed frame (rotation applied) at index [i]. */
    fun frameAt(i: Int): Bitmap {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(file.absolutePath)
            return r.getFrameAtIndex(i)!!
        } finally {
            r.release()
        }
    }
}

/** Mono PCM (channel 0) of a file's first audio track, through AND-04's PcmDecoder (edit lists and priming honoured). */
class Pcm(val rate: Int, val samples: FloatArray) {
    /** [first, last] sample-time intervals (µs) where |x| exceeds [threshold], merged across gaps < [gapUs]. */
    fun bursts(threshold: Float = 0.05f, gapUs: Long = 5_000): List<Pair<Long, Long>> {
        val out = ArrayList<Pair<Long, Long>>()
        var start = -1L
        var last = -1L
        for (i in samples.indices) {
            if (abs(samples[i]) <= threshold) continue
            val t = i * 1_000_000L / rate
            if (start >= 0 && t - last <= gapUs) {
                last = t
            } else {
                if (start >= 0) out += Pair(start, last)
                start = t
                last = t
            }
        }
        if (start >= 0) out += Pair(start, last)
        return out
    }

    /** RMS of [fromUs, toUs). */
    fun rms(fromUs: Long, toUs: Long): Double {
        val a = (fromUs * rate / 1_000_000).toInt().coerceIn(0, samples.size)
        val b = (toUs * rate / 1_000_000).toInt().coerceIn(a, samples.size)
        var sum = 0.0
        for (i in a until b) sum += samples[i].toDouble() * samples[i]
        return if (b > a) Math.sqrt(sum / (b - a)) else 0.0
    }

    val durationUs: Long get() = samples.size * 1_000_000L / rate

    companion object {
        fun of(ctx: EngineContext, file: File): Pcm {
            PcmDecoder(ctx).open(file.absolutePath).use { stream ->
                val parts = ArrayList<FloatArray>()
                while (true) {
                    val chunk = stream.read() ?: break
                    parts += FloatArray(chunk.size / stream.channels) { chunk[it * stream.channels] }
                }
                return Pcm(stream.sampleRate, ReverseMath.concat(parts))
            }
        }
    }
}

/** Polls the bytes of a directory tree and the process memory while a job runs. */
class Samplers(private val work: File) : AutoCloseable {
    val peakWorkBytes = AtomicLong()
    val peakWorkFiles = AtomicLong()
    val baselinePssKb: Long
    val peakPssKb = AtomicLong()
    val baselineNativeKb: Long
    val peakNativeKb = AtomicLong()
    val baselineJavaKb: Long
    val peakJavaKb = AtomicLong()
    private val running = AtomicBoolean(true)
    private val thread: Thread

    init {
        Runtime.getRuntime().gc()
        System.runFinalization()
        Runtime.getRuntime().gc()
        baselinePssKb = Debug.getPss()
        baselineNativeKb = Debug.getNativeHeapAllocatedSize() / 1024
        baselineJavaKb = javaKb()
        thread = Thread({
            var n = 0
            while (running.get()) {
                val files = work.walkTopDown().filter { it.isFile }.toList()
                peakWorkBytes.accumulateAndGet(files.sumOf { it.length() }, ::maxOf)
                peakWorkFiles.accumulateAndGet(files.size.toLong(), ::maxOf)
                if (n++ % 10 == 0) {
                    peakPssKb.accumulateAndGet(Debug.getPss(), ::maxOf)
                    peakNativeKb.accumulateAndGet(Debug.getNativeHeapAllocatedSize() / 1024, ::maxOf)
                    peakJavaKb.accumulateAndGet(javaKb(), ::maxOf)
                }
                Thread.sleep(10)
            }
        }, "reverse-test-sampler").apply {
            isDaemon = true
            start()
        }
    }

    private fun javaKb(): Long = (Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory()) / 1024

    val pssDeltaMb: Double get() = (peakPssKb.get() - baselinePssKb) / 1024.0
    val nativeDeltaMb: Double get() = (peakNativeKb.get() - baselineNativeKb) / 1024.0
    val javaDeltaMb: Double get() = (peakJavaKb.get() - baselineJavaKb) / 1024.0

    override fun close() {
        running.set(false)
        thread.join(2_000)
    }
}

object ReverseFixtures {
    /** A fixture copied to the app cache. */
    fun file(name: String): File = TestFixtures.copyToCache(FixtureTree.ENGINE, "media/$name")

    /** P(k) of a CFR fixture: floor(k * 1e6 / fps). */
    fun pts(k: Int, fps: Int): Long = Math.floorDiv(k * 1_000_000L, fps.toLong())

    /** Presentation ticks of vfr_720p.mp4 (manifest, timescale 600). */
    fun vfrTicks(): LongArray {
        val manifest = org.json.JSONObject(TestFixtures.readText(FixtureTree.ENGINE, "media/manifest.json"))
        val ticks = manifest.getJSONObject("files").getJSONObject("vfr_720p.mp4").getJSONObject("video").getJSONArray("ptsTicks")
        return LongArray(ticks.length()) { ticks.getLong(it) }
    }

    /** End tick of vfr_720p.mp4. */
    fun vfrEndTick(): Long = org.json.JSONObject(TestFixtures.readText(FixtureTree.ENGINE, "media/manifest.json"))
        .getJSONObject("files").getJSONObject("vfr_720p.mp4").getJSONObject("video").getLong("endTick")
}
