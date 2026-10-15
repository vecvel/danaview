// OWNER: AND-18
//
// RenderedRangeSwap: AND-18's implementation of AND-16's RenderedRangeHook (ARCH §13.3
// "Over-budget layers and the render-preview cache", D-45). It holds the rendered ranges of one
// preview session and tells the contingency backend which of them are still valid; the backend
// plays a valid range during PLAYBACK ONLY from its file through one range deck pair in place of
// every slot of the range, pre-rolled like a standby deck and switched at the range's exact frame
// boundaries under the hold/miss rule (AND-16 MultiPlayerEngine). Paused frames, scrubs and exact
// seeks always use the normal decks.
//
// Invalidation (ARCH §12.2 "Rendered ranges"): the swap remembers the session snapshot it last
// checked; [refresh] diffs it with the current one (RangeTouch: the Dart `patchTouchesRange` rule
// applied to the change, plus transient overrides) and drops every touched range until the next
// `setRenderedRanges` ([set]). A snapshot that shows a source frame (PreviewSession's import
// preview) is not a plan change and is skipped. [ranges] refreshes first, so a structural rebuild
// never reinstalls a touched range; RenderedRangeHandler polls [refresh] on danaview-preview and
// rebuilds the backend when a range was dropped, so a param patch (no structural rebuild) also
// falls back to live.
//
// Threads: [set] and [refresh] on danaview-preview, [ranges] on the backend's worker, [onBoundary]
// on danaview-gl; state is guarded by one lock and every method is cheap. Never logs URIs.

package com.vecvel.danaview.editor.engine.preview.render

import com.vecvel.danaview.editor.engine.plan.ParamSnapshot
import com.vecvel.danaview.editor.engine.preview.PreviewSession
import com.vecvel.danaview.editor.engine.preview.fallback.RenderedRange
import com.vecvel.danaview.editor.engine.preview.fallback.RenderedRangeHook
import java.util.concurrent.atomic.AtomicReference

/** The rendered ranges of one session as AND-16's hook (file header). */
class RenderedRangeSwap(private val snapshot: AtomicReference<ParamSnapshot>) : RenderedRangeHook {
    /** One rendered range: its frames and file ([range]) and its plan-time span. */
    class Entry(val range: RenderedRange, val startUs: Long, val endUs: Long, val hash: String)

    /** Counters for tests and QA logs. */
    data class Stats(
        /** Ranges entered by playback (onBoundary with a range). */
        val entered: Int = 0,
        /** Returns to the live decks (onBoundary with null). */
        val left: Int = 0,
        /** Ranges dropped because a change touched them. */
        val dropped: Int = 0,
        /** The output frame of the last boundary (-1: none). */
        val lastBoundary: Long = -1,
        /** The range playback is in now (by its first frame), or null. */
        val current: Long? = null,
    )

    private val lock = Any()
    private var entries: List<Entry> = emptyList()
    private var seen: ParamSnapshot? = null
    private var stats = Stats()

    /** Replaces the ranges with [next], valid for the snapshot [at] (setRenderedRanges). */
    fun set(next: List<Entry>, at: ParamSnapshot) = synchronized(lock) {
        entries = next.sortedBy { it.range.first }
        seen = if (isSourceFrame(at)) null else at
    }

    /** The valid ranges (tests). */
    val current: List<Entry> get() = synchronized(lock) { entries }

    /** Whether no range is valid. */
    val isEmpty: Boolean get() = synchronized(lock) { entries.isEmpty() }

    /** The counters. */
    fun stats(): Stats = synchronized(lock) { stats }

    /**
     * Checks the current snapshot against the last one checked and drops every range the change
     * touches. Returns whether a range was dropped.
     */
    fun refresh(): Boolean {
        val snap = snapshot.get()
        synchronized(lock) {
            if (isSourceFrame(snap)) return false
            val prev = seen
            if (prev == null) {
                seen = snap
                return false
            }
            if (prev === snap || entries.isEmpty()) {
                seen = snap
                return false
            }
            val planChanged = prev.plan !== snap.plan
            val keep = entries.filter { e ->
                !(planChanged && RangeTouch.changeTouches(prev.plan, snap.plan, e.startUs, e.endUs)) &&
                    !RangeTouch.transientTouches(snap, e.startUs, e.endUs)
            }
            seen = snap
            val dropped = entries.size - keep.size
            if (dropped == 0) return false
            entries = keep
            stats = stats.copy(dropped = stats.dropped + dropped)
            return true
        }
    }

    override fun ranges(rev: Long): List<RenderedRange> {
        refresh()
        return synchronized(lock) { entries.map { it.range } }
    }

    override fun onBoundary(k: Long, entered: RenderedRange?) {
        synchronized(lock) {
            stats = if (entered != null) {
                stats.copy(entered = stats.entered + 1, lastBoundary = k, current = entered.first)
            } else {
                stats.copy(left = stats.left + 1, lastBoundary = k, current = null)
            }
        }
    }

    companion object {
        /** Whether [snap] shows PreviewSession's source-frame plan instead of the timeline. */
        fun isSourceFrame(snap: ParamSnapshot): Boolean =
            snap.plan.layers.size == 1 && snap.plan.layers[0].id == PreviewSession.SOURCE_FRAME_LAYER
    }
}
