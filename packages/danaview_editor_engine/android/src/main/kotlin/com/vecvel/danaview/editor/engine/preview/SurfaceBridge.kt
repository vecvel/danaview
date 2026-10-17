// OWNER: AND-10
//
// SurfaceBridge (ARCH §12.7 "Android", §13.3): the preview texture is a Flutter SurfaceProducer
// created with `SurfaceLifecycle.resetInBackground`, so Flutter may destroy its Surface while the
// app is in the background (trim memory) and hand out a new one when it returns:
//
// - `onSurfaceCleanup` (main thread) asks the session, on danaview-preview, to stop drawing on the
//   Surface (destroy the paused renderer's EGL window surface; AND-16's frame clock detaches the
//   same way) and waits for that on a latch for at most [latchTimeoutMs] (500 ms). The main thread
//   never waits longer; the preview thread never waits on main (every main-thread step here is
//   posted, never awaited, from the preview side). A latch that times out is counted
//   ([latchTimeouts]); the Surface is released by Flutter anyway.
// - `onSurfaceAvailable` (main thread) fetches the new Surface and posts it to the session, which
//   reattaches and redraws the last frame (ARCH §12.7).
// - Every SurfaceProducer call (create, setSize, getSurface, release) runs on the main thread, the
//   thread Flutter's texture registry expects; results come back to danaview-preview by post.
//
// Quality changes resize the producer ([resize]): Flutter then hands out a new Surface of the new
// size, which the session attaches like a recovered one. Never logs content.

package com.vecvel.danaview.editor.engine.preview

import android.os.SystemClock
import android.view.Surface
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.Lane
import com.vecvel.danaview.editor.engine.core.MainScheduler
import io.flutter.view.TextureRegistry
import java.util.concurrent.CountDownLatch
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/** SurfaceProducer bridge: resetInBackground, <= 500 ms cleanup latch (ARCH §12.7; AND-10). */
class SurfaceBridge(
    private val main: MainScheduler,
    private val previewLane: Lane,
    private val listener: Listener,
    /** Longest main-thread wait in onSurfaceCleanup (ARCH §12.7: 500 ms). */
    private val latchTimeoutMs: Long = LATCH_TIMEOUT_MS,
) : TextureRegistry.SurfaceProducer.Callback {
    /** What the bridge tells the session; both calls arrive on danaview-preview. */
    interface Listener {
        /** Stop drawing on the current Surface now; call [done] (any thread) once nothing renders to it. */
        fun onSurfaceLost(done: () -> Unit)

        /** A new [surface] ([width] × [height]) replaced the lost one: reattach and redraw the last frame. */
        fun onSurfaceAvailable(surface: Surface, width: Int, height: Int)
    }

    /** The opened producer: its texture id, Surface and size. */
    data class Opened(val textureId: Long, val surface: Surface, val width: Int, val height: Int)

    @Volatile private var producer: TextureRegistry.SurfaceProducer? = null
    @Volatile private var released = false

    private val latches = AtomicInteger()
    private val timeouts = AtomicInteger()
    private val maxLatchNs = AtomicLong()
    private val lastLatchNs = AtomicLong()
    private val available = AtomicInteger()

    /** onSurfaceCleanup calls so far. */
    val latchCount: Int get() = latches.get()

    /** Cleanup latches that hit the timeout. */
    val latchTimeouts: Int get() = timeouts.get()

    /** Longest main-thread wait so far, ms. */
    val maxLatchMs: Double get() = maxLatchNs.get() / 1e6

    /** Last main-thread wait, ms. */
    val lastLatchMs: Double get() = lastLatchNs.get() / 1e6

    /** onSurfaceAvailable calls so far. */
    val availableCount: Int get() = available.get()

    /** The texture id (-1 before [open]). */
    @Volatile var textureId: Long = -1
        private set

    /**
     * Creates the producer on [textures] (resetInBackground) at [width] × [height] on the main
     * thread; [done] is called on danaview-preview.
     */
    fun open(textures: TextureRegistry, width: Int, height: Int, done: Completion<Opened>) {
        onMain(done) {
            check(!released) { "released" }
            val p = textures.createSurfaceProducer(TextureRegistry.SurfaceLifecycle.resetInBackground)
            p.setSize(width, height)
            p.setCallback(this)
            producer = p
            textureId = p.id()
            Opened(p.id(), p.surface, p.width, p.height)
        }
    }

    /** Resizes the producer; [done] gets the (possibly new) Surface of the new size, on danaview-preview. */
    fun resize(width: Int, height: Int, done: Completion<Opened>) {
        onMain(done) {
            val p = producer ?: throw EngineException(EngineErrorCode.surfaceLost, "no surface producer")
            p.setSize(width, height)
            Opened(p.id(), p.surface, p.width, p.height)
        }
    }

    /** Releases the producer and its texture (main thread; idempotent). [done] is called on danaview-preview. */
    fun release(done: Completion<Unit>) {
        released = true
        onMain(done) {
            producer?.let {
                it.setCallback(null)
                it.release()
            }
            producer = null
        }
    }

    // ---- SurfaceProducer.Callback (main thread) ----

    override fun onSurfaceCleanup() {
        if (released || producer == null) return
        val latch = CountDownLatch(1)
        val start = SystemClock.elapsedRealtimeNanos()
        try {
            previewLane.execute {
                try {
                    listener.onSurfaceLost { latch.countDown() }
                } catch (t: Throwable) {
                    latch.countDown()
                    throw t
                }
            }
        } catch (_: RejectedExecutionException) {
            latch.countDown()
        }
        val ok = try {
            latch.await(latchTimeoutMs, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        val waited = SystemClock.elapsedRealtimeNanos() - start
        latches.incrementAndGet()
        if (!ok) timeouts.incrementAndGet()
        lastLatchNs.set(waited)
        maxLatchNs.accumulateAndGet(waited) { a, b -> maxOf(a, b) }
    }

    override fun onSurfaceAvailable() {
        val p = producer ?: return
        if (released) return
        available.incrementAndGet()
        val surface = p.surface
        val w = p.width
        val h = p.height
        try {
            previewLane.execute { listener.onSurfaceAvailable(surface, w, h) }
        } catch (_: RejectedExecutionException) {
            // The session is gone.
        }
    }

    private fun <T> onMain(done: Completion<T>, block: () -> T) {
        val reply: (Result<T>) -> Unit = { r ->
            try {
                previewLane.execute { done(r) }
            } catch (_: RejectedExecutionException) {
                done(r)
            }
        }
        val task = Runnable { reply(runCatching(block)) }
        if (main.isCurrentThread()) task.run() else main.execute(task)
    }

    companion object {
        /** ARCH §12.7: the main thread waits at most 500 ms in onSurfaceCleanup. */
        const val LATCH_TIMEOUT_MS = 500L
    }
}
