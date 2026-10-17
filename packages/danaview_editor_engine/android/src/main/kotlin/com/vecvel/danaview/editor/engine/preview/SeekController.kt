// OWNER: AND-10
//
// Exact seeks and scrub coalescing (ARCH §5, §12.2, §13.3 "Operations"; D-35). The preview session
// turns `seek(timeUs, exact)` into an output frame `k = frameIndexOf(timeUs)` (floor; clamped to the
// plan's frames) and hands it to this controller, which drives the active PreviewBackend:
//
// - One seek is in flight at a time; a seek requested meanwhile waits as the pending one and a
//   newer request replaces it (latest wins). A replaced request completes with the ack of the one
//   that replaced it (the same rule as the Dart side's scrub coalescing, ENG-02).
// - An exact seek is acknowledged by the first frame the backend reports as displayed with index
//   k, where the backend identifies a platform presentation time τ as `frameIndexNearest(τ)` (never
//   by comparing τ with a plan edge). A scrub is acknowledged by the first frame displayed after it
//   was issued, whatever its index ("may show any frame within ±1 GOP and still reports the
//   displayed frame").
// - Timeout (D-35): after [exactTimeoutMs] (500 ms; a backend may ask for longer, see
//   PreviewBackend.exactSeekTimeoutMs) the seek is acknowledged with the frame actually displayed.
// - Backend positions use frame_grid.json's `androidSeekMsRounding` = "floor" ([SeekMath.seekMs]):
//   AND-16's decks seek to `floor((ruleFramePts − clipStart) / 1000)` ms with SeekParameters.EXACT.
//
// Confined to the scheduler's thread (danaview-preview); [onFrameDisplayed] may be called with
// frames that belong to no seek (playback), they only update [displayed].

package com.vecvel.danaview.editor.engine.preview

import com.vecvel.danaview.editor.engine.core.Cancellable
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.plan.FrameGrid

/** Pure frame-grid helpers of seeking (D-35; JVM-free, checked against frame_grid.json). */
object SeekMath {
    /** frame_grid.json `androidSeekMsRounding` (ENG-06, AND-01 V-N18). */
    const val ANDROID_SEEK_MS_ROUNDING = "floor"

    /** Number of output frames of a plan lasting [durUs]: the smallest K with timeOfFrame(K) >= durUs. */
    fun frameCount(grid: FrameGrid, durUs: Long): Long {
        if (durUs <= 0) return 0
        val k = grid.frameIndexOf(durUs)
        return if (grid.timeOfFrame(k) < durUs) k + 1 else k
    }

    /** The frame a seek to [timeUs] shows: frameIndexOf(t) (floor), clamped to [0, frameCount − 1]. */
    fun targetFrame(grid: FrameGrid, timeUs: Long, frameCount: Long): Long {
        val k = grid.frameIndexOf(timeUs.coerceAtLeast(0))
        return if (frameCount <= 0) k.coerceAtLeast(0) else k.coerceIn(0, frameCount - 1)
    }

    /** The output frame a platform presentation time [ptsUs] belongs to: frameIndexNearest (D-35). */
    fun displayedFrame(grid: FrameGrid, ptsUs: Long): Long = grid.frameIndexNearest(ptsUs)

    /** A platform µs position as a player seek in ms, rounded down ("floor"). */
    fun seekMs(platformUs: Long): Long = Math.floorDiv(platformUs, 1000L)

    /** A deck seek inside a clipped item: floor((ruleFramePts − clipStart) / 1000) ms (ARCH §13.3). */
    fun deckSeekMs(ruleFramePtsUs: Long, clipStartUs: Long): Long = seekMs(ruleFramePtsUs - clipStartUs)

    /** Frame [k]'s platform seek position in ms: floor(P(k) / 1000) with P(k) = round(k·1e6/fps). */
    fun frameSeekMs(grid: FrameGrid, k: Long): Long = seekMs(grid.platformTimeOfFrame(k))
}

/** Seek requests and acks (file header). */
class SeekController(
    private val scheduler: DebounceScheduler,
    /** Starts a backend seek to frame `target`; `done` fails when the backend cannot seek. */
    private val issue: (target: Long, exact: Boolean, done: Completion<Unit>) -> Unit,
) {
    /** An acknowledged seek: the frame displayed, the command seq, and whether it is the exact target. */
    data class Ack(val requestedUs: Long, val target: Long, val displayedFrame: Long, val seq: Long, val exactHit: Boolean, val latencyMs: Long, val timedOut: Boolean)

    /** One seek request (the session's command [seq]). */
    class Request(val requestedUs: Long, val target: Long, val exact: Boolean, val seq: Long, val done: Completion<Ack>) {
        internal val followers = ArrayList<Request>()
    }

    /** Exact-seek timeout (D-35: 500 ms), then the ack reports the frame actually displayed. */
    var exactTimeoutMs: Long = EXACT_TIMEOUT_MS

    /** Scrub timeout. */
    var scrubTimeoutMs: Long = EXACT_TIMEOUT_MS

    /** The last frame a backend reported as displayed (-1 before the first). */
    var displayed: Long = -1
        private set

    private var inFlight: Request? = null
    private var issuedAtMs = 0L
    private var timer: Cancellable? = null
    private var pending: Request? = null
    private var token = 0L

    /** Seeks acknowledged so far / acknowledged by timeout / that hit their exact target. */
    var acked: Int = 0
        private set
    var timeouts: Int = 0
        private set
    var exactHits: Int = 0
        private set

    /** Whether a seek is in flight or pending. */
    val isBusy: Boolean get() = inFlight != null || pending != null

    /** The seek in flight (null when idle). */
    val current: Request? get() = inFlight

    /** Requests a seek; it starts now or replaces the pending one. */
    fun request(r: Request) {
        if (inFlight == null) {
            start(r)
            return
        }
        pending?.let { old ->
            r.followers += old
            r.followers += old.followers
            old.followers.clear()
        }
        pending = r
    }

    /** A backend frame [k] is on screen (any thread's events must be posted to the scheduler first). */
    fun onFrameDisplayed(k: Long) {
        displayed = k
        val r = inFlight ?: return
        if (!r.exact || k == r.target) complete(r, k, timedOut = false)
    }

    /** Forgets the displayed frame (a new plan or surface: nothing valid is on screen yet). */
    fun resetDisplayed(k: Long = -1) {
        displayed = k
    }

    /** Fails every seek in flight or pending with [error] (dispose, suspension). */
    fun cancelAll(error: Throwable = EngineException(EngineErrorCode.cancelled, "seek cancelled")) {
        timer?.cancel()
        timer = null
        token++
        val all = listOfNotNull(inFlight, pending)
        inFlight = null
        pending = null
        for (r in all) fail(r, error)
    }

    private fun start(r: Request) {
        inFlight = r
        issuedAtMs = scheduler.nowMs()
        val myToken = ++token
        val timeout = if (r.exact) exactTimeoutMs else scrubTimeoutMs
        timer = scheduler.schedule(timeout) {
            if (token == myToken && inFlight === r) {
                timeouts++
                complete(r, displayed.coerceAtLeast(0), timedOut = true)
            }
        }
        try {
            issue(r.target, r.exact) { result ->
                result.exceptionOrNull()?.let { e ->
                    scheduler.post {
                        if (token == myToken && inFlight === r) {
                            timer?.cancel()
                            timer = null
                            inFlight = null
                            fail(r, e)
                            startNext()
                        }
                    }
                }
            }
        } catch (t: Throwable) {
            timer?.cancel()
            timer = null
            inFlight = null
            fail(r, t)
            startNext()
        }
    }

    private fun complete(r: Request, k: Long, timedOut: Boolean) {
        timer?.cancel()
        timer = null
        inFlight = null
        acked++
        if (k == r.target) exactHits++
        val ack = Ack(r.requestedUs, r.target, k, r.seq, k == r.target, scheduler.nowMs() - issuedAtMs, timedOut)
        r.done(Result.success(ack))
        for (f in r.followers) f.done(Result.success(ack))
        startNext()
    }

    private fun fail(r: Request, error: Throwable) {
        val e = EngineErrors.from(error)
        r.done(Result.failure(e))
        for (f in r.followers) f.done(Result.failure(e))
    }

    private fun startNext() {
        val next = pending ?: return
        pending = null
        start(next)
    }

    companion object {
        /** D-35 exact-seek ack timeout. */
        const val EXACT_TIMEOUT_MS = 500L
    }
}
