@file:OptIn(UnstableApi::class, ExperimentalApi::class)

package com.vecvel.vwish.spike.engine

import android.content.Context
import android.graphics.PixelFormat
import android.hardware.HardwareBuffer
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.DefaultVideoFrameProcessor
import androidx.media3.effect.MultipleInputVideoGraph
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.transformer.Composition
import androidx.media3.transformer.CompositionPlayer
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

data class RenderedFrame(val ptsUs: Long, val releaseTimeNs: Long, val wallNs: Long)

data class ReaderImage(val timestampNs: Long, val wallNs: Long, val rows: Map<Int, IntArray>?)

/**
 * CompositionPlayer on its own looper (ARCH §13.3 "Session": MultipleInputVideoGraph with
 * WORKING_COLOR_SPACE_ORIGINAL, no replayable cache unless asked), rendering into an ImageReader
 * surface that stands in for the Flutter SurfaceProducer.
 */
class PlayerHarness(
    private val context: Context,
    val width: Int,
    val height: Int,
    replayableCache: Boolean = false,
    /**
     * false (default for correctness tests): late decoded input is never dropped, so every output
     * frame is composited from its own source frames even when the emulator cannot keep up.
     * true: Media3's default late-drop policy (performance runs).
     */
    dropLateInput: Boolean = false,
    /** false: CompositionPlayer's default video graph (diagnostics only; ARCH uses MultipleInputVideoGraph). */
    multipleInputVideoGraph: Boolean = true,
    configure: (CompositionPlayer.Builder) -> Unit = {},
) : AutoCloseable {
    private val thread = HandlerThread("spike-player").apply { start() }
    private val handler = Handler(thread.looper)
    private val readerThread = HandlerThread("spike-reader").apply { start() }
    val reader: ImageReader = ImageReader.newInstance(
        width,
        height,
        PixelFormat.RGBA_8888,
        4,
        HardwareBuffer.USAGE_GPU_COLOR_OUTPUT or HardwareBuffer.USAGE_CPU_READ_OFTEN,
    )
    lateinit var player: CompositionPlayer
        private set
    val rendered = ConcurrentLinkedQueue<RenderedFrame>()
    val images = ConcurrentLinkedQueue<ReaderImage>()
    val dropped = AtomicInteger()
    val error = AtomicReference<PlaybackException?>()

    /** Canvas rows (y down) to copy out of every ImageReader image, or empty for none. */
    @Volatile var readRows: List<Int> = emptyList()

    init {
        reader.setOnImageAvailableListener({ r ->
            val img = r.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                val rows = if (readRows.isEmpty()) null else readRows.associateWith { y -> readRow(img, y) }
                images.add(ReaderImage(img.timestamp, System.nanoTime(), rows))
            } finally {
                img.close()
            }
        }, Handler(readerThread.looper))
        run {
            val b = CompositionPlayer.Builder(context)
                .setLooper(thread.looper)
                .experimentalSetEnableReplayableCache(replayableCache)
            if (multipleInputVideoGraph) {
                b.setVideoGraphFactory(
                    MultipleInputVideoGraph.Factory(
                        DefaultVideoFrameProcessor.Factory.Builder()
                            .setSdrWorkingColorSpace(DefaultVideoFrameProcessor.WORKING_COLOR_SPACE_ORIGINAL)
                            .build(),
                    ),
                )
            }
            if (!dropLateInput) b.experimentalSetLateThresholdToDropInputUs(androidx.media3.common.C.TIME_UNSET)
            configure(b)
            player = b.build()
            player.addListener(object : Player.Listener {
                override fun onPlayerError(e: PlaybackException) {
                    error.set(e)
                }
            })
            player.addAnalyticsListener(object : AnalyticsListener {
                override fun onDroppedVideoFrames(eventTime: AnalyticsListener.EventTime, droppedFrames: Int, elapsedMs: Long) {
                    dropped.addAndGet(droppedFrames)
                }
            })
            player.setVideoFrameMetadataListener { pts, releaseNs, _, _ ->
                rendered.add(RenderedFrame(pts, releaseNs, System.nanoTime()))
            }
            player.setVideoSurface(reader.surface, Size(width, height))
        }
    }

    private fun readRow(img: android.media.Image, y: Int): IntArray {
        val plane = img.planes[0]
        val buf = plane.buffer
        val out = IntArray(width)
        val base = y.coerceIn(0, height - 1) * plane.rowStride
        for (x in 0 until width) {
            val i = base + x * plane.pixelStride
            out[x] = ((buf.get(i).toInt() and 0xff) shl 16) or ((buf.get(i + 1).toInt() and 0xff) shl 8) or (buf.get(i + 2).toInt() and 0xff)
        }
        return out
    }

    /** Runs [block] on the player looper and returns its result. */
    fun <T> run(block: () -> T): T {
        if (Thread.currentThread() == thread) return block()
        val result = AtomicReference<Any?>()
        val failure = AtomicReference<Throwable?>()
        val latch = CountDownLatch(1)
        handler.post {
            try {
                result.set(block())
            } catch (t: Throwable) {
                failure.set(t)
            } finally {
                latch.countDown()
            }
        }
        check(latch.await(20, TimeUnit.SECONDS)) { "player looper blocked" }
        failure.get()?.let { throw it }
        @Suppress("UNCHECKED_CAST")
        return result.get() as T
    }

    fun load(c: Composition, positionMs: Long = 0) = run {
        player.setComposition(c, positionMs)
        if (player.playbackState == Player.STATE_IDLE) player.prepare()
    }

    fun state(): Int = run { player.playbackState }

    /** Detaches the player from the ImageReader surface (paused-renderer hand-off, D-36). */
    fun detachSurface() = run {
        // CompositionPlayer 1.11.1 checkArgument(output == current output): the no-arg
        // clearVideoSurface() passes null and throws IllegalArgumentException (AND-01 finding).
        player.clearVideoSurface(reader.surface)
    }

    /** Reattaches the ImageReader surface to the player. */
    fun attachSurface() = run { player.setVideoSurface(reader.surface, Size(width, height)) }

    /** Plays until STATE_ENDED (or [timeoutMs]); returns whether it ended. */
    fun playToEnd(timeoutMs: Long): Boolean {
        run { player.play() }
        val end = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < end) {
            error.get()?.let { throw AssertionError("player error", it) }
            if (state() == Player.STATE_ENDED) return true
            Thread.sleep(20)
        }
        return false
    }

    /**
     * Seeks to [positionMs] and waits for the first rendered frame after the seek; returns it with
     * the wall latency in ms, or null on timeout.
     */
    fun seekAndAwait(positionMs: Long, timeoutMs: Long, predicate: (RenderedFrame) -> Boolean = { true }): Pair<RenderedFrame, Double>? {
        val t0 = System.nanoTime()
        run { player.seekTo(positionMs) }
        val f = awaitRendered(t0, timeoutMs, predicate) ?: return null
        return f to (f.wallNs - t0) / 1e6
    }

    /**
     * Plays from the current position until a frame with index >= [k] (at [fps]) is rendered, then
     * pauses. Multi-sequence compositions cannot seek in Media3 1.11.1 (R1, SeekDiagnosticsTest),
     * so player tests reach a paused frame this way. Returns the paused frame (the last one rendered
     * after the pause settled), or null if no frame >= [k] came within [timeoutMs].
     */
    fun playUntilFrame(k: Long, fps: Int, timeoutMs: Long): RenderedFrame? {
        val t0 = System.nanoTime()
        run { player.play() }
        val reached = awaitRendered(t0, timeoutMs) { GridTime.frameIndexNearest(it.ptsUs, fps) >= k }
        run { player.pause() }
        if (reached == null) return null
        Thread.sleep(400)
        return rendered.filter { it.wallNs >= t0 }.maxByOrNull { it.ptsUs }
    }

    /** The ImageReader image of a rendered frame (matched by release time), or the newest image after [sinceNs]. */
    fun imageOf(frame: RenderedFrame, sinceNs: Long): ReaderImage? =
        images.lastOrNull { it.timestampNs == frame.releaseTimeNs } ?: images.lastOrNull { it.wallNs >= sinceNs }

    fun positionMs(): Long = run { player.currentPosition }

    fun awaitReady(timeoutMs: Long = 90_000) {
        val end = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < end) {
            error.get()?.let { throw AssertionError("player error", it) }
            if (state() == Player.STATE_READY) return
            Thread.sleep(10)
        }
        throw AssertionError("player not ready after $timeoutMs ms (state ${state()})")
    }

    /** Waits for a rendered frame (VideoFrameMetadataListener) matching [predicate] after [sinceNs]. */
    fun awaitRendered(sinceNs: Long, timeoutMs: Long, predicate: (RenderedFrame) -> Boolean): RenderedFrame? {
        val end = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < end) {
            error.get()?.let { throw AssertionError("player error", it) }
            rendered.firstOrNull { it.wallNs >= sinceNs && predicate(it) }?.let { return it }
            Thread.sleep(2)
        }
        return null
    }

    fun awaitImage(sinceNs: Long, timeoutMs: Long, predicate: (ReaderImage) -> Boolean = { true }): ReaderImage? {
        val end = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < end) {
            error.get()?.let { throw AssertionError("player error", it) }
            images.firstOrNull { it.wallNs >= sinceNs && predicate(it) }?.let { return it }
            Thread.sleep(2)
        }
        return null
    }

    override fun close() {
        try {
            run { player.release() }
        } finally {
            reader.close()
            thread.quitSafely()
            readerThread.quitSafely()
        }
    }
}
