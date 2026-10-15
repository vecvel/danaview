// OWNER: AND-16
//
// The rendered-range hook (owner decision 2026-10-11, D-43(e) point 4, ARCH D-45, §13.3
// "Over-budget layers and the render-preview cache"). AND-18's RenderedRangeSwap implements it; the
// default is [RenderedRangeHook.NONE] (no ranges). During PLAYBACK ONLY the contingency backend
// plays a rendered range from its file through one range deck pair in place of every slot of the
// range (pre-rolled like a standby deck), switching at the range's exact frame boundaries under the
// hold/miss rule (drop a frame, never show a wrong one). Paused frames, scrubs and exact seeks
// always use the normal decks.
//
// File contract (AND-18's renders): an H.264 file at the preview canvas size and the project fps on
// the frame grid whose frame j (j = k − first) carries pts P(j) = round(j·1e6/fps) and shows output
// frame k of the plan revision the range was rendered from. Threads: every method is called on
// danaview-gl (the backend's engine thread); keep them cheap and non-blocking. Never log the URI.

package com.vecvel.danaview.editor.engine.preview.fallback

/** Output frames [first, endExclusive) of the plan that play from [uri] during playback. */
data class RenderedRange(val first: Long, val endExclusive: Long, val uri: String) {
    init {
        require(first >= 0 && endExclusive > first) { "empty rendered range" }
    }

    /** Whether output frame [k] is in the range. */
    operator fun contains(k: Long): Boolean = k >= first && k < endExclusive
}

/** Supplies rendered ranges to the contingency backend's playback (file header). */
interface RenderedRangeHook {
    /**
     * The ranges valid for the plan revision [rev] (sorted, non-overlapping). Called when playback
     * starts and after each structural rebuild; an empty list plays everything live.
     */
    fun ranges(rev: Long): List<RenderedRange>

    /**
     * Playback crossed a range boundary at output frame [k]: [entered] is the range that frame
     * [k] plays from, or null when playback returns to the live decks (also called when a range
     * could not be used and playback stays live).
     */
    fun onBoundary(k: Long, entered: RenderedRange?)

    companion object {
        /** No rendered ranges (AND-16's default until AND-18 installs its swap). */
        val NONE: RenderedRangeHook = object : RenderedRangeHook {
            override fun ranges(rev: Long): List<RenderedRange> = emptyList()

            override fun onBoundary(k: Long, entered: RenderedRange?) = Unit
        }
    }
}
