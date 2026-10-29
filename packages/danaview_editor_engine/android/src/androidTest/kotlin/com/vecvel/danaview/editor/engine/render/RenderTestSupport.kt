// OWNER: AND-18
//
// Support for AND-18's instrumented tests (package render):
// - [RangeCut]: a preview plan cut to output frames [first, end) with times relative to the range
//   start, the shape CORE-37 sends with `renderPreview` (layer edges and map ends moved onto the
//   range's own grid; rate-1 maps stay rate 1).
// - [RenderRig]: the production RenderPreviewJobService of an engine (software-first decoders for
//   the barcode checks, as the export tests do: the emulators' hardware H.264 decoders drop leading
//   B-frames after a seek), rendering into `<cache>/danaview/editor/renders/` and awaiting the job
//   events.
// - [RenderedFile]: what a render file holds (frame count, sync samples, pts, tracks) and its
//   frames as bitmaps.
// - [RangeHarness]: AND-16's backend on its DirectHost drawing into a [CaptureSink] (AND-16's
//   BackendHarness and OutputSink, plus pixel capture of chosen frames), with [RangeHarness.bind]
//   installing AND-18's RenderedRangeBinding (the code RenderedRangeHandler runs for a session).
// Emulator numbers are logged under AND18, never as device numbers.

package com.vecvel.danaview.editor.engine.render

import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.util.Log
import com.vecvel.danaview.editor.engine.composition.ExportRunner
import com.vecvel.danaview.editor.engine.effects.EffectFixtures
import com.vecvel.danaview.editor.engine.fallback.DirectHost
import com.vecvel.danaview.editor.engine.fallback.Region
import com.vecvel.danaview.editor.engine.media.ExactFrames
import com.vecvel.danaview.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.danaview.editor.engine.preview.fallback.ContingencyPreviewBackend
import com.vecvel.danaview.editor.engine.preview.fallback.EngineStats
import com.vecvel.danaview.editor.engine.preview.fallback.SourceFrameIndex
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import com.vecvel.danaview.editor.engine.freeze.FreezeEngine
import com.vecvel.danaview.editor.engine.paused.await
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventMsg
import com.vecvel.danaview.editor.engine.pigeon.JobKindMsg
import com.vecvel.danaview.editor.engine.pigeon.JobPriorityMsg
import com.vecvel.danaview.editor.engine.pigeon.JobRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.RenderedRangeMsg
import com.vecvel.danaview.editor.engine.pigeon.ResolvedMediaMsg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.PlanWriter
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.preview.render.RenderPreviewJobService
import com.vecvel.danaview.editor.engine.preview.render.RenderPreviewServices
import com.vecvel.danaview.editor.engine.preview.render.RenderPreviewSpecs
import com.vecvel.danaview.editor.engine.preview.render.RenderRanges
import com.vecvel.danaview.editor.engine.preview.render.RenderedRangeBinding
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.math.roundToLong

const val AND18_TAG = "AND18"

fun log18(msg: String) = Log.i(AND18_TAG, msg)

/** Range plans (file header). */
object RangeCut {
    /** [plan] cut to output frames [first, end) of its grid, times relative to the range start. */
    fun cut(plan: RenderPlan, first: Long, end: Long, rev: Long = plan.rev): RenderPlan {
        val g = FrameGrid.of(plan.canvas.gridFps)
        val s = g.timeOfFrame(first)
        val e = g.timeOfFrame(end)
        fun shift(t: Long): Long = if (g.isOnGrid(t)) g.timeOfFrame(g.frameIndexOf(t) - first) else t - s
        val layers = plan.layers.filter { it.t0 < e && it.t1 > s }.map { l ->
            require(l.anim.isEmpty() && l.cmasks.all { it.anim.isEmpty() }) { "RangeCut does not move keyframes" }
            val a = maxOf(l.t0, s)
            val b = minOf(l.t1, e)
            val map = l.map.mapNotNull { seg ->
                val sa = maxOf(seg.t0, a)
                val sb = minOf(seg.t1, b)
                if (sb <= sa) return@mapNotNull null
                val n0 = shift(sa)
                val n1 = shift(sb)
                val s0 = seg.sourceAt(sa.toDouble()).roundToLong()
                val s1 = if (seg.s1 - seg.s0 == seg.t1 - seg.t0) s0 + (n1 - n0) else seg.sourceAt(sb.toDouble()).roundToLong()
                MapSegment(n0, n1, s0, s1)
            }
            l.copy(t0 = shift(a), t1 = shift(b), map = map)
        }
        val used = layers.mapNotNull { it.asset }.toSet()
        val cut = RenderPlan(
            rev = rev, target = PlanTarget.PREVIEW, canvas = plan.canvas, durUs = g.timeOfFrame(end - first),
            assets = plan.assets.filterKeys { it in used }, layers = layers.sortedWith(PlanValidator::compareLayers), audio = emptyList(),
        )
        assertEquals("cut plan valid", emptyList<Any>(), PlanValidator.validate(cut))
        return cut
    }
}

/** The render-preview job service of [engine] (file header). */
class RenderRig(val engine: FreezeEngine, softwareDecoders: Boolean = true) {
    val service: RenderPreviewJobService = RenderPreviewServices.of(engine.ctx).jobs.apply {
        if (softwareDecoders) assetLoaderFactory = { ExportRunner.softwareFirstAssetLoader() }
        effectAssets = EffectFixtures.assets
        maxLongSideOverride = 1920
    }
    val rendersDir: File = RenderPreviewSpecs.rendersDir(engine.paths)

    fun output(name: String): File = File(rendersDir, "$name.mp4")

    fun request(out: File, plan: RenderPlan, priority: JobPriorityMsg = JobPriorityMsg.BACKGROUND) = JobRequestMsg(
        kind = JobKindMsg.RENDER_PREVIEW,
        media = ResolvedMediaMsg("file://" + out.absolutePath, "render", isProxy = false),
        priority = priority,
        outputPath = out.absolutePath,
        plan = PlanWriter.planBytes(plan),
    )

    /** Starts a render of [range] into [out]; returns the job id (or throws the start failure). */
    fun start(range: RenderPlan, out: File, priority: JobPriorityMsg = JobPriorityMsg.BACKGROUND): String {
        val req = request(out, range, priority)
        return await { cb -> engine.ctx.threads.jobs.execute { service.start(req, req.plan!!, req.outputPath!!, cb) } }
    }

    /** Renders [range] into `renders/<name>.mp4`; returns the file and the wall time in ms. */
    fun render(range: RenderPlan, name: String, timeoutMs: Long = 300_000): Pair<File, Long> {
        val out = output(name)
        val t0 = System.nanoTime()
        val id = start(range, out)
        val end = engine.awaitTerminal(id, timeoutMs)
        val ms = (System.nanoTime() - t0) / 1_000_000
        assertEquals("render $name: ${end.failure?.code} ${end.failure?.message}", EngineEventKindMsg.JOB_DONE, end.kind)
        val asset = end.jobDone!!.asset!!
        assertEquals(out.absolutePath, asset.path)
        assertEquals(out.length(), asset.sizeBytes)
        assertTrue("no part file left", !RenderPreviewSpecs.partFile(out).exists())
        return out to ms
    }

    /** Events of [jobId]. */
    fun events(jobId: String): List<EngineEventMsg> = synchronized(engine.events) { engine.events.filter { it.jobId == jobId } }

    /** A `RenderedRangeMsg` of output frames [first, end) on [grid] playing [file]. */
    fun msg(first: Long, end: Long, grid: FrameGrid, file: File): RenderedRangeMsg =
        RenderedRangeMsg(grid.timeOfFrame(first), grid.timeOfFrame(end), "file://" + file.absolutePath, file.nameWithoutExtension)
}

/** Facts of a render file (file header). */
class RenderedFile(val file: File) {
    val videoTracks: Int
    val audioTracks: Int
    val samples: Int
    val syncSamples: Int
    val pts: List<Long>
    val width: Int
    val height: Int

    init {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(file.absolutePath)
            var v = -1
            var vt = 0
            var at = 0
            for (i in 0 until ex.trackCount) {
                val mime = ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME).orEmpty()
                if (mime.startsWith("video/")) {
                    vt++
                    if (v < 0) v = i
                }
                if (mime.startsWith("audio/")) at++
            }
            videoTracks = vt
            audioTracks = at
            val f = ex.getTrackFormat(v)
            width = f.getInteger(MediaFormat.KEY_WIDTH)
            height = f.getInteger(MediaFormat.KEY_HEIGHT)
            ex.selectTrack(v)
            var n = 0
            var sync = 0
            val times = ArrayList<Long>()
            while (ex.sampleTime >= 0) {
                n++
                if (ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) sync++
                times += ex.sampleTime
                if (!ex.advance()) break
            }
            samples = n
            syncSamples = sync
            pts = times.sorted()
        } finally {
            ex.release()
        }
    }

    /** Frames [from, from + count) as bitmaps (by index; MediaMetadataRetriever, API 28+). */
    fun frames(from: Int, count: Int): List<Bitmap> {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(file.absolutePath)
            val out = ArrayList<Bitmap>()
            var i = from
            while (i < from + count) {
                val n = minOf(8, from + count - i)
                out += r.getFramesAtIndex(i, n)
                i += n
            }
            return out
        } finally {
            r.release()
        }
    }

    override fun toString(): String = "${width}x$height, $samples samples ($syncSamples sync), video $videoTracks audio $audioTracks, ${file.length() / 1024} KiB"
}

/** One presented frame: output frame (from pts), region barcodes, arrival, and pixels when kept. */
class Shown(val k: Long, val ptsUs: Long, val readings: Map<String, Int?>, val atNs: Long, val rgba: ByteArray?)

/**
 * The SurfaceProducer stand-in of [RangeHarness] (AND-16's OutputSink, plus the RGBA pixels of the
 * output frames listed in [keep]).
 */
class CaptureSink(val width: Int, val height: Int, val fps: Int, private val regions: List<Region>) : AutoCloseable {
    private val thread = HandlerThread("and18-sink").apply { start() }
    val reader: ImageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 4)
    val frames: MutableList<Shown> = CopyOnWriteArrayList()

    /** Output frames whose pixels are kept (all when [keepAll]). */
    val keep: MutableSet<Long> = java.util.Collections.newSetFromMap(ConcurrentHashMap())
    @Volatile var keepAll = false

    /**
     * Also keeps the pixels of the first [keepFirstCount] presented frames whose k is in
     * [keepFirstIn], whichever frames a loaded emulator happens to present (not a fixed k list).
     */
    @Volatile var keepFirstIn: LongRange? = null
    @Volatile var keepFirstCount = 0
    private var keptFirst = 0

    init {
        reader.setOnImageAvailableListener({ r ->
            while (true) {
                val img = try {
                    r.acquireNextImage()
                } catch (_: IllegalStateException) {
                    null
                } ?: break
                try {
                    val plane = img.planes[0]
                    val buf = plane.buffer
                    val stride = plane.rowStride
                    val bytes = ByteArray(stride * (img.height - 1) + img.width * 4)
                    buf.position(0)
                    buf.get(bytes, 0, minOf(bytes.size, buf.remaining()))
                    val readings = regions.associate { it.name to FrameBarcode.decode(bytes, img.width, img.height, stride, region = it.barcode) }
                    val pts = img.timestamp / 1000L
                    val k = FrameGrid.of(fps).frameIndexNearest(pts)
                    val first = keepFirstIn?.let { k in it && keptFirst < keepFirstCount } == true
                    if (first) keptFirst++
                    val px = if (keepAll || first || k in keep) {
                        val tight = ByteArray(img.width * img.height * 4)
                        for (y in 0 until img.height) System.arraycopy(bytes, y * stride, tight, y * img.width * 4, img.width * 4)
                        tight
                    } else {
                        null
                    }
                    frames += Shown(k, pts, readings, System.nanoTime(), px)
                } catch (_: IllegalStateException) {
                } finally {
                    img.close()
                }
            }
        }, Handler(thread.looper))
    }

    fun clear() = frames.clear()

    /** Starts keeping the pixels of the first [count] presented frames with k in [range]. */
    fun keepFirst(range: LongRange, count: Int) {
        keepFirstCount = 0
        keepFirstIn = null
        keptFirst = 0
        keepFirstCount = count
        keepFirstIn = range
    }

    fun stopKeepingFirst() {
        keepFirstIn = null
    }

    fun awaitK(k: Long, timeoutMs: Long = 20_000): Shown {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            frames.lastOrNull { it.k == k }?.let { return it }
            Thread.sleep(2)
        }
        error("frame $k never presented (${frames.takeLast(5).map { it.k }})")
    }

    override fun close() {
        reader.close()
        thread.quitSafely()
    }
}

/** RGBA (tight rows) → Bitmap. */
fun rgbaBitmap(rgba: ByteArray, w: Int, h: Int): Bitmap =
    Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).apply { copyPixelsFromBuffer(ByteBuffer.wrap(rgba)) }

/**
 * AND-16's ContingencyPreviewBackend on a DirectHost drawing into a [CaptureSink] (AND-16's
 * BackendHarness with pixel capture), plus AND-18's [RenderRig] on the same engine.
 */
class RangeHarness(
    name: String,
    val plan: RenderPlan,
    regions: List<Region>,
    config: ContingencyPreviewBackend.Config = ContingencyPreviewBackend.Config(liveBudget = 6),
) : AutoCloseable {
    val engine = FreezeEngine(name)
    val host = DirectHost(engine, plan)
    val sink = CaptureSink(plan.canvas.w, plan.canvas.h, plan.canvas.fps, regions)
    val backend = ContingencyPreviewBackend(
        config.also {
            if (it.effectAssets == null) it.effectAssets = EffectFixtures.assets
            if (it.codecSelector == null) it.codecSelector = ExactFrames.softwareFirst
        },
    )
    val grid: FrameGrid = FrameGrid.of(plan.canvas.fps)
    val rig = RenderRig(engine)

    init {
        engine.ctx.sourceFrames.codecSelector = ExactFrames.softwareFirst
        await<Unit> { cb -> onPreview { backend.open(host, cb) } }
        check(!backend.usesStillsFallback) { "the contingency engine did not open (stills fallback)" }
        await<Unit> { cb -> onPreview { backend.rebuild(plan, cb) } }
        onPreview { backend.setRenderSize(plan.canvas.w, plan.canvas.h) }
        await<Unit> { cb -> onPreview { backend.attachSurface(sink.reader.surface, plan.canvas.w, plan.canvas.h, cb) } }
    }

    fun onPreview(block: () -> Unit) = engine.ctx.threads.preview.execute(block)

    fun stats(): EngineStats = await { cb -> backend.stats(cb) }

    /** Exact seek to [k]; the latency until frameDisplayed(k) in ms (−1: timeout). */
    fun seekExact(k: Long, timeoutMs: Long = 20_000): Double {
        val before = host.displayed.size
        val t0 = System.nanoTime()
        await<Unit> { cb -> onPreview { backend.seek(k, true, cb) } }
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (host.displayed.drop(before).contains(k)) return (System.nanoTime() - t0) / 1e6
            if (host.failures.isNotEmpty()) error("backend failed: ${host.failures.first()}")
            Thread.sleep(1)
        }
        return -1.0
    }

    fun play(from: Long) = await<Unit> { cb -> onPreview { backend.play(from, null, cb) } }

    fun pause(): Long = await { cb -> onPreview { backend.pause(cb) } }

    /**
     * Plays from [from] until the end (or [timeoutMs]); [during] is polled on this thread while it
     * plays until it returns true.
     */
    fun playToEnd(from: Long, timeoutMs: Long, during: (() -> Boolean)? = null): Boolean {
        host.endedAt = null
        play(from)
        var hook = during
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (host.endedAt != null) return true
            if (host.failures.isNotEmpty()) error("backend failed: ${host.failures.first()}")
            if (hook != null && hook()) hook = null
            Thread.sleep(1)
        }
        pause()
        return false
    }

    /** Swaps the plan snapshot on danaview-preview (a param patch: no rebuild, as PreviewSession does). */
    fun publish(next: RenderPlan, touched: Set<String>) = await<Unit> { cb ->
        onPreview {
            host.snapshot.set(host.snapshot.get().withPlan(next, touched))
            cb(Result.success(Unit))
        }
    }

    /**
     * The same param patch published on danaview-gl between two composites (the engine reads the
     * snapshot once per composite there): returns the last output frame composited before the new
     * snapshot became visible (-1: none), so every frame presented with a larger k was composited
     * after it.
     */
    fun publishBetweenFrames(next: RenderPlan, touched: Set<String>): Long = await { cb ->
        engine.ctx.threads.gl.execute {
            host.snapshot.set(host.snapshot.get().withPlan(next, touched))
            cb(Result.success(host.displayed.lastOrNull() ?: -1L))
        }
    }

    /** AND-18's binding with [ranges] (the code RenderedRangeHandler runs for a PreviewSession). */
    fun bind(ranges: List<RenderedRangeMsg>): RenderedRangeBinding {
        val handler = requireNotNull(engine.ctx.threads.preview.handler)
        val binding = await<RenderedRangeBinding> { cb ->
            onPreview {
                val b = RenderedRangeBinding(backend, host.snapshot, handler)
                b.apply(RenderRanges.entries(ranges, grid))
                cb(Result.success(b))
            }
        }
        // The rebuild runs on danaview-gl after the worker built the range deck plan; a stats round
        // trip after a short wait orders it.
        Thread.sleep(300)
        stats()
        return binding
    }

    override fun close() {
        try {
            await<Unit> { cb -> onPreview { backend.release(cb) } }
            await<Unit> { cb -> host.renderer.dispose(cb) }
        } finally {
            sink.close()
            try {
                engine.ctx.sourceFrames.trim(CacheTrimLevelMsg.CLEAR_ALL)
            } catch (_: Throwable) {
            }
            SourceFrameIndex.clear()
            engine.close()
        }
    }
}
