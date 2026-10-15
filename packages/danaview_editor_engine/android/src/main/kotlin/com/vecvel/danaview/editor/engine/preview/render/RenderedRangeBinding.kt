// OWNER: AND-18
//
// RenderedRangeBinding: one session's RenderedRangeSwap bound to its AND-16 backend (ARCH D-45,
// §12.2 "Rendered ranges"). [apply] installs the swap as the backend's rendered-range hook (once),
// replaces the ranges and rebuilds the backend on the session's current plan, so the next playback
// (or the one running) picks them up. While ranges exist a poll on the session's lane
// (danaview-preview, every [POLL_MS]) runs the swap's invalidation; when a change touched a range
// the backend is rebuilt at once (the range deck goes and the live decks take over, hold/miss: a
// frame is dropped, never a stale one kept beyond the rebuild). A rebuild waits while [ready] says
// no (session closed, suspended for an export, or showing a source frame). The poll stops when
// [alive] turns false or no range is left. Used by RenderedRangeHandler (PreviewSession) and by the
// instrumented tests (AND-16's DirectHost). Never logs URIs.

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
) {
    /** The hook installed on the backend. */
    val swap = RenderedRangeSwap(snapshot)

    private val token = Any()
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
        handler.removeCallbacksAndMessages(token)
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
        if (!alive()) {
            stop()
            return
        }
        if (swap.refresh()) pendingRebuild = true
        rebuildIfReady()
        if (swap.isEmpty && !pendingRebuild) {
            polling = false
            return
        }
        post()
    }

    companion object {
        /** Invalidation poll period while ranges exist (about half a 60 fps frame). */
        const val POLL_MS = 8L
    }
}
