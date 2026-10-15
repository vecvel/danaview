// OWNER: AND-16
//
// Support for AND-16's instrumented tests (package fallback):
// - [FallbackPlans]: plans over ENG-05's frame counters (frame number = source frame index), among
//   them the grid-cut composition of AND-01 (3 slots, 6 layers, cuts at k ≡ 1, 2 mod 3, gaps) with
//   each slot in its own quadrant so every layer's barcode is read in its region.
// - [OutputSink]: the SurfaceProducer stand-in, an RGBA ImageReader that decodes the region barcodes
//   of every frame the backend presents and keys it by its presentation time (pts = P(k), D-35).
// - [DirectHost]: a PreviewBackendHost without a session (the backend under test drives the
//   Surface directly), recording frameDisplayed / frameDropped / stalled / ended / failed.
// - [BackendHarness]: a ContingencyPreviewBackend opened on a DirectHost with blocking helpers.
// Times are emulator numbers (logged under AND16), never device numbers.

package com.vecvel.danaview.editor.engine.fallback

import android.graphics.PixelFormat
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.effects.EffectFixtures
import com.vecvel.danaview.editor.engine.freeze.FreezeEngine
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.media.ExactFrames
import com.vecvel.danaview.editor.engine.paused.await
import com.vecvel.danaview.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.preview.EngineFrameSource
import com.vecvel.danaview.editor.engine.preview.FrameRange
import com.vecvel.danaview.editor.engine.preview.HandlerDebounceScheduler
import com.vecvel.danaview.editor.engine.preview.PausedFrameRenderer
import com.vecvel.danaview.editor.engine.preview.PreviewBackendHost
import com.vecvel.danaview.editor.engine.preview.PausedFrames
import com.vecvel.danaview.editor.engine.preview.SeekMath
import com.vecvel.danaview.editor.engine.preview.fallback.ContingencyPreviewBackend
import com.vecvel.danaview.editor.engine.preview.fallback.EngineStats
import com.vecvel.danaview.editor.engine.preview.fallback.RuleFrameMath
import com.vecvel.danaview.editor.engine.preview.fallback.SourceFrameIndex
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import com.vecvel.danaview.editor.engine.support.FrameBarcodeRegion
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals

const val AND16_TAG = "AND16"

/** A layer region of the output (canvas px). */
data class Region(val name: String, val x: Int, val y: Int, val w: Int, val h: Int) {
    val barcode: FrameBarcodeRegion get() = FrameBarcodeRegion(x, y, w, h)
}

/** Test plans (file header). */
object FallbackPlans {
    const val W = 640
    const val H = 360

    /** The counter fixture of [fps] (ENG-05: 8 s, frame number = frame index). */
    fun counterName(fps: Int): String = when (fps) {
        24 -> "frame_counter_720p24.mp4"
        25 -> "frame_counter_720p25.mp4"
        30 -> "frame_counter_1080p30.mp4"
        48 -> "frame_counter_720p48.mp4"
        60 -> "frame_counter_720p60.mp4"
        else -> error("no counter at $fps fps")
    }

    fun uri(name: String): String = "file://" + TestFixtures.copyToCache(FixtureTree.ENGINE, "media/$name").absolutePath

    fun counterAsset(fps: Int): PlanAsset {
        val (w, h) = if (fps == 30) 1920 to 1080 else 1280 to 720
        return PlanAsset(PlanAssetKind.VIDEO, uri(counterName(fps)), fp = "fp-counter$fps", w = w, h = h)
    }

    /** Quadrant regions: seq 0 top-left, seq 1 top-right, seq 2 bottom-left, seq 3 bottom-right. */
    val QUADRANTS = listOf(Region("s0", 0, 0, 320, 180), Region("s1", 320, 0, 320, 180), Region("s2", 0, 180, 320, 180), Region("s3", 320, 180, 320, 180))

    /** A media layer of `counter` showing source frame [sourceFrame] at output frame [k0] in quadrant [q]. */
    fun quadLayer(id: String, seq: Int, q: Int, k0: Long, k1: Long, sourceFrame: Long, fps: Int, z: Int = 10 + seq): PlanLayer {
        val g = FrameGrid.of(fps)
        val t0 = g.timeOfFrame(k0)
        val t1 = g.timeOfFrame(k1)
        val s0 = Math.floorDiv(sourceFrame * 1_000_000L, fps.toLong())
        val r = QUADRANTS[q]
        return PlanLayer(
            id = id, z = z, seq = seq, t0 = t0, t1 = t1, kind = PlanLayerKind.MEDIA, asset = "counter",
            map = listOf(MapSegment(t0, t1, s0, s0 + (t1 - t0))),
            base = PlanSize(W.toDouble(), H.toDouble()),
            xf = PlanTransform(cx = r.x + r.w / 2.0, cy = r.y + r.h / 2.0, s = 0.5),
        )
    }

    /** A full-canvas media layer (main track) showing source frame k + [offset] at output frame k. */
    fun mainLayer(fps: Int, frames: Long, offset: Long = 10, seq: Int = 0, id: String = "main#v"): PlanLayer {
        val g = FrameGrid.of(fps)
        val t1 = g.timeOfFrame(frames)
        val s0 = Math.floorDiv(offset * 1_000_000L, fps.toLong())
        return PlanLayer(
            id = id, z = seq, seq = seq, t0 = 0, t1 = t1, kind = PlanLayerKind.MEDIA, asset = "counter",
            map = listOf(MapSegment(0, t1, s0, s0 + t1)), base = PlanSize(W.toDouble(), H.toDouble()),
        )
    }

    fun plan(fps: Int, frames: Long, layers: List<PlanLayer>, rev: Long = 1, assets: Map<String, PlanAsset> = mapOf("counter" to counterAsset(fps))): RenderPlan {
        val p = RenderPlan(
            rev = rev, target = PlanTarget.PREVIEW, canvas = PlanCanvas(W, H, fps, bg = 0xFF203040.toInt()),
            durUs = FrameGrid.of(fps).timeOfFrame(frames), assets = assets,
            layers = layers.sortedWith(PlanValidator::compareLayers), audio = emptyList(),
        )
        assertEquals("plan valid", emptyList<Any>(), PlanValidator.validate(p))
        return p
    }

    /** A cut at fraction [frac] of [d] frames moved to the next frame k ≡ [residue] (mod 3) (AND-01). */
    fun cutAt(d: Long, frac: Double, residue: Int): Long {
        var k = (d * frac).toLong()
        while (Math.floorMod(k, 3L) != residue.toLong()) k++
        return k
    }

    /**
     * AND-01's grid-cut composition over 4 s at [fps]: slot 0 (top-left) A | B, C; slot 1 (top-right)
     * D; slot 2 (bottom-left) E, F; every edge at k ≡ 1 or 2 (mod 3), with gaps.
     */
    fun gridCut(fps: Int, seconds: Int = 4): RenderPlan {
        val d = (fps * seconds).toLong()
        val f = fps.toLong()
        val aEnd = cutAt(d, 0.26, 1)
        val bEnd = cutAt(d, 0.52, 2)
        val cStart = cutAt(d, 0.77, 2)
        val dStart = cutAt(d, 0.28, 1)
        val dEnd = cutAt(d, 0.54, 2)
        val eEnd = cutAt(d, 0.36, 1)
        val fStart = cutAt(d, 0.64, 2)
        val layers = listOf(
            quadLayer("A#v", 0, 0, 0, aEnd, (0.8 * f).toLong(), fps),
            quadLayer("B#v", 0, 0, aEnd, bEnd, (6.5 * f).toLong(), fps),
            quadLayer("C#v", 0, 0, cStart, d, (2.0 * f).toLong(), fps),
            quadLayer("D#v", 1, 1, dStart, dEnd, (4.0 * f).toLong(), fps),
            quadLayer("E#v", 2, 2, 0, eEnd, (5.5 * f).toLong(), fps),
            quadLayer("F#v", 2, 2, fStart, d, (1.0 * f).toLong(), fps),
        )
        return plan(fps, d, layers)
    }

    /**
     * The source frame index (counter barcode) [layer] shows at output frame [k]: the rule frame
     * (ARCH §11.5) in the source's real PTS table [pts] (frame index = position in the table), or null.
     */
    fun expected(plan: RenderPlan, layer: PlanLayer, k: Long, pts: LongArray): Int? {
        val g = FrameGrid.of(plan.canvas.fps)
        val t = g.timeOfFrame(k)
        if (!layer.covers(t)) return null
        val s = PausedFrames.sourceTimeUs(layer, t)
        val rule = RuleFrameMath.rule(pts, s)
        return java.util.Arrays.binarySearch(pts, rule)
    }

    /** What quadrant [q] (slot q) must show at output frame [k]: a barcode, or null for background. */
    fun expectedIn(plan: RenderPlan, q: Int, k: Long, pts: LongArray): Int? {
        val g = FrameGrid.of(plan.canvas.fps)
        val t = g.timeOfFrame(k)
        val l = plan.layers.firstOrNull { it.kind == PlanLayerKind.MEDIA && it.seq == q && it.covers(t) } ?: return null
        return expected(plan, l, k, pts)
    }

    /** The PTS table of the counter of [fps]. */
    fun pts(ctx: EngineContext, fps: Int): LongArray = SourceFrameIndex(ctx.appContext).frameTimes(counterAsset(fps).uri)
}

/** One presented frame: its output frame (from pts), region readings and arrival. */
class SinkFrame(val k: Long, val ptsUs: Long, val readings: Map<String, Int?>, val full: Int?, val atNs: Long)

/** The SurfaceProducer stand-in (file header). */
class OutputSink(val width: Int, val height: Int, val fps: Int, private val regions: List<Region>) : AutoCloseable {
    private val thread = HandlerThread("and16-sink").apply { start() }
    val reader: ImageReader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 4)
    val frames: MutableList<SinkFrame> = CopyOnWriteArrayList()
    private val count = AtomicInteger()

    @Volatile var keepPixels = false
    val lastPixels = AtomicReference<ByteArray?>()

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
                    val full = FrameBarcode.decode(bytes, img.width, img.height, stride)
                    val pts = img.timestamp / 1000L
                    frames += SinkFrame(FrameGrid.of(fps).frameIndexNearest(pts), pts, readings, full, System.nanoTime())
                    count.incrementAndGet()
                    if (keepPixels) {
                        val tight = ByteArray(img.width * img.height * 4)
                        for (y in 0 until img.height) System.arraycopy(bytes, y * stride, tight, y * img.width * 4, img.width * 4)
                        lastPixels.set(tight)
                    }
                } catch (_: IllegalStateException) {
                } finally {
                    img.close()
                }
            }
        }, Handler(thread.looper))
    }

    val frameCount: Int get() = count.get()

    fun clear() = frames.clear()

    /** Waits until a frame with output index [k] arrived. */
    fun awaitK(k: Long, timeoutMs: Long = 20_000): SinkFrame {
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

/** A PreviewBackendHost without a session (file header). */
class DirectHost(val engine: FreezeEngine, plan: RenderPlan) : PreviewBackendHost {
    override val sessionId: String = "and16-test"
    override val ctx: EngineContext get() = engine.ctx
    override val snapshot: AtomicReference<ParamSnapshot> = AtomicReference(ParamSnapshot.of(plan))
    override val renderer: PausedFrameRenderer = PausedFrameRenderer(engine.ctx.appContext, engine.ctx.threads.gl, EngineFrameSource(engine.ctx), snapshot, EffectFixtures.assets)
    override val previewLane = engine.ctx.threads.preview
    override val scheduler = HandlerDebounceScheduler(requireNotNull(previewLane.handler))
    override val frameCount: Long get() = SeekMath.frameCount(FrameGrid.of(snapshot.get().plan.canvas.fps), snapshot.get().plan.durUs)
    override val useProxies: Boolean = false

    val displayed: MutableList<Long> = CopyOnWriteArrayList()
    val dropped: MutableList<Long> = CopyOnWriteArrayList()
    val failures: MutableList<Throwable> = CopyOnWriteArrayList()
    val stalls = AtomicInteger()
    val recoveries = AtomicInteger()
    @Volatile var endedAt: Long? = null

    override fun frameDisplayed(k: Long) {
        displayed += k
    }

    override fun frameDropped(k: Long) {
        dropped += k
    }

    override fun stalled() {
        stalls.incrementAndGet()
    }

    override fun recovered() {
        recoveries.incrementAndGet()
    }

    override fun ended(k: Long) {
        endedAt = k
    }

    override fun failed(error: Throwable) {
        Log.w(AND16_TAG, "host failure", error)
        failures += error
    }
}

/** A ContingencyPreviewBackend on a DirectHost drawing into an [OutputSink] (file header). */
class BackendHarness(name: String, val plan: RenderPlan, regions: List<Region>, config: ContingencyPreviewBackend.Config = ContingencyPreviewBackend.Config()) : AutoCloseable {
    val engine = FreezeEngine(name)
    val host = DirectHost(engine, plan)
    val sink = OutputSink(plan.canvas.w, plan.canvas.h, plan.canvas.fps, regions)
    val backend = ContingencyPreviewBackend(config.also { if (it.effectAssets == null) it.effectAssets = EffectFixtures.assets })
    val grid: FrameGrid = FrameGrid.of(plan.canvas.fps)

    init {
        engine.ctx.sourceFrames.codecSelector = ExactFrames.softwareFirst
        await<Unit> { cb -> onPreview { backend.open(host, cb) } }
        check(!backend.usesStillsFallback) { "the contingency engine did not open (stills fallback)" }
        await<Unit> { cb -> onPreview { backend.rebuild(plan, cb) } }
        onPreview { backend.setRenderSize(plan.canvas.w, plan.canvas.h) }
        await<Unit> { cb -> onPreview { backend.attachSurface(sink.reader.surface, plan.canvas.w, plan.canvas.h, cb) } }
    }

    fun onPreview(block: () -> Unit) = engine.ctx.threads.preview.execute(block)

    /** Swaps the plan (snapshot) and rebuilds the decks. */
    fun setPlan(next: RenderPlan, touched: Set<String> = emptySet()) {
        host.snapshot.set(host.snapshot.get().withPlan(next, touched))
        await<Unit> { cb -> onPreview { backend.rebuild(next, cb) } }
    }

    /** Exact seek to [k]; returns the latency until frameDisplayed(k) in ms. */
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

    fun seekAsync(k: Long, exact: Boolean) = await<Unit> { cb -> onPreview { backend.seek(k, exact, cb) } }

    fun play(from: Long, loop: FrameRange? = null) = await<Unit> { cb -> onPreview { backend.play(from, loop, cb) } }

    fun pause(): Long = await { cb -> onPreview { backend.pause(cb) } }

    fun stats(): EngineStats = await { cb -> backend.stats(cb) }

    /** Plays from [from] until the backend reports the end (or [timeoutMs]). */
    fun playToEnd(from: Long, timeoutMs: Long): Boolean {
        host.endedAt = null
        play(from)
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (host.endedAt != null) return true
            if (host.failures.isNotEmpty()) error("backend failed: ${host.failures.first()}")
            Thread.sleep(5)
        }
        pause()
        return false
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

/** p50/p90/max of a list of ms values. */
class Timings(values: List<Double>) {
    private val sorted = values.sorted()
    fun p(q: Double): Double = if (sorted.isEmpty()) Double.NaN else sorted[((sorted.size - 1) * q).toInt()]
    override fun toString(): String = "n=%d p50=%.1f p90=%.1f max=%.1f ms".format(sorted.size, p(0.5), p(0.9), sorted.lastOrNull() ?: Double.NaN)
}
