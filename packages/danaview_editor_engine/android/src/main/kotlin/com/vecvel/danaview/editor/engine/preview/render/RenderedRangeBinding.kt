// OWNER: AND-18
//
// RenderedRangeBinding: one session's RenderedRangeSwap bound to its AND-16 backend (ARCH D-45,
// §12.2 "Rendered ranges"). [apply] installs the swap as the backend's rendered-range hook (once),
// replaces the ranges and rebuilds the backend on the session's current plan, so the next playback
// (or the one running) picks them up. During playback the backend asks the swap about every frame
// inside a range (RenderedRangeHook.isValid), so a change that touched the range falls back to the
// live decks on the next frame; the swap's [RenderedRangeSwap.onDropped] then posts a rebuild here
// that removes the range deck. While ranges exist a slow poll on the session's lane
// (danaview-preview, every [POLL_MS]; paused frames never use a range, so this is only
// bookkeeping) runs the same invalidation while nothing plays and retries a rebuild that had to
// wait: a rebuild waits while [ready] says no (session closed, suspended for an export, or showing
// a source frame). The poll stops when no range is left; when [alive] turns false it stops for
// good and [onGone] runs. Used by RenderedRangeHandler (PreviewSession) and by the instrumented
// tests (AND-16's DirectHost). Never logs URIs.

package com.vecvel.danaview.editor.engine.preview.render

import android.os.Handler
import android.os.SystemClock
import android.util.Log
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.preview.fallback.ContingencyPreviewBackend
import java.util.concurrent.atomic.AtomicReference

/** A swap bound to a backend and a lane (file header). Call everything on [handler]'s thread. */
class RenderedRangeBinding(
    private val backend: ContingencyPreviewBackend,
    private val snapshot: AtomicReference<ParamSnapshot>,
    private val handler: Handler,
    /** Whether the backend may be rebuilt now. */
    private val ready: () -> Boolean = { true },
    /** Whether the session still exists (false ends the poll). */
    private val alive: () -> Boolean = { true },
    /** Runs on [handler] once [alive] turned false (the owner forgets this binding). */
    private val onGone: () -> Unit = {},
) {
    /** The hook installed on the backend. */
    val swap = RenderedRangeSwap(snapshot)

    private val token = Any()

    init {
        // A drop seen on danaview-gl (per-frame check) or by the poll: rebuild without the range.
        swap.onDropped = { handler.postAtTime({ onRangeDropped() }, token, SystemClock.uptimeMillis()) }
    }

    private var pendingRebuild = false
    private var polling = false

    /** Rebuilds requested (tests). */
    @Volatile var rebuilds = 0
        private set

    /** Replaces the ranges (setRenderedRanges) and rebuilds the backend. */
    fun apply(entries: List<RenderedRangeSwap.Entry>) {
        val hadRanges = !swap.isEmpty
        swap.set(entries, snapshot.get())
        if (backend.renderedRangeHook !== swap) backend.renderedRangeHook = swap
        if (entries.isNotEmpty() || hadRanges) {
            pendingRebuild = true
            rebuildIfReady()
        }
        schedulePoll()
    }

    /** Stops polling (the session is gone). */
    fun stop() {
        polling = false
        swap.onDropped = null
        handler.removeCallbacksAndMessages(token)
    }

    private fun onRangeDropped() {
        if (!alive()) return gone()
        pendingRebuild = true
        rebuildIfReady()
        schedulePoll()
    }

    private fun gone() {
        stop()
        onGone()
    }

    private fun rebuildIfReady() {
        if (!pendingRebuild || !ready()) return
        val snap = snapshot.get()
        if (RenderedRangeSwap.isSourceFrame(snap)) return
        pendingRebuild = false
        rebuilds++
        backend.rebuild(snap.plan) { r ->
            r.exceptionOrNull()?.let {
                val code = EngineErrors.from(it).code
                if (code != EngineErrorCode.cancelled) Log.w(EngineContext.TAG, "rendered ranges: rebuild failed ($code)")
            }
        }
    }

    private fun schedulePoll() {
        if (polling) return
        polling = true
        post()
    }

    private fun post() {
        handler.postAtTime({ poll() }, token, SystemClock.uptimeMillis() + POLL_MS)
    }

    private fun poll() {
        if (!polling) return
        if (!alive()) return gone()
        // A drop posts onRangeDropped (the rebuild); the poll only keeps the swap current.
        swap.refresh()
        rebuildIfReady()
        if (swap.isEmpty && !pendingRebuild) {
            polling = false
            return
        }
        post()
    }

    companion object {
        /**
         * Poll period while ranges exist. Playback checks validity per frame, so the poll only keeps
         * the swap current while paused and retries waiting rebuilds; 2 wake-ups a second at most.
         */
        const val POLL_MS = 500L
    }
}
