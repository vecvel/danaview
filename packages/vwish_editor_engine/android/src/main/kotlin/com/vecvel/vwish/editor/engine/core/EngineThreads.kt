// OWNER: ENG-08
//
// The engine's threads (ARCH §18.1): the platform main thread plus five named lanes, each a
// HandlerThread with its own Looper so Media3 players, Transformer, FrameExtractor and GL contexts
// can be bound to it:
//
//   vwish-preview  preview sessions: plan apply, seek, transport, clock (AND-10, AND-16)
//   vwish-gl       GL compositing and effects (AND-09, AND-17)
//   vwish-export   ExportCoordinator and its Transformer (AND-11)
//   vwish-jobs     thumbnails and media jobs (AND-03..AND-07)
//   vwish-io       probe, compatibility, stat/hash, caches, recorder control (AND-02, AND-14, ...)
//
// Host handlers run on main, validate, post to a lane and reply on main (ARCH §12.6). Lanes start
// lazily, so an app that never opens the editor creates no threads.

package com.vecvel.vwish.editor.engine.core

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import java.util.concurrent.Executor
import java.util.concurrent.RejectedExecutionException

/** A cancellable delayed task. */
fun interface Cancellable {
    /** Cancels the task if it has not run yet. */
    fun cancel()
}

/** The platform main thread as seen by the engine (fakeable in JVM tests). */
interface MainScheduler : Executor {
    /** Runs [task] on the main thread after [delayMs]. */
    fun postDelayed(task: Runnable, delayMs: Long): Cancellable

    /** Monotonic milliseconds (SystemClock.uptimeMillis on Android). */
    fun nowMs(): Long

    /** Whether the caller is on the main thread. */
    fun isCurrentThread(): Boolean
}

/** The five engine lanes, their thread names and priorities (ARCH §18.1). */
enum class LaneSpec(val threadName: String, val priority: Int) {
    PREVIEW("vwish-preview", Process.THREAD_PRIORITY_DISPLAY),
    GL("vwish-gl", Process.THREAD_PRIORITY_DISPLAY),
    EXPORT("vwish-export", Process.THREAD_PRIORITY_DEFAULT),
    JOBS("vwish-jobs", Process.THREAD_PRIORITY_BACKGROUND),
    IO("vwish-io", Process.THREAD_PRIORITY_BACKGROUND),
}

/** One serial engine lane. [execute] throws [RejectedExecutionException] after [quit]. */
interface Lane : Executor {
    /** Which lane this is. */
    val spec: LaneSpec

    /** The lane's Looper (null for test lanes without one). */
    val looper: Looper?

    /** A Handler on [looper] (null for test lanes). */
    val handler: Handler?

    /** Whether the caller runs on this lane. */
    fun isCurrentThread(): Boolean

    /** Stops the lane after the queued tasks. */
    fun quit()
}

/** A [Lane] backed by a [HandlerThread]. */
class HandlerLane(override val spec: LaneSpec) : Lane {
    private val thread = HandlerThread(spec.threadName, spec.priority).apply { start() }

    override val looper: Looper = thread.looper
    override val handler: Handler = Handler(looper)

    @Volatile private var quitting = false

    override fun execute(command: Runnable) {
        if (quitting || !handler.post(command)) throw RejectedExecutionException("${spec.threadName} has quit")
    }

    override fun isCurrentThread(): Boolean = Looper.myLooper() == looper

    override fun quit() {
        quitting = true
        thread.quitSafely()
    }
}

/** The Android main thread. */
class AndroidMainScheduler : MainScheduler {
    private val handler = Handler(Looper.getMainLooper())

    override fun execute(command: Runnable) {
        handler.post(command)
    }

    override fun postDelayed(task: Runnable, delayMs: Long): Cancellable {
        handler.postDelayed(task, delayMs)
        return Cancellable { handler.removeCallbacks(task) }
    }

    override fun nowMs(): Long = SystemClock.uptimeMillis()

    override fun isCurrentThread(): Boolean = Looper.myLooper() == Looper.getMainLooper()
}

/**
 * The engine's main scheduler and lanes (ARCH §18.1). Lanes are created on first use by
 * [laneFactory] ([HandlerLane] on Android; immediate or recording lanes in JVM tests).
 */
class EngineThreads(
    val main: MainScheduler,
    private val laneFactory: (LaneSpec) -> Lane = ::HandlerLane,
) {
    private val lanes = HashMap<LaneSpec, Lane>()

    /** The lane for [spec], started on first use. */
    fun lane(spec: LaneSpec): Lane = synchronized(lanes) { lanes.getOrPut(spec) { laneFactory(spec) } }

    /** vwish-preview. */
    val preview: Lane get() = lane(LaneSpec.PREVIEW)

    /** vwish-gl. */
    val gl: Lane get() = lane(LaneSpec.GL)

    /** vwish-export. */
    val export: Lane get() = lane(LaneSpec.EXPORT)

    /** vwish-jobs. */
    val jobs: Lane get() = lane(LaneSpec.JOBS)

    /** vwish-io. */
    val io: Lane get() = lane(LaneSpec.IO)

    /** Lanes started so far. */
    fun started(): List<Lane> = synchronized(lanes) { lanes.values.toList() }

    /** Quits every started lane (process teardown and tests). */
    fun shutdown() {
        val all = synchronized(lanes) { lanes.values.toList().also { lanes.clear() } }
        all.forEach { it.quit() }
    }

    companion object {
        /** Main thread + HandlerThread lanes. */
        fun android(): EngineThreads = EngineThreads(AndroidMainScheduler())
    }
}
