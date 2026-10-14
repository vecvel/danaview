@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-11

// Instrumented test support for AND-11: an engine context with its own roots under the test app's
// cache (one per test), the production ExportCoordinator driven through its glue-facing API on the
// danaview-export lane, engine events collected from the EventHub, plan builders over ENG-05's
// committed fixtures (and API-04's sprite fixture), and readers of the exported file (track formats
// and sample-entry fourccs, Media3-extracted video PTS, decoded output audio through AND-04's
// PcmStream, which applies the AAC priming edit list as a player does).
// Emulator frame checks install software-first decoders through `assetLoaderFactory` (AND-08 measured
// fact 1: the goldfish H.264 decoder drops B-pyramid frames even in a plain transcode); production
// keeps Transformer's default asset loader.

package com.vecvel.danaview.editor.engine.export

import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.inspector.MediaExtractorCompat
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.composition.ExportRunner
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineEventSink
import com.vecvel.danaview.editor.engine.core.EngineThreads
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.media.PcmDecoder
import com.vecvel.danaview.editor.engine.pigeon.DetachedHandoffMsg
import com.vecvel.danaview.editor.engine.pigeon.EncodeSettingsMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportContainerMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportJobRecordMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportPreflightMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportProgressMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportResultMsg
import com.vecvel.danaview.editor.engine.pigeon.FailureMsg
import com.vecvel.danaview.editor.engine.pigeon.VideoCodecMsg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanWriter
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import java.io.Closeable
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

const val EXPORT_TEST_TAG = "DanaviewExportTest"

/** One engine context with private roots and the production coordinator (file header). */
class ExportHarness(name: String, fixedRoot: Boolean = false) : Closeable {
    val app = TestFixtures.targetContext.applicationContext
    val root = File(app.cacheDir, if (fixedRoot) "and11/$name" else "and11/$name-${System.nanoTime()}")
    val paths: Paths = Paths.fromDart(File(root, "cache/danaview/editor").absolutePath, File(root, "files/danaview/editor").absolutePath)
    val ctx = EngineContext(app, EngineThreads.android())
    val events = CopyOnWriteArrayList<EngineEventMsg>()
    private val sink = EngineEventSink { events.add(it) }
    private var attached = false
    val coordinator: ExportCoordinator get() = ctx.exports

    init {
        if (!fixedRoot) root.deleteRecursively()
        ctx.installRoots(paths)
        attach()
    }

    fun attach() {
        if (attached) return
        InstrumentationRegistry.getInstrumentation().runOnMainSync { ctx.events.attach(sink) }
        attached = true
    }

    fun detach() {
        if (!attached) return
        InstrumentationRegistry.getInstrumentation().runOnMainSync { ctx.events.detach(sink) }
        attached = false
    }

    /** Software-first decoders for frame checks (file header). */
    fun softwareDecoders() {
        coordinator.assetLoaderFactory = { ExportRunner.softwareFirstAssetLoader() }
    }

    fun output(name: String): File = File(paths.work, "export-$name.mp4")

    private fun <T> onExportLane(timeoutSec: Long = 60, block: ((Result<T>) -> Unit) -> Unit): T {
        val latch = CountDownLatch(1)
        val out = AtomicReference<Result<T>>()
        ctx.threads.export.execute {
            block { r ->
                out.set(r)
                latch.countDown()
            }
        }
        check(latch.await(timeoutSec, TimeUnit.SECONDS)) { "export lane call timed out" }
        return out.get().getOrThrow()
    }

    fun preflight(plan: RenderPlan, settings: EncodeSettingsMsg): ExportPreflightMsg =
        onExportLane { coordinator.preflight(PlanWriter.planBytes(plan), settings, it) }

    fun start(plan: RenderPlan, settings: EncodeSettingsMsg, out: File, whenDetached: DetachedHandoffMsg = DetachedHandoffMsg.SAVE_TO_GALLERY): String =
        onExportLane { coordinator.start(PlanWriter.planBytes(plan), settings, out.absolutePath, "Export test", whenDetached, it) }

    fun cancel(jobId: String) = onExportLane<Unit> { coordinator.cancel(jobId, it) }

    fun activeJobs(): List<ExportJobRecordMsg> = onExportLane { coordinator.activeJobs(it) }

    fun consume(jobId: String) = onExportLane<Unit> {
        coordinator.consumeJobRecord(jobId)
        it(Result.success(Unit))
    }

    /** A finished job: its result or failure, every progress sample, and the wall time. */
    class Outcome(val jobId: String, val result: ExportResultMsg?, val failure: FailureMsg?, val progress: List<ExportProgressMsg>, val wallMs: Long) {
        val warnings: Set<String> get() = progress.flatMap { p -> p.warnings.map { it.code } }.toSet()

        fun requireResult(): ExportResultMsg = result ?: throw AssertionError("export failed: ${failure?.code} ${failure?.message}")
    }

    fun progress(jobId: String): List<ExportProgressMsg> =
        events.filter { it.jobId == jobId && it.kind == EngineEventKindMsg.EXPORT_PROGRESS }.mapNotNull { it.exportProgress }

    /** Waits for the terminal event of [jobId]. */
    fun await(jobId: String, timeoutSec: Long = 600, started: Long = System.nanoTime()): Outcome {
        val deadline = System.nanoTime() + timeoutSec * 1_000_000_000L
        while (System.nanoTime() < deadline) {
            val end = events.firstOrNull { it.jobId == jobId && (it.kind == EngineEventKindMsg.JOB_DONE || it.kind == EngineEventKindMsg.FAILURE) }
            if (end != null) {
                return Outcome(jobId, end.jobDone?.exportResult, end.failure, progress(jobId), (System.nanoTime() - started) / 1_000_000)
            }
            Thread.sleep(20)
        }
        throw AssertionError("export $jobId did not finish in $timeoutSec s")
    }

    /** Starts and awaits one export. */
    fun export(plan: RenderPlan, settings: EncodeSettingsMsg, name: String): Outcome {
        val t0 = System.nanoTime()
        val id = start(plan, settings, output(name))
        val o = await(id, started = t0)
        Log.i(EXPORT_TEST_TAG, "$name: ${if (o.result != null) "done" else "failed ${o.failure?.code}"} in ${o.wallMs} ms (emulator), encoder ${o.result?.videoEncoderName} hardware=${o.result?.hardwareEncoder}, warnings ${o.warnings}")
        return o
    }

    override fun close() {
        detach()
        for (lane in ctx.threads.started()) lane.quit()
        root.deleteRecursively()
    }
}

/** Settings messages. */
fun settings(
    w: Int = 1280,
    h: Int = 720,
    fps: Int = 30,
    codec: VideoCodecMsg = VideoCodecMsg.H264,
    videoBitrate: Long = 5_000_000,
    keyframeIntervalMs: Long = 1000,
) = EncodeSettingsMsg(
    container = ExportContainerMsg.MP4,
    codec = codec,
    width = w.toLong(),
    height = h.toLong(),
    fps = fps.toLong(),
    videoBitrate = videoBitrate,
    audioBitrate = 128_000,
    audioSampleRate = 48_000,
    audioChannels = 2,
    keyframeIntervalMs = keyframeIntervalMs,
    stripLocation = true,
)

/** Plan pieces over the committed fixtures. */
object ExportPlans {
    fun media(name: String): String = "file://" + TestFixtures.copyToCache(FixtureTree.ENGINE, "media/$name").absolutePath

    fun sprite(name: String): String = "file://" + TestFixtures.copyToCache(FixtureTree.ENGINE_API, "sprites/$name").absolutePath

    /**
     * A media layer of asset [asset] on the [grid] frames [k0, k1) showing source frame
     * [sourceFrame] of a [sourceFps] source at k0 (source time floored to the µs; the rule frame is
     * <= s + 500 µs), at [rate].
     */
    fun mediaLayer(
        id: String,
        z: Int,
        seq: Int,
        grid: FrameGrid,
        k0: Long,
        k1: Long,
        sourceFrame: Long,
        sourceFps: Int,
        asset: String = "md_src",
        base: PlanSize = PlanSize(1280.0, 720.0),
        rate: Double = 1.0,
    ): PlanLayer {
        val t0 = grid.timeOfFrame(k0)
        val t1 = grid.timeOfFrame(k1)
        val s0 = Math.floorDiv(sourceFrame * 1_000_000L, sourceFps.toLong())
        return PlanLayer(
            id = id, z = z, seq = seq, t0 = t0, t1 = t1, kind = PlanLayerKind.MEDIA, asset = asset,
            map = listOf(MapSegment(t0, t1, s0, s0 + Math.round((t1 - t0) * rate))), base = base,
        )
    }
}

/** Reads exported files. */
object ExportedFile {
    class Track(val mime: String, val format: MediaFormat)

    /** Track formats (platform MediaExtractor). */
    fun tracks(f: File): List<Track> {
        val ex = android.media.MediaExtractor()
        try {
            ex.setDataSource(f.absolutePath)
            return (0 until ex.trackCount).map { i -> ex.getTrackFormat(i).let { Track(it.getString(MediaFormat.KEY_MIME)!!, it) } }
        } finally {
            ex.release()
        }
    }

    fun video(f: File): Track = tracks(f).single { it.mime.startsWith("video/") }

    fun audio(f: File): Track = tracks(f).single { it.mime.startsWith("audio/") }

    /** Whether the file contains the 4-byte box/sample-entry type [fourcc] (e.g. `hvc1`, `avc1`). */
    fun hasFourcc(f: File, fourcc: String): Boolean {
        val bytes = f.readBytes()
        val pattern = fourcc.toByteArray(Charsets.US_ASCII)
        outer@ for (i in 0..bytes.size - pattern.size) {
            for (j in pattern.indices) if (bytes[i + j] != pattern[j]) continue@outer
            return true
        }
        return false
    }

    /** Video sample presentation times through Media3's extractor (edit lists applied), sorted. */
    fun videoPts(f: File): List<Long> {
        val ex = MediaExtractorCompat(TestFixtures.targetContext)
        try {
            ex.setDataSource(f.absolutePath)
            val t = (0 until ex.trackCount).first { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)!!.startsWith("video/") }
            ex.selectTrack(t)
            val out = ArrayList<Long>()
            while (ex.sampleTime >= 0) {
                out += ex.sampleTime
                if (!ex.advance()) break
            }
            return out.sorted()
        } finally {
            ex.release()
        }
    }

    /** Rotation metadata in degrees (MediaMetadataRetriever). */
    fun rotation(f: File): Int {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(f.absolutePath)
            return r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toInt() ?: 0
        } finally {
            r.release()
        }
    }

    /** Mean luma (0..255) of every video frame, in presentation order. */
    fun meanLuma(f: File, frameCount: Int): List<Double> {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(f.absolutePath)
            val out = ArrayList<Double>()
            var i = 0
            while (i < frameCount) {
                val n = minOf(10, frameCount - i)
                for (b in r.getFramesAtIndex(i, n)) {
                    val px = IntArray(b.width * b.height)
                    b.getPixels(px, 0, b.width, 0, 0, b.width, b.height)
                    var sum = 0L
                    for (c in px) sum += ((c shr 16 and 0xFF) * 299 + (c shr 8 and 0xFF) * 587 + (c and 0xFF) * 114) / 1000
                    out += sum.toDouble() / px.size
                    b.recycle()
                }
                i += n
            }
            return out
        } finally {
            r.release()
        }
    }

    /** Decoded output audio (content time 0 = first sample) through AND-04's PcmStream. */
    class Pcm(val sampleRate: Int, val channels: Int, val samples: FloatArray) {
        val frames: Int get() = samples.size / channels

        val durationUs: Long get() = frames * 1_000_000L / sampleRate

        /** Peak |sample| over every channel. */
        fun peak(): Float = samples.maxOfOrNull { kotlin.math.abs(it) } ?: 0f

        /** RMS over every channel, dBFS. */
        fun rmsDb(): Double {
            if (samples.isEmpty()) return Double.NEGATIVE_INFINITY
            val ms = samples.sumOf { it.toDouble() * it } / samples.size
            return if (ms <= 0) Double.NEGATIVE_INFINITY else 10 * kotlin.math.log10(ms)
        }

        /** Content time (µs) of the first frame >= [fromUs] whose channel-0 |sample| exceeds [threshold]. */
        fun onsetUs(fromUs: Long, threshold: Float = 0.05f): Long? {
            val from = (fromUs * sampleRate / 1_000_000L).toInt().coerceAtLeast(0)
            for (i in from until frames) if (kotlin.math.abs(samples[i * channels]) > threshold) return i * 1_000_000L / sampleRate
            return null
        }
    }

    fun decodeAudio(ctx: EngineContext, f: File): Pcm {
        PcmDecoder(ctx).open("file://" + f.absolutePath).use { s ->
            val chunks = ArrayList<FloatArray>()
            while (true) chunks += s.read() ?: break
            val all = FloatArray(chunks.sumOf { it.size })
            var p = 0
            for (c in chunks) {
                c.copyInto(all, p)
                p += c.size
            }
            return Pcm(s.sampleRate, s.channels, all)
        }
    }
}
