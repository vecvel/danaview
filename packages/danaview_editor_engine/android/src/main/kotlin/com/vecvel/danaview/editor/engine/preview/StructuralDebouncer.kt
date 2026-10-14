// OWNER: AND-17
//
// StructuralDebouncer (D-36, ARCH §13.3 "Operations", §13.4): structural patches (layer set, kind,
// z, time, asset, map or hold changes; ARCH §11.2 patch classification) rebuild the preview
// backend (AND-16: a re-plan of the affected slots' decks; any Media3 player: setComposition),
// which costs hundreds of milliseconds. Editing gestures that commit several structural patches in
// a row must not rebuild for each one, so they are coalesced:
//
// - trailing debounce: a rebuild starts [trailingMs] (150 ms) after the last patch of a burst;
// - max wait: a rebuild starts at the latest [maxWaitMs] (600 ms) after the first patch not yet
//   rebuilt, so a steady stream of patches still shows its result;
// - one rebuild at a time: patches arriving while a rebuild runs are merged ([merge]) and rebuilt
//   after it completes (immediately when their max wait has already passed);
// - [flush] starts the pending rebuild now (play pressed: playback never starts on a stale build);
//   [cancel] drops it (session dispose).
// While paused the new frame is shown at once by PausedFrameRenderer and the rebuild runs in the
// background; when it completes during playback the backend swaps to its own output on its first
// frame (the session's job). 10 patches in 1 s give at most 3 rebuilds (JVM test
// paused/StructuralDebouncerTest, androidTest paused/StructuralDebounceTest).
//
// All entry points and callbacks run on one thread: the [DebounceScheduler]'s (production: the
// danaview-preview lane's Handler, [HandlerDebounceScheduler]). [rebuild] receives the merged value
// and a `done` callback it must call (on any thread) when the rebuild has finished or failed.

package com.vecvel.danaview.editor.engine.preview

import android.os.Handler
import android.os.SystemClock
import com.vecvel.danaview.editor.engine.core.Cancellable

/** Time and delayed tasks of a [StructuralDebouncer]. */
interface DebounceScheduler {
    /** Monotonic time in ms. */
    fun nowMs(): Long

    /** Runs [task] on the scheduler's thread after [delayMs]. */
    fun schedule(delayMs: Long, task: Runnable): Cancellable

    /** Runs [task] on the scheduler's thread as soon as possible. */
    fun post(task: Runnable)
}

/** A [DebounceScheduler] on an Android [handler] (uptime clock). */
class HandlerDebounceScheduler(private val handler: Handler) : DebounceScheduler {
    override fun nowMs(): Long = SystemClock.uptimeMillis()

    override fun schedule(delayMs: Long, task: Runnable): Cancellable {
        handler.postDelayed(task, delayMs.coerceAtLeast(0L))
        return Cancellable { handler.removeCallbacks(task) }
    }

    override fun post(task: Runnable) {
        handler.post(task)
    }
}

/** Coalesces structural patches into few rebuilds (file header). */
class StructuralDebouncer<T : Any>(
    private val scheduler: DebounceScheduler,
    /** Merges a newly submitted value into the pending one (default: the latest wins). */
    private val merge: (pending: T, next: T) -> T = { _, next -> next },
    private val trailingMs: Long = TRAILING_MS,
    private val maxWaitMs: Long = MAX_WAIT_MS,
    /** Starts a rebuild of [value]; must call `done` exactly once when it has finished. */
    private val rebuild: (value: T, done: () -> Unit) -> Unit,
) {
    init {
        require(trailingMs >= 0 && maxWaitMs >= trailingMs) { "trailing ≤ max wait" }
    }

    private var pending: T? = null
    private var firstPendingAt = 0L
    private var lastPendingAt = 0L
    private var timer: Cancellable? = null
    private var running = false
    private var runToken = 0L

    /** Patches submitted so far. */
    var submitted: Int = 0
        private set

    /** Rebuilds started so far. */
    var rebuilds: Int = 0
        private set

    /** Whether a value waits for its rebuild. */
    val isPending: Boolean get() = pending != null

    /** Whether a rebuild is running. */
    val isRebuilding: Boolean get() = running

    /** Called (on the scheduler thread) when no rebuild is running and none is pending. */
    var onIdle: (() -> Unit)? = null

    /** Submits a structural change [value] (merged into the pending one). */
    fun submit(value: T) {
        val now = scheduler.nowMs()
        submitted++
        val current = pending
        if (current == null) {
            pending = value
            firstPendingAt = now
        } else {
            pending = merge(current, value)
        }
        lastPendingAt = now
        if (!running) arm()
    }

    /** Starts the pending rebuild now (or right after the running one). */
    fun flush() {
        if (pending == null) return
        firstPendingAt = Long.MIN_VALUE / 2
        lastPendingAt = Long.MIN_VALUE / 2
        if (!running) arm()
    }

    /** Drops the pending value and its timer (a running rebuild still completes). */
    fun cancel() {
        timer?.cancel()
        timer = null
        pending = null
    }

    /** The time the pending rebuild is due: min(last + trailing, first + max wait). */
    private fun dueAt(): Long = minOf(lastPendingAt + trailingMs, firstPendingAt + maxWaitMs)

    private fun arm() {
        timer?.cancel()
        timer = null
        if (pending == null) return
        val delay = dueAt() - scheduler.nowMs()
        if (delay <= 0) {
            start()
        } else {
            timer = scheduler.schedule(delay) {
                timer = null
                if (!running && pending != null) {
                    if (dueAt() <= scheduler.nowMs()) start() else arm()
                }
            }
        }
    }

    private fun start() {
        val value = pending ?: return
        pending = null
        running = true
        rebuilds++
        val token = ++runToken
        var finished = false
        rebuild(value) {
            scheduler.post {
                if (finished || token != runToken) return@post
                finished = true
                running = false
                if (pending != null) arm() else onIdle?.invoke()
            }
        }
    }

    companion object {
        /** Trailing debounce (D-36). */
        const val TRAILING_MS = 150L

        /** Longest wait after the first pending patch (D-36). */
        const val MAX_WAIT_MS = 600L
    }
}
