@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-03
//
// JPEG thumbnail strips (ARCH §12.3, §15; BUILD_PLAN AND-03, same contract as iOS IOS-03): tile t
// of a request holds framesPerTile (8) frames at times (t · framesPerTile + k) · intervalMs
// (k = 0 until framesPerTile; frames at or past the media duration are left out), each heightPx
// high and aspect-correct in display orientation, side by side in one JPEG (Bitmap.compress
// JPEG 70). Video frames come from Media3's FrameExtractor (media3-inspector-frame) with
// SeekParameters.CLOSEST_SYNC and Presentation.createForHeight(heightPx), so the GPU downscales and
// rotation is applied; one extractor per (file, height) is kept in a small LRU and closed after
// 10 s idle. Still images decode through BitmapFactory (inSampleSize) + EXIF rotation.
//
// Sync-frame tolerance (documented per the AC): each frame is the sync (key) frame closest to its
// requested time (ExoPlayer's CLOSEST_SYNC: the earlier one on a tie), so a frame is at most half a
// GOP away from its slot time (<= 0.5 s for the 1 s GOPs of the ENG-05 fixtures). The
// instrumented test checks every barcode against the sync-frame table read with
// MediaExtractorCompat.
//
// Cache: DiskCache thumbs/ `<stableHash(fingerprint|interval|height|tile|framesPerTile|proxy)>.vwth`
// = "VWTH" + frames (u32 LE) + frame width (u32 LE) + JPEG, the same key and format as iOS. A hit is
// answered on the calling lane without queueing (<= 20 ms).
//
// Scheduling: Dart keeps at most 8 tiles in flight (ARCH §18.1); here at most 2 render at once
// (design/native.md §6.6), so thumbnails never hold more than two decoder instances (AND-02 keeps
// two instances free for them). Pending requests are served visible > prefetch > background, FIFO
// within a priority. `cancel(requestId)` answers a pending request with `cancelled` at once and
// stops a running render before its next frame.

package com.vecvel.vwish.editor.engine.media

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.RectF
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.inspector.MetadataRetriever
import androidx.media3.inspector.frame.FrameExtractor
import com.vecvel.vwish.editor.engine.core.Completion
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrorCode
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.EngineException
import com.vecvel.vwish.editor.engine.core.fail
import com.vecvel.vwish.editor.engine.core.succeed
import com.vecvel.vwish.editor.engine.pigeon.CacheTrimLevelMsg
import com.vecvel.vwish.editor.engine.pigeon.ThumbPriorityMsg
import com.vecvel.vwish.editor.engine.pigeon.ThumbnailRequestMsg
import com.vecvel.vwish.editor.engine.pigeon.ThumbnailTileMsg
import java.io.ByteArrayOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Thumbnail strips (ARCH §12.3, §15; AND-03). Called on vwish-jobs. */
class ThumbnailService(private val ctx: EngineContext) {
    /** One tile request. */
    private class Request(
        val id: String,
        val message: ThumbnailRequestMsg,
        val priority: ThumbPriorityMsg,
        val sequence: Long,
        done: Completion<ThumbnailTileMsg>,
    ) {
        private val reply = AtomicBoolean(false)
        private val completion = done
        val cancelled = AtomicBoolean(false)

        /** Completes once; later calls are ignored. Returns whether this call completed. */
        fun complete(result: Result<ThumbnailTileMsg>): Boolean {
            if (!reply.compareAndSet(false, true)) return false
            completion(result)
            return true
        }
    }

    private val lock = Any()
    private val queue = ThumbnailQueue<Request>({ it.priority }, { it.sequence })
    private val running = HashMap<String, Request>()
    private val sequence = AtomicLong()
    private val workers: ExecutorService by lazy {
        ThreadPoolExecutor(MAX_RENDERS, MAX_RENDERS, 30, TimeUnit.SECONDS, LinkedBlockingQueue()) { r ->
            Thread(r, "vwish-thumbs-${threadIds.incrementAndGet()}").apply {
                isDaemon = true
                priority = Thread.NORM_PRIORITY - 1
            }
        }.apply { allowCoreThreadTimeOut(true) }
    }
    private val threadIds = AtomicInteger()
    private val extractors = ExtractorPool()

    /** Test hook: called on the render thread after each decoded frame of [requestId]. */
    @Volatile internal var onFrameDecoded: ((requestId: String, index: Int) -> Unit)? = null

    /** Produces the tile for [request]; a cancelled request completes with `cancelled`. */
    fun requestTile(requestId: String, request: ThumbnailRequestMsg, priority: ThumbPriorityMsg, done: Completion<ThumbnailTileMsg>) {
        val paths = ctx.pathsOrNull
        val store = paths?.let { DiskCache.stores(it).thumbs }
        if (store != null) {
            val cached = store.read(cacheKey(request), CACHE_EXTENSION)?.let(::decodeCached)
            if (cached != null) {
                done.succeed(cached)
                return
            }
        }
        val entry = Request(requestId, request, priority, sequence.incrementAndGet(), done)
        synchronized(lock) {
            running[requestId]?.let { previous -> cancelEntry(previous) }
            queue.removeIf { it.id == requestId }?.complete(Result.failure(cancelledError()))
            queue.add(entry)
        }
        pump()
    }

    /** Cancels the pending tile [requestId]. Unknown ids are ignored. */
    fun cancel(requestId: String) {
        val pending = synchronized(lock) {
            running[requestId]?.let { cancelEntry(it) }
            queue.removeIf { it.id == requestId }
        }
        pending?.complete(Result.failure(cancelledError()))
    }

    /** Drops in-memory state per [level] (`EngineHostApi.trimCaches`, memory warnings): closes the frame extractors. */
    fun trim(level: CacheTrimLevelMsg) {
        workers.execute { extractors.closeAll() }
    }

    private fun cancelEntry(entry: Request) {
        entry.cancelled.set(true)
        entry.complete(Result.failure(cancelledError()))
    }

    private fun pump() {
        while (true) {
            val next = synchronized(lock) {
                if (running.size >= MAX_RENDERS) return
                val request = queue.poll() ?: return
                running[request.id] = request
                request
            }
            workers.execute { render(next) }
        }
    }

    private fun render(request: Request) {
        try {
            if (request.cancelled.get()) throw cancelledError()
            val tile = renderTile(request)
            ctx.pathsOrNull?.let { paths ->
                try {
                    DiskCache.stores(paths).thumbs.write(encodeCached(tile), cacheKey(request.message), CACHE_EXTENSION)
                } catch (e: EngineException) {
                    Log.w(EngineContext.TAG, "thumbnail cache write failed: ${e.code.name}")
                }
            }
            request.complete(Result.success(tile))
        } catch (t: Throwable) {
            val error = if (request.cancelled.get()) cancelledError() else EngineErrors.from(t).withFingerprint(request.message.media.fingerprint)
            request.complete(Result.failure(error))
        } finally {
            synchronized(lock) { if (running[request.id] === request) running.remove(request.id) }
            scheduleIdleSweep()
            pump()
        }
    }

    private fun renderTile(request: Request): ThumbnailTileMsg {
        val message = request.message
        val uri = message.media.uri
        val context = ctx.appContext
        val container = SniffedContainer.sniff(MediaSources.head(context, uri), MediaSources.hint(context, uri))
        val height = message.heightPx.toInt()
        if (container.isImage) {
            val bitmap = decodeStill(context, uri, height)
            try {
                return strip(listOf(bitmap), frameWidth(bitmap.width, bitmap.height, height), height)
            } finally {
                bitmap.recycle()
            }
        }
        val entry = extractors.acquire(context, uri, height)
        val frames = ArrayList<Bitmap>()
        try {
            val times = frameTimesMs(message, entry.durationUs / 1000.0)
            if (times.isEmpty()) throw EngineErrors.invalidArgument("request.tileIndex", "tile starts after the media end")
            for ((index, ms) in times.withIndex()) {
                if (request.cancelled.get()) throw cancelledError()
                val frame = try {
                    entry.extractor.getFrame(ms).get(FRAME_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                } catch (e: TimeoutException) {
                    throw EngineException(EngineErrorCode.decodeFailed, "thumbnail frame timed out", retryable = true, cause = e)
                } catch (e: java.util.concurrent.ExecutionException) {
                    throw MediaSources.mapOpenError(e)
                }
                frames.add(frame.bitmap)
                onFrameDecoded?.invoke(request.id, index)
            }
            if (request.cancelled.get()) throw cancelledError()
            val first = frames.first()
            return strip(frames, frameWidth(first.width, first.height, height), height)
        } finally {
            extractors.release(entry)
            for (bitmap in frames) bitmap.recycle()
        }
    }

    private fun scheduleIdleSweep() {
        ctx.threads.main.postDelayed({ workers.execute { extractors.closeIdle(System.nanoTime()) } }, IDLE_CLOSE_MS + 100)
    }

    /** FrameExtractors per (uri, height), LRU of [MAX_EXTRACTORS], closed after [IDLE_CLOSE_MS] idle. */
    private class ExtractorPool {
        class Entry(val key: String, val extractor: FrameExtractor, val durationUs: Long) {
            var users = 0
            var lastUsedNs = System.nanoTime()
        }

        private val entries = LinkedHashMap<String, Entry>()

        fun acquire(context: Context, uri: String, heightPx: Int): Entry {
            val key = "$heightPx|$uri"
            synchronized(this) {
                entries[key]?.let { entry ->
                    entries.remove(key)
                    entries[key] = entry
                    entry.users++
                    entry.lastUsedNs = System.nanoTime()
                    return entry
                }
            }
            val durationUs = durationUs(context, uri)
            val extractor = FrameExtractor.Builder(context, MediaSources.mediaItem(uri))
                .setSeekParameters(SeekParameters.CLOSEST_SYNC)
                .setEffects(listOf(Presentation.createForHeight(heightPx)))
                .build()
            val entry = Entry(key, extractor, durationUs)
            entry.users = 1
            val evicted = ArrayList<Entry>()
            synchronized(this) {
                val existing = entries[key]
                if (existing != null) {
                    // Another render opened the same file meanwhile: use theirs.
                    existing.users++
                    evicted.add(entry.also { it.users = 0 })
                    closeEntries(evicted)
                    return existing
                }
                entries[key] = entry
                val iterator = entries.values.iterator()
                while (entries.size > MAX_EXTRACTORS && iterator.hasNext()) {
                    val candidate = iterator.next()
                    if (candidate.users == 0) {
                        iterator.remove()
                        evicted.add(candidate)
                    }
                }
            }
            closeEntries(evicted)
            return entry
        }

        fun release(entry: Entry) = synchronized(this) {
            entry.users = max(0, entry.users - 1)
            entry.lastUsedNs = System.nanoTime()
        }

        fun closeIdle(nowNs: Long) {
            val idle = synchronized(this) {
                val list = entries.values.filter { it.users == 0 && nowNs - it.lastUsedNs >= IDLE_CLOSE_MS * 1_000_000 }
                list.forEach { entries.remove(it.key) }
                list
            }
            closeEntries(idle)
        }

        fun closeAll() {
            val all = synchronized(this) {
                val list = entries.values.filter { it.users == 0 }
                list.forEach { entries.remove(it.key) }
                list
            }
            closeEntries(all)
        }

        private fun closeEntries(list: List<Entry>) {
            for (entry in list) {
                try {
                    entry.extractor.close()
                } catch (e: RuntimeException) {
                    Log.w(EngineContext.TAG, "frame extractor close failed: ${e.javaClass.simpleName}")
                }
            }
        }

        private fun durationUs(context: Context, uri: String): Long {
            try {
                MetadataRetriever.Builder(context, MediaSources.mediaItem(uri)).build().use { retriever ->
                    val duration = retriever.retrieveDurationUs().get(Probe.RETRIEVE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                    if (duration == C.TIME_UNSET || duration <= 0) throw EngineException(EngineErrorCode.unsupportedMedia, "media has no duration")
                    return duration
                }
            } catch (e: TimeoutException) {
                throw EngineException(EngineErrorCode.io, "duration timed out", retryable = true, cause = e)
            } catch (t: Throwable) {
                throw MediaSources.mapOpenError(t)
            }
        }
    }

    companion object {
        /** Tiles rendered at once (design/native.md §6.6). */
        const val MAX_RENDERS = 2

        /** Dart's in-flight cap (ARCH §18.1); documented here for the contract tests. */
        const val MAX_IN_FLIGHT = 8

        /** FrameExtractors kept open. */
        const val MAX_EXTRACTORS = 2

        /** Idle time after which an extractor is closed. */
        const val IDLE_CLOSE_MS = 10_000L

        /** JPEG quality (ARCH §15: compress(JPEG, 70)). */
        const val JPEG_QUALITY = 70

        /** Cache file extension. */
        const val CACHE_EXTENSION = "vwth"

        /** Wait limit for one frame. */
        const val FRAME_TIMEOUT_MS = 15_000L

        private fun cancelledError() = EngineException(EngineErrorCode.cancelled, "cancelled")

        /** The request times (ms) of [request] that lie before [durationMs]. */
        fun frameTimesMs(request: ThumbnailRequestMsg, durationMs: Double): List<Long> {
            val first = request.tileIndex * request.framesPerTile
            return (0 until request.framesPerTile).map { (first + it) * request.intervalMs }.filter { it.toDouble() < durationMs }
        }

        /** Cell width of a frame of [width] x [height] drawn [heightPx] high (aspect kept, at least 1). */
        fun frameWidth(width: Int, height: Int, heightPx: Int): Int =
            if (width <= 0 || height <= 0) heightPx else max(1, (width.toDouble() * heightPx / height).roundToInt())

        /** The cache key of [request] (same string and hash as iOS `ThumbnailService.cacheKey`). */
        fun cacheKey(request: ThumbnailRequestMsg): String = CacheStore.stableHash(
            "${request.media.fingerprint}|${request.intervalMs}|${request.heightPx}|${request.tileIndex}|${request.framesPerTile}|${if (request.proxy) 1 else 0}",
        )

        /** "VWTH" + frames (u32 LE) + frame width (u32 LE) + JPEG. */
        fun encodeCached(tile: ThumbnailTileMsg): ByteArray {
            val out = ByteArray(12 + tile.encoded.size)
            "VWTH".toByteArray(Charsets.US_ASCII).copyInto(out)
            writeU32(out, 4, tile.frames)
            writeU32(out, 8, tile.frameWidthPx)
            tile.encoded.copyInto(out, 12)
            return out
        }

        /** Decodes [encodeCached] output; null when malformed. */
        fun decodeCached(data: ByteArray): ThumbnailTileMsg? {
            if (data.size <= 12 || String(data, 0, 4, Charsets.US_ASCII) != "VWTH") return null
            val frames = readU32(data, 4)
            val width = readU32(data, 8)
            if (frames <= 0 || width <= 0) return null
            return ThumbnailTileMsg(encoded = data.copyOfRange(12, data.size), frames = frames, frameWidthPx = width)
        }

        private fun writeU32(out: ByteArray, offset: Int, value: Long) {
            for (i in 0 until 4) out[offset + i] = ((value shr (8 * i)) and 0xFF).toByte()
        }

        private fun readU32(data: ByteArray, offset: Int): Long =
            (0 until 4).fold(0L) { acc, i -> acc or ((data[offset + i].toLong() and 0xFF) shl (8 * i)) }

        /** Draws [frames] aspect-fit into cells of frameWidth x heightPx on black and encodes the JPEG. */
        fun strip(frames: List<Bitmap>, frameWidth: Int, heightPx: Int): ThumbnailTileMsg {
            val strip = Bitmap.createBitmap(frameWidth * frames.size, heightPx, Bitmap.Config.ARGB_8888)
            try {
                val canvas = Canvas(strip)
                canvas.drawColor(Color.BLACK)
                val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
                for ((index, frame) in frames.withIndex()) {
                    val scale = min(frameWidth.toFloat() / frame.width, heightPx.toFloat() / frame.height)
                    val w = frame.width * scale
                    val h = frame.height * scale
                    val left = index * frameWidth + (frameWidth - w) / 2f
                    val top = (heightPx - h) / 2f
                    canvas.drawBitmap(frame, null, RectF(left, top, left + w, top + h), paint)
                }
                val out = ByteArrayOutputStream()
                if (!strip.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)) {
                    throw EngineException(EngineErrorCode.internal, "jpeg encode failed")
                }
                return ThumbnailTileMsg(encoded = out.toByteArray(), frames = frames.size.toLong(), frameWidthPx = frameWidth.toLong())
            } finally {
                strip.recycle()
            }
        }

        /** Decodes a still image about [heightPx] high (inSampleSize), upright per its EXIF orientation. */
        @SuppressLint("ExifInterface")
        fun decodeStill(context: Context, uri: String, heightPx: Int): Bitmap {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            MediaSources.open(context, uri).use { BitmapFactory.decodeStream(it, null, bounds) }
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw EngineException(EngineErrorCode.unsupportedMedia, "image not decodable")
            val orientation = try {
                MediaSources.open(context, uri).use {
                    android.media.ExifInterface(it).getAttributeInt(android.media.ExifInterface.TAG_ORIENTATION, android.media.ExifInterface.ORIENTATION_NORMAL)
                }
            } catch (e: java.io.IOException) {
                android.media.ExifInterface.ORIENTATION_NORMAL
            }
            val rotation = when (orientation) {
                android.media.ExifInterface.ORIENTATION_ROTATE_90, android.media.ExifInterface.ORIENTATION_TRANSPOSE -> 90f
                android.media.ExifInterface.ORIENTATION_ROTATE_180, android.media.ExifInterface.ORIENTATION_FLIP_VERTICAL -> 180f
                android.media.ExifInterface.ORIENTATION_ROTATE_270, android.media.ExifInterface.ORIENTATION_TRANSVERSE -> 270f
                else -> 0f
            }
            val sourceHeight = if (rotation == 90f || rotation == 270f) bounds.outWidth else bounds.outHeight
            var sample = 1
            while (sourceHeight / (sample * 2) >= heightPx) sample *= 2
            val options = BitmapFactory.Options().apply { inSampleSize = sample }
            val decoded = MediaSources.open(context, uri).use { BitmapFactory.decodeStream(it, null, options) }
                ?: throw EngineException(EngineErrorCode.unsupportedMedia, "image not decodable")
            if (rotation == 0f) return decoded
            val rotated = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, Matrix().apply { postRotate(rotation) }, true)
            if (rotated !== decoded) decoded.recycle()
            return rotated
        }
    }
}

/**
 * Pending thumbnail requests: highest priority first (visible > prefetch > background), FIFO within
 * a priority (by [sequenceOf]). Not thread-safe; ThumbnailService guards it.
 */
class ThumbnailQueue<T>(private val priorityOf: (T) -> ThumbPriorityMsg, private val sequenceOf: (T) -> Long) {
    private val items = ArrayList<T>()

    /** Adds [item]. */
    fun add(item: T) {
        items.add(item)
    }

    /** Removes and returns the next item, or null. */
    fun poll(): T? {
        val next = items.minWithOrNull(compareBy({ rank(priorityOf(it)) }, { sequenceOf(it) })) ?: return null
        items.remove(next)
        return next
    }

    /** Removes and returns the first item matching [predicate], or null. */
    fun removeIf(predicate: (T) -> Boolean): T? {
        val index = items.indexOfFirst(predicate)
        return if (index < 0) null else items.removeAt(index)
    }

    /** Pending items. */
    val size: Int get() = items.size

    private fun rank(priority: ThumbPriorityMsg): Int = when (priority) {
        ThumbPriorityMsg.VISIBLE -> 0
        ThumbPriorityMsg.PREFETCH -> 1
        ThumbPriorityMsg.BACKGROUND -> 2
    }
}
