@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-06
//
// Source-frame cache (ARCH §12.2, §13.3 'Paused edits', §15; BUILD_PLAN AND-06, same contract as
// iOS IOS-06): a small LRU of decoded EXACT source frames for the preview session (AND-10) and the
// paused-frame renderer (AND-17):
//
// - `frame`: the rule frame (D-04: greatest PTS <= s + 500 µs) of a source time, upright (rotation
//   applied) and SDR, at full size or bounded to a long side (showSourceFrame's trim-edge preview
//   at preview size, AND-17's paused prefetch, AND-16's over-budget stills);
// - `sampleColor`: the pre-key source (the full-size frame without any effect) averaged over the
//   3x3 pixels around a normalized point (display orientation, top-left origin), gamma-encoded
//   R'G'B' components 0..1 as decoded (no colour conversion, ARCH §13);
// - `lookStills`: stills of one frame scaled to a height, each through AND-09's LayerLookEffect
//   with the caller's look override (`LookStill`: the layer's params with the look under test,
//   built by AND-10's renderLookStills from the plan), or unprocessed for a null entry. All looks of
//   a call share one FrameExtractor whose LayerLookEffect reads a switchable binding; each look
//   re-extracts the same frame. The output size is fixed by the first look (looks of one item share
//   its crop).
//
// Frames come from ExactFrames (FreezeFrameJob.kt): FrameExtractor with SeekParameters.EXACT,
// verified against the rule frame's PTS, with a software-decoder retry (a media whose default
// decoder delivered a wrong frame keeps software decoders first afterwards). Bitmaps are ARGB_8888.
//
// Memory: the cache holds at most `budgetBytes` of bitmaps (tier budget: minimal 16 MB, low 24 MB,
// mid 64 MB, high 192 MB, the same values as iOS; two full 1080p frames on the weakest devices) and
// evicts the least recently used frame first; a frame larger than the whole budget is returned but
// not kept. Evicted bitmaps are not recycled (a caller may still draw them); the GC frees them. At
// most one FrameExtractor (one decoder instance: AND-01 keeps two free for frame extraction and
// thumbnails) stays open between requests; it is closed after 5 s idle and on any trim.
// `trim(memoryPressure)` keeps a quarter of the budget, `background` and `clearAll` drop
// everything.
//
// Thread-safe; extractions are serialized. The blocking calls decode on the caller's thread
// (danaview-preview, danaview-jobs, never main); the async calls run on the cache's own worker
// ("danaview-frames"). Never logs paths.

package com.vecvel.danaview.editor.engine.preview

import android.graphics.Bitmap
import android.util.Log
import androidx.annotation.OptIn
import androidx.annotation.VisibleForTesting
import androidx.core.graphics.scale
import androidx.media3.common.Effect
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.inspector.frame.FrameExtractor
import com.vecvel.danaview.editor.engine.core.Cancellable
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.JobControl
import com.vecvel.danaview.editor.engine.effects.BoundLayer
import com.vecvel.danaview.editor.engine.effects.EffectAssets
import com.vecvel.danaview.editor.engine.effects.LayerBinding
import com.vecvel.danaview.editor.engine.effects.LayerLookEffect
import com.vecvel.danaview.editor.engine.effects.RasterSizing
import com.vecvel.danaview.editor.engine.effects.RenderGeometry
import com.vecvel.danaview.editor.engine.media.ExactFrames
import com.vecvel.danaview.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.danaview.editor.engine.pigeon.ColorMsg
import com.vecvel.danaview.editor.engine.pigeon.DeviceTierMsg
import com.vecvel.danaview.editor.engine.plan.LayerParams
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * A look applied to a look still: [params] are the layer's parameters with the look under test
 * (LUT, grade, chroma and crop as the plan would draw them), [layer] and [plan] the plan objects
 * they belong to (LUT assets resolve through the plan), [geometry] the plan's canvas and render
 * size. AND-10's `renderLookStills` builds one per LookSpec.
 */
class LookStill(
    val params: LayerParams,
    val layer: PlanLayer,
    val plan: RenderPlan,
    val geometry: RenderGeometry,
    /** Opens LUT assets; null = the app's ContentResolver. */
    val assets: EffectAssets? = null,
) {
    /** The bound layer the look effect draws. */
    val bound: BoundLayer get() = BoundLayer(params, layer, plan)
}

/** Source-frame cache (ARCH §12.2, §15; AND-06). */
class SourceFrameCache(
    private val ctx: EngineContext,
    /** Byte budget; null reads the device tier on first use ([budgetFor]). */
    budgetBytes: Long? = null,
) {
    /** Cache key: media (fingerprint, or the URI when unknown), source time, long-side bound (0 = full size). */
    data class Key(val media: String, val sourceTimeUs: Long, val maxLongSide: Int)

    private val fixedBudget = budgetBytes

    /** The byte budget of the cached frames (tier budget unless given). */
    val budgetBytes: Long by lazy { fixedBudget ?: budgetFor(ctx.deviceProfile.tier()) }

    private val frames: FrameLru<Key, Bitmap> by lazy { FrameLru(this.budgetBytes) { it.allocationByteCount.toLong() } }
    private val decodeLock = ReentrantLock()
    private var pooled: PooledExtractor? = null
    private var idleClose: ScheduledFuture<*>? = null
    private val softwareMedia = HashSet<String>()
    private val displaySizes = HashMap<String, Pair<Int, Int>>()
    private val decodes = AtomicInteger()
    private val threadIds = AtomicInteger()
    private val worker: ScheduledExecutorService by lazy {
        Executors.newSingleThreadScheduledExecutor { r ->
            Thread(r, "danaview-frames-${threadIds.incrementAndGet()}").apply { isDaemon = true }
        }
    }

    /**
     * Test hook: the decoder choice of the first extraction attempt. Null (production) uses Media3's
     * default (the retry after a wrong frame always puts software decoders first).
     */
    @VisibleForTesting
    @Volatile
    var codecSelector: MediaCodecSelector? = null

    /** Frames decoded so far (hits do not decode). */
    val decodeCount: Int get() = decodes.get()

    /** Bytes of the cached frames. */
    val totalBytes: Long get() = frames.totalBytes

    /** Cached frames. */
    val count: Int get() = frames.size

    /** Whether a FrameExtractor is open (tests). */
    val hasOpenExtractor: Boolean get() = decodeLock.withLock { pooled != null }

    // ---- frames ----

    /**
     * The rule frame of [uri] at [sourceTimeUs], upright and SDR, at most [maxLongSide] px on its
     * long side (null = full size; smaller sources are not enlarged). Cached; the returned bitmap is
     * shared, so callers must not recycle or modify it. Blocking.
     */
    fun frame(uri: String, fingerprint: String?, sourceTimeUs: Long, maxLongSide: Int? = null, control: JobControl? = null): Bitmap {
        if (maxLongSide != null && maxLongSide <= 0) throw EngineErrors.invalidArgument("maxLongSide", "not positive")
        val media = fingerprint ?: uri
        val key = Key(media, sourceTimeUs, maxLongSide ?: 0)
        frames.get(key)?.let { return it }
        val bitmap = decodeLock.withLock {
            frames.get(key)?.let { return it }
            val rulePts = ExactFrames.ruleFramePtsUs(ctx.appContext, uri, sourceTimeUs)
            control?.throwIfCancelled()
            val height = maxLongSide?.let { targetHeight(uri, it) }
            val decoded = extractPooled(uri, media, rulePts, height, control)
            decodes.incrementAndGet()
            decoded
        }
        frames.put(key, bitmap)
        return bitmap
    }

    /**
     * The 3x3 average colour of the pre-key source (the full-size frame, no effects) at normalized
     * ([x], [y]) (0..1, top-left origin, display orientation): R'G'B' as decoded, alpha 1 for video.
     */
    fun sampleColor(uri: String, fingerprint: String?, sourceTimeUs: Long, x: Double, y: Double, control: JobControl? = null): ColorMsg {
        if (!x.isFinite() || !y.isFinite()) throw EngineErrors.invalidArgument("point", "not finite")
        val bitmap = frame(uri, fingerprint, sourceTimeUs, null, control)
        val w = bitmap.width
        val h = bitmap.height
        if (w <= 0 || h <= 0) throw EngineException(EngineErrorCode.decodeFailed, "empty frame")
        val window = ColorSampling.window(w, h, x, y)
        val argb = IntArray(window.width * window.height)
        bitmap.getPixels(argb, 0, window.width, window.x, window.y, window.width, window.height)
        return ColorSampling.average(argb)
    }

    /**
     * One still per entry of [looks] of the frame of [uri] at [sourceTimeUs], [heightPx] high
     * (aspect kept): through LayerLookEffect with the entry's look, or unprocessed for a null
     * entry. The caller owns (and may recycle) the returned bitmaps. Blocking.
     */
    fun lookStills(
        uri: String,
        fingerprint: String?,
        sourceTimeUs: Long,
        heightPx: Int,
        looks: List<LookStill?>,
        control: JobControl? = null,
    ): List<Bitmap> {
        if (heightPx <= 0) throw EngineErrors.invalidArgument("heightPx", "not positive")
        val out = ArrayList<Bitmap>(looks.size)
        try {
            val styled = looks.filterNotNull()
            val rendered = if (styled.isEmpty()) emptyList() else renderLooks(uri, fingerprint ?: uri, sourceTimeUs, heightPx, styled, control)
            var next = 0
            for (look in looks) {
                control?.throwIfCancelled()
                out += if (look == null) unprocessedStill(uri, fingerprint, sourceTimeUs, heightPx, control) else rendered[next++]
            }
            return out
        } catch (t: Throwable) {
            out.forEach { it.recycle() }
            throw t
        }
    }

    /** [frame] on the cache's worker; [done] gets the shared bitmap. The returned handle cancels it. */
    fun frameAsync(uri: String, fingerprint: String?, sourceTimeUs: Long, maxLongSide: Int?, done: Completion<Bitmap>): Cancellable {
        val control = CancelFlag()
        val replied = AtomicBoolean(false)
        fun reply(result: Result<Bitmap>) {
            if (replied.compareAndSet(false, true)) done(result)
        }
        worker.execute {
            if (control.isCancelled) return@execute reply(Result.failure(cancelled()))
            try {
                reply(Result.success(frame(uri, fingerprint, sourceTimeUs, maxLongSide, control)))
            } catch (t: Throwable) {
                reply(Result.failure(if (control.isCancelled) cancelled() else EngineErrors.from(t)))
            }
        }
        return Cancellable {
            control.cancel()
            reply(Result.failure(cancelled()))
        }
    }

    // ---- eviction ----

    /** Drops every frame of [fingerprint] (relink, media removed). */
    fun remove(fingerprint: String) {
        frames.removeIf { it.media == fingerprint }
        decodeLock.withLock {
            softwareMedia.remove(fingerprint)
        }
    }

    /** Drops every frame and closes the extractor (session dispose). */
    fun removeAll() {
        frames.trimTo(0)
        closeExtractorLater()
    }

    /**
     * Drops cached frames per [level] (`EngineHostApi.trimCaches`, memory warnings): memoryPressure
     * keeps a quarter of the budget, background and clearAll drop everything; the open extractor is
     * closed in every case. Called on danaview-preview; never blocks on a decode.
     */
    fun trim(level: CacheTrimLevelMsg) {
        when (level) {
            CacheTrimLevelMsg.MEMORY_PRESSURE -> frames.trimTo(budgetBytes / 4)
            CacheTrimLevelMsg.BACKGROUND, CacheTrimLevelMsg.CLEAR_ALL -> frames.trimTo(0)
        }
        closeExtractorLater()
    }

    // ---- decoding (under decodeLock) ----

    private class PooledExtractor(val key: String, val extractor: FrameExtractor, val software: Boolean)

    private fun extractPooled(uri: String, media: String, rulePtsUs: Long, height: Int?, control: JobControl?): Bitmap {
        idleClose?.cancel(false)
        val effects: List<Effect> = height?.let { listOf(Presentation.createForHeight(it)) } ?: emptyList()
        try {
            val software = media in softwareMedia
            val selector = if (software) ExactFrames.softwareFirst else codecSelector
            val first = getFrame(acquire(uri, height, effects, selector, software), rulePtsUs, control)
            if (ExactFrames.isFrame(first.presentationTimeMs, rulePtsUs)) return first.bitmap
            first.bitmap.recycle()
            Log.w(EngineContext.TAG, "source frame off by ${first.presentationTimeMs - ExactFrames.seekPositionMs(rulePtsUs)} ms; retrying with software decoders")
            closePooled()
            softwareMedia += media
            val second = getFrame(acquire(uri, height, effects, ExactFrames.softwareFirst, true), rulePtsUs, control)
            if (ExactFrames.isFrame(second.presentationTimeMs, rulePtsUs)) return second.bitmap
            second.bitmap.recycle()
            throw EngineException(EngineErrorCode.decodeFailed, "the decoder did not deliver the requested frame", retryable = true)
        } catch (t: Throwable) {
            // A failed or stopped extractor is not reused.
            closePooled()
            throw t
        } finally {
            scheduleIdleClose()
        }
    }

    private fun acquire(uri: String, height: Int?, effects: List<Effect>, selector: MediaCodecSelector?, software: Boolean): FrameExtractor {
        val key = "${height ?: 0}|${if (software) 1 else 0}|$uri"
        pooled?.let { if (it.key == key) return it.extractor }
        closePooled()
        val extractor = try {
            ExactFrames.extractor(ctx.appContext, uri, effects, selector)
        } catch (t: Throwable) {
            throw ExactFrames.mapFrameError(t)
        }
        pooled = PooledExtractor(key, extractor, software)
        return extractor
    }

    private fun getFrame(extractor: FrameExtractor, rulePtsUs: Long, control: JobControl?): FrameExtractor.Frame =
        ExactFrames.await(extractor.getFrame(ExactFrames.seekPositionMs(rulePtsUs)), control)

    private fun closePooled() {
        pooled?.let { ExactFrames.closeQuietly(it.extractor) }
        pooled = null
    }

    private fun scheduleIdleClose() {
        idleClose?.cancel(false)
        idleClose = worker.schedule({ decodeLock.withLock { closePooled() } }, IDLE_CLOSE_MS, TimeUnit.MILLISECONDS)
    }

    private fun closeExtractorLater() {
        worker.execute { decodeLock.withLock { closePooled() } }
    }

    /** The output height that bounds [uri]'s display long side to [maxLongSide] (null when it already fits). */
    private fun targetHeight(uri: String, maxLongSide: Int): Int? {
        val (w, h) = displaySizes.getOrPut(uri) { ExactFrames.displaySize(ctx.appContext, uri) }
        return Sizing.boundedHeight(w, h, maxLongSide)
    }

    private fun unprocessedStill(uri: String, fingerprint: String?, sourceTimeUs: Long, heightPx: Int, control: JobControl?): Bitmap {
        val full = frame(uri, fingerprint, sourceTimeUs, null, control)
        val width = Sizing.widthForHeight(full.width, full.height, heightPx)
        return full.scale(width, heightPx).let { if (it === full) full.copy(Bitmap.Config.ARGB_8888, false) else it }
    }

    private fun renderLooks(uri: String, media: String, sourceTimeUs: Long, heightPx: Int, looks: List<LookStill>, control: JobControl?): List<Bitmap> {
        val first = looks.first()
        val binding = SwitchableBinding(first.bound)
        val effects = listOf<Effect>(
            LayerLookEffect(binding, first.geometry, RasterSizing.SOURCE, assets = first.assets),
            Presentation.createForHeight(heightPx),
        )
        return decodeLock.withLock {
            idleClose?.cancel(false)
            closePooled() // one decoder at a time
            val rulePts = ExactFrames.ruleFramePtsUs(ctx.appContext, uri, sourceTimeUs)
            val out = ArrayList<Bitmap>(looks.size)
            var selector = if (media in softwareMedia) ExactFrames.softwareFirst else codecSelector
            var extractor = ExactFrames.extractor(ctx.appContext, uri, effects, selector)
            try {
                val position = ExactFrames.seekPositionMs(rulePts)
                for ((index, look) in looks.withIndex()) {
                    control?.throwIfCancelled()
                    binding.bound.set(look.bound)
                    // Alternate floor and floor - 1 ms so each look is a fresh seek (both land on the rule frame).
                    val at = if (index % 2 == 1 && position >= 1) position - 1 else position
                    var got = ExactFrames.await(extractor.getFrame(at), control)
                    if (!ExactFrames.isFrame(got.presentationTimeMs, rulePts)) {
                        got.bitmap.recycle()
                        ExactFrames.closeQuietly(extractor)
                        selector = ExactFrames.softwareFirst
                        softwareMedia += media
                        extractor = ExactFrames.extractor(ctx.appContext, uri, effects, selector)
                        got = ExactFrames.await(extractor.getFrame(position), control)
                        if (!ExactFrames.isFrame(got.presentationTimeMs, rulePts)) {
                            got.bitmap.recycle()
                            throw EngineException(EngineErrorCode.decodeFailed, "the decoder did not deliver the requested frame", retryable = true)
                        }
                    }
                    decodes.incrementAndGet()
                    out += got.bitmap
                }
                out
            } catch (t: Throwable) {
                out.forEach { it.recycle() }
                throw if (t is EngineException) t else ExactFrames.mapFrameError(t)
            } finally {
                ExactFrames.closeQuietly(extractor)
            }
        }
    }

    /** The look effect's binding, switched between the looks of one call. */
    private class SwitchableBinding(initial: BoundLayer) : LayerBinding {
        val bound = AtomicReference(initial)
        override fun resolve(ptsUs: Long): BoundLayer = bound.get()
        override fun current(): BoundLayer = bound.get()
        override val maxScale: Double get() = max(1e-6, abs(bound.get().params.xf.s))
    }

    /** A JobControl that only knows a cancel (async requests). */
    private class CancelFlag : JobControl {
        private val flag = AtomicBoolean(false)
        override val jobId: String = "source-frame"
        override val isCancelled: Boolean get() = flag.get()
        override fun reportProgress(fraction: Double) = Unit
        fun cancel() = flag.set(true)
    }

    companion object {
        /** Idle time after which the open extractor is closed. */
        const val IDLE_CLOSE_MS = 5_000L

        private const val MB = 1024L * 1024L

        /** Byte budget per tier (same values as iOS IOS-06). */
        fun budgetFor(tier: DeviceTierMsg): Long = when (tier) {
            DeviceTierMsg.MINIMAL -> 16 * MB
            DeviceTierMsg.LOW -> 24 * MB
            DeviceTierMsg.MID -> 64 * MB
            DeviceTierMsg.HIGH -> 192 * MB
        }

        private fun cancelled() = EngineException(EngineErrorCode.cancelled, "cancelled")
    }
}

/** Frame size arithmetic (pure). */
object Sizing {
    /** The height that bounds a [width] x [height] frame's long side to [maxLongSide], or null when it fits. */
    fun boundedHeight(width: Int, height: Int, maxLongSide: Int): Int? {
        if (width <= 0 || height <= 0 || max(width, height) <= maxLongSide) return null
        return max(1, (height.toDouble() * maxLongSide / max(width, height)).roundToInt())
    }

    /** The width of a [width] x [height] frame drawn [heightPx] high (aspect kept, at least 1). */
    fun widthForHeight(width: Int, height: Int, heightPx: Int): Int =
        if (width <= 0 || height <= 0) heightPx else max(1, (width.toDouble() * heightPx / height).roundToInt())
}

/** The 3x3 colour sample (pure; same window rule as iOS `SourceFrameCache.averageColor`). */
object ColorSampling {
    /** A pixel rectangle. */
    data class Window(val x: Int, val y: Int, val width: Int, val height: Int)

    /**
     * The 3x3 window (smaller for frames under 3 px) around the pixel at normalized ([x], [y]) of a
     * [width] x [height] frame, shifted inside the frame at its edges.
     */
    fun window(width: Int, height: Int, x: Double, y: Double): Window {
        val cx = min(width - 1, max(0, Math.floor(x.coerceIn(0.0, 1.0) * width).toInt()))
        val cy = min(height - 1, max(0, Math.floor(y.coerceIn(0.0, 1.0) * height).toInt()))
        val rw = min(3, width)
        val rh = min(3, height)
        val x0 = min(max(0, cx - 1), max(0, width - 3))
        val y0 = min(max(0, cy - 1), max(0, height - 3))
        return Window(x0, y0, rw, rh)
    }

    /** The average of [argb] pixels (non-premultiplied ARGB ints) as a ColorMsg (components 0..1). */
    fun average(argb: IntArray): ColorMsg {
        if (argb.isEmpty()) return ColorMsg(0.0, 0.0, 0.0, 0.0)
        var r = 0.0
        var g = 0.0
        var b = 0.0
        var a = 0.0
        for (p in argb) {
            a += (p ushr 24) and 0xFF
            r += (p shr 16) and 0xFF
            g += (p shr 8) and 0xFF
            b += p and 0xFF
        }
        val n = argb.size * 255.0
        return ColorMsg(red = r / n, green = g / n, blue = b / n, alpha = a / n)
    }
}

/**
 * A byte-bounded LRU (pure, thread-safe): [put] evicts least recently used entries until the total
 * fits [budgetBytes]; an entry larger than the whole budget is not kept.
 */
class FrameLru<K, V>(budgetBytes: Long, private val sizeOf: (V) -> Long) {
    private val lock = Any()
    private val map = LinkedHashMap<K, V>(16, 0.75f, true)
    private val sizes = HashMap<K, Long>()
    private var total = 0L

    /** The byte budget. */
    val budgetBytes: Long = max(0L, budgetBytes)

    /** Bytes of the entries. */
    val totalBytes: Long get() = synchronized(lock) { total }

    /** Entries. */
    val size: Int get() = synchronized(lock) { map.size }

    /** The entry of [key] (marked most recently used), or null. */
    fun get(key: K): V? = synchronized(lock) { map[key] }

    /** Adds [value]; returns false when it is larger than the budget (not kept). */
    fun put(key: K, value: V): Boolean = synchronized(lock) {
        val bytes = max(0L, sizeOf(value))
        if (bytes > budgetBytes) return false
        remove(key)
        map[key] = value
        sizes[key] = bytes
        total += bytes
        evictTo(budgetBytes)
        true
    }

    /** Evicts least recently used entries until at most [bytes] remain. */
    fun trimTo(bytes: Long) = synchronized(lock) { evictTo(max(0L, bytes)) }

    /** Removes every entry whose key matches [predicate]. */
    fun removeIf(predicate: (K) -> Boolean) = synchronized(lock) {
        map.keys.filter(predicate).forEach { remove(it) }
    }

    /** Keys from least to most recently used (tests). */
    fun keys(): List<K> = synchronized(lock) { map.keys.toList() }

    private fun remove(key: K) {
        if (map.remove(key) != null) total -= sizes.remove(key) ?: 0L
    }

    private fun evictTo(limit: Long) {
        val iterator = map.entries.iterator()
        while (total > limit && iterator.hasNext()) {
            val entry = iterator.next()
            iterator.remove()
            total -= sizes.remove(entry.key) ?: 0L
        }
    }
}
