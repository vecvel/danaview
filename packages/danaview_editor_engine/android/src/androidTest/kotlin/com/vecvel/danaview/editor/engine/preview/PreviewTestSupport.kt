// OWNER: AND-10
//
// Support for the AND-10 instrumented tests (package preview):
// - [FakeTextureRegistry] / [FakeSurfaceProducer]: Flutter's SurfaceProducer contract over an
//   ImageReader (RGBA_8888), so the tests see every frame the session presents and can drive the
//   resetInBackground lifecycle (onSurfaceCleanup on the main thread, then a new Surface and
//   onSurfaceAvailable), the way Flutter's ImageReaderSurfaceProducer does after a trim.
// - [PreviewHarness]: a PreviewSessionManager on an engine context (AND-06's FreezeEngine roots, the
//   software-first decoder choice the emulator needs) with one opened session, blocking helpers
//   that call the session on danaview-preview, and the captured engine events.
// - [RecordingBackend]: a PreviewBackend that draws on the Surface itself (as AND-16's will) but
//   only records its calls and reports frames at once, for the hand-off and seq tests.
// Plans come from AND-17's PausedPlans (640×360 @ 24 fps over ENG-05's barcode counter).

package com.vecvel.danaview.editor.engine.preview

import android.graphics.PixelFormat
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.effects.EffectFixtures
import com.vecvel.danaview.editor.engine.freeze.FreezeEngine
import com.vecvel.danaview.editor.engine.media.ExactFrames
import com.vecvel.danaview.editor.engine.paused.await
import com.vecvel.danaview.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.danaview.editor.engine.pigeon.ClockMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.PlanAckMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewConfigMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewEventMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewOpenedMsg
import com.vecvel.danaview.editor.engine.pigeon.PreviewQualityMsg
import com.vecvel.danaview.editor.engine.pigeon.SeekAckMsg
import com.vecvel.danaview.editor.engine.plan.PlanTransient
import com.vecvel.danaview.editor.engine.plan.PlanWriter
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.plan.RenderPlanPatch
import io.flutter.view.TextureRegistry
import java.util.Collections
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

const val AND10_TAG = "AND10"

/** One frame the fake producer received: RGBA top-down, its reader generation and arrival time. */
class ProducedFrame(val index: Int, val generation: Int, val width: Int, val height: Int, val rgba: ByteArray, val atNs: Long)

/** Flutter's SurfaceProducer over an ImageReader (file header). */
class FakeSurfaceProducer(private val id: Long, val lifecycle: TextureRegistry.SurfaceLifecycle) : TextureRegistry.SurfaceProducer {
    private val thread = HandlerThread("fake-producer-$id").apply { start() }
    private val handler = Handler(thread.looper)
    private var w = 1
    private var h = 1
    private var reader: ImageReader? = null
    private val oldReaders = ArrayList<ImageReader>()
    @Volatile private var callback: TextureRegistry.SurfaceProducer.Callback? = null
    private val generation = AtomicInteger()
    private val count = AtomicInteger()

    /** Frames received (the last [KEEP] kept). */
    val frames: MutableList<ProducedFrame> = CopyOnWriteArrayList()

    /** Frames received so far. */
    val frameCount: Int get() = count.get()

    /** Whether [release] was called. */
    @Volatile var released = false
        private set

    /** Calls of getSurface that created a new reader. */
    val generations: Int get() = generation.get()

    override fun id(): Long = id

    override fun release() {
        released = true
        reader?.close()
        oldReaders.forEach { it.close() }
        reader = null
        thread.quitSafely()
    }

    override fun setSize(width: Int, height: Int) {
        w = width
        h = height
    }

    override fun getWidth(): Int = w

    override fun getHeight(): Int = h

    @Synchronized
    override fun getSurface(): Surface {
        val r = reader
        if (r != null && r.width == w && r.height == h) return r.surface
        r?.let { oldReaders += it }
        val next = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 3)
        val gen = generation.incrementAndGet()
        next.setOnImageAvailableListener({ ir -> read(ir, gen) }, handler)
        reader = next
        return next.surface
    }

    override fun getForcedNewSurface(): Surface = synchronized(this) {
        reader?.let { oldReaders += it }
        reader = null
        surface
    }

    override fun setCallback(callback: TextureRegistry.SurfaceProducer.Callback?) {
        this.callback = callback
    }

    override fun scheduleFrame() = Unit

    override fun handlesCropAndRotation(): Boolean = false

    private fun read(ir: ImageReader, gen: Int) {
        val image = try {
            ir.acquireLatestImage()
        } catch (_: IllegalStateException) {
            null
        } ?: return
        image.use {
            val plane = it.planes[0]
            val buf = plane.buffer
            val iw = it.width
            val ih = it.height
            val out = ByteArray(iw * ih * 4)
            for (y in 0 until ih) {
                buf.position(y * plane.rowStride)
                buf.get(out, y * iw * 4, iw * 4)
            }
            frames += ProducedFrame(count.incrementAndGet(), gen, iw, ih, out, System.nanoTime())
            while (frames.size > KEEP) frames.removeAt(0)
        }
    }

    /** Flutter's trim path: onSurfaceCleanup on the main thread, then the reader is closed. Returns the wait in ms. */
    fun simulateCleanup(): Double {
        var ms = 0.0
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val t0 = System.nanoTime()
            callback?.onSurfaceCleanup()
            ms = (System.nanoTime() - t0) / 1e6
            synchronized(this) {
                reader?.close()
                reader = null
            }
        }
        return ms
    }

    /** Flutter's resume path: a new reader, then onSurfaceAvailable on the main thread. */
    fun simulateAvailable() {
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            surface
            callback?.onSurfaceAvailable()
        }
    }

    /** The latest frame, or null. */
    fun last(): ProducedFrame? = frames.lastOrNull()

    /** Waits until more than [after] frames arrived; returns the latest. */
    fun awaitFrame(after: Int, timeoutMs: Long = 20_000): ProducedFrame {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (frameCount > after) return frames.last()
            Thread.sleep(5)
        }
        error("no frame after #$after in $timeoutMs ms")
    }

    companion object {
        const val KEEP = 16
    }
}

/** A TextureRegistry that only makes [FakeSurfaceProducer]s. */
class FakeTextureRegistry : TextureRegistry {
    private val ids = AtomicLong(100)

    /** Every producer created. */
    val producers: MutableList<FakeSurfaceProducer> = CopyOnWriteArrayList()

    override fun createSurfaceProducer(lifecycle: TextureRegistry.SurfaceLifecycle): TextureRegistry.SurfaceProducer =
        FakeSurfaceProducer(ids.incrementAndGet(), lifecycle).also { producers += it }

    override fun createSurfaceTexture(): TextureRegistry.SurfaceTextureEntry = throw UnsupportedOperationException()

    override fun registerSurfaceTexture(surfaceTexture: android.graphics.SurfaceTexture): TextureRegistry.SurfaceTextureEntry =
        throw UnsupportedOperationException()

    override fun createImageTexture(): TextureRegistry.ImageTextureEntry = throw UnsupportedOperationException()
}

/** A manager with one opened session over a fake texture registry (file header). */
class PreviewHarness(
    name: String,
    backend: (() -> PreviewBackend)? = null,
    longSide: Int = 1920,
) : AutoCloseable {
    val engine = FreezeEngine(name)
    val ctx: EngineContext get() = engine.ctx
    val textures = FakeTextureRegistry()
    val manager = PreviewSessionManager(engine.ctx).apply {
        if (backend != null) backendFactory = backend
        effectAssets = EffectFixtures.assets
        maxPreviewLongSideOverride = longSide
    }
    lateinit var session: PreviewSession
    lateinit var opened: PreviewOpenedMsg

    init {
        engine.ctx.sourceFrames.codecSelector = ExactFrames.softwareFirst
    }

    val producer: FakeSurfaceProducer get() = textures.producers.last()

    fun open(quality: PreviewQualityMsg = PreviewQualityMsg.FULL, w: Long = 640, h: Long = 360, fps: Long = 24): PreviewOpenedMsg {
        opened = await { cb -> onPreview { manager.open(PreviewConfigMsg(w, h, fps, quality, false), textures, cb) } }
        session = requireNotNull(manager.get(opened.sessionId))
        return opened
    }

    fun onPreview(block: () -> Unit) = ctx.threads.preview.execute(block)

    /** Runs [block] on danaview-preview and waits for it. */
    fun <T> sync(block: () -> T): T = await { cb -> onPreview { cb(runCatching(block)) } }

    fun <T> call(timeoutS: Long = 120, block: (PreviewSession, Completion<T>) -> Unit): T = await(timeoutS) { cb -> onPreview { block(session, cb) } }

    fun setPlan(plan: RenderPlan): PlanAckMsg = call { s, cb -> s.setPlan(PlanWriter.planBytes(plan), cb) }

    fun patch(patch: RenderPlanPatch): PlanAckMsg = call { s, cb -> s.applyPatch(PlanWriter.patchJson(patch).toByteArray(), cb) }

    fun transient(t: PlanTransient) = onPreview { session.setTransient(t.item, PlanWriter.transientJson(t).toByteArray()) }

    fun play(): Long = call { s, cb -> s.play(null, cb) }

    fun pause(): Long = call { s, cb -> s.pause(cb) }

    fun seek(timeUs: Long, exact: Boolean = true): SeekAckMsg = call { s, cb -> s.seek(timeUs, exact, cb) }

    fun capture(): ByteArray = call { s, cb -> s.debugCaptureFrame(cb) }

    fun events(): List<com.vecvel.danaview.editor.engine.pigeon.EngineEventMsg> = synchronized(engine.events) { engine.events.toList() }

    fun previewEvents(kind: PreviewEventKindMsg): List<PreviewEventMsg> =
        events().filter { it.kind == EngineEventKindMsg.PREVIEW && it.sessionId == opened.sessionId }.mapNotNull { it.previewEvent }.filter { it.kind == kind }

    fun clocks(): List<ClockMsg> = events().filter { it.kind == EngineEventKindMsg.CLOCK && it.sessionId == opened.sessionId }.mapNotNull { it.clock }

    /** Waits until [predicate] holds (polling). */
    fun waitUntil(what: String, timeoutMs: Long = 20_000, predicate: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (predicate()) return
            Thread.sleep(5)
        }
        error("timed out waiting for $what")
    }

    override fun close() {
        try {
            if (this::session.isInitialized) await<Unit> { cb -> onPreview { session.dispose(cb) } }
        } finally {
            try {
                ctx.sourceFrames.trim(CacheTrimLevelMsg.CLEAR_ALL)
            } catch (t: Throwable) {
                Log.w(AND10_TAG, "trim on close failed", t)
            }
            engine.close()
        }
    }
}

/**
 * A backend that draws on the Surface itself, like AND-16's, but only records its calls: frames are
 * "displayed" at once (seek → frameDisplayed(k); play → frameDisplayed(from)). For the hand-off,
 * seq and rebuild tests.
 */
class RecordingBackend : PreviewBackend {
    override val name: String = "recording"
    override val drawsOnSurface: Boolean = true
    lateinit var host: PreviewBackendHost
    val calls: MutableList<String> = Collections.synchronizedList(ArrayList())
    val rebuilds = AtomicInteger()
    @Volatile var attached: Surface? = null
    @Volatile var position = 0L
    @Volatile var rebuildDelayMs = 0L
    @Volatile var holdSeeks = false

    override fun open(host: PreviewBackendHost, done: Completion<Unit>) {
        this.host = host
        calls += "open"
        done(Result.success(Unit))
    }

    override fun rebuild(plan: RenderPlan, done: Completion<Unit>) {
        calls += "rebuild:${plan.rev}"
        rebuilds.incrementAndGet()
        if (rebuildDelayMs > 0) host.scheduler.schedule(rebuildDelayMs) { done(Result.success(Unit)) } else done(Result.success(Unit))
    }

    override fun attachSurface(surface: Surface, width: Int, height: Int, done: Completion<Unit>) {
        calls += "attach"
        attached = surface
        done(Result.success(Unit))
    }

    override fun detachSurface(done: Completion<Unit>) {
        calls += "detach"
        attached = null
        done(Result.success(Unit))
    }

    override fun play(fromFrame: Long, loop: FrameRange?, done: Completion<Unit>) {
        calls += "play:$fromFrame"
        position = fromFrame
        done(Result.success(Unit))
        host.frameDisplayed(fromFrame)
    }

    override fun pause(done: Completion<Long>) {
        calls += "pause"
        done(Result.success(position))
    }

    override fun seek(k: Long, exact: Boolean, done: Completion<Unit>) {
        calls += "seek:$k:$exact"
        done(Result.success(Unit))
        if (!holdSeeks) {
            position = k
            host.frameDisplayed(k)
        }
    }

    /** Reports frame [k] as displayed (a held seek finishing, or playback advancing). */
    fun show(k: Long) {
        position = k
        host.frameDisplayed(k)
    }

    override fun setRenderSize(width: Int, height: Int) {
        calls += "size:${width}x$height"
    }

    override fun setUseProxies(on: Boolean) = Unit

    override fun capture(done: Completion<PausedFrameRenderer.Captured>) = done(Result.success(PausedFrameRenderer.Captured(1, 1, ByteArray(4))))

    override fun trim(level: CacheTrimLevelMsg) = Unit

    override fun suspendForExport(done: Completion<Unit>) {
        calls += "suspend"
        done(Result.success(Unit))
    }

    override fun resumeAfterExport(done: Completion<Unit>) {
        calls += "resume"
        done(Result.success(Unit))
    }

    override fun release(done: Completion<Unit>) {
        calls += "release"
        done(Result.success(Unit))
    }
}

/** Mean absolute RGB difference of two RGBA frames of the same size (0..255). */
fun meanDiff(a: ByteArray, b: ByteArray): Double {
    require(a.size == b.size) { "sizes differ" }
    var sum = 0L
    var n = 0
    var i = 0
    while (i < a.size) {
        for (c in 0 until 3) sum += kotlin.math.abs((a[i + c].toInt() and 0xFF) - (b[i + c].toInt() and 0xFF))
        n += 3
        i += 4
    }
    return sum.toDouble() / n
}

/** The RGBA of pixel ([x], [y]) of a [w]-wide top-down frame. */
fun pixel(rgba: ByteArray, w: Int, x: Int, y: Int): IntArray {
    val i = (y * w + x) * 4
    return IntArray(4) { rgba[i + it].toInt() and 0xFF }
}
