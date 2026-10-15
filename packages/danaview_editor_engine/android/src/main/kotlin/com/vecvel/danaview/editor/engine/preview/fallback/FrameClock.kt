// OWNER: AND-16
//
// The contingency engine's frame clock and hold/miss rule (ARCH §13.3 "Frame clock", AND-01.md §2).
// Pure: the engine feeds it Choreographer vsync times on danaview-gl.
//
// - The clock maps wall time to plan time at the project fps from an origin; the decks run
//   [leadUs] ahead of it (2 output frames), so each deck's ImageReader queue already holds the rule
//   frame of output frame k when k is composited. Wall time becomes an output frame with
//   frameIndexNearest and frames are evaluated at timeOfFrame(k) (D-35).
// - While a playing deck rebuffers the clock stops ([hold]: the origin moves with the wall clock),
//   for at most [MAX_STALL_MS] at a time.
// - The clock follows the audio master: [follow] snaps it to the audio plan time when they differ by
//   more than half a frame (ARCH §13.3 "Audio").
// - Hold/miss ([HoldMiss]): frame k is composited only when every active slot latched its rule
//   frame; otherwise it waits for the next vsync, or is dropped as soon as a deck already passed it.

package com.vecvel.danaview.editor.engine.preview.fallback

import com.vecvel.danaview.editor.engine.plan.FrameGrid

/** Wall clock → plan time at the project fps (file header). */
class FrameClock(val grid: FrameGrid, val leadFrames: Int = LEAD_FRAMES) {
    private var originNs = 0L
    private var startT = 0L

    /** Whether the clock runs. */
    var running = false
        private set

    /** How far the decks run ahead of the compositor (µs). */
    val leadUs: Long get() = leadFrames * 1_000_000L / grid.fps

    /** Half an output frame (µs). */
    val halfFrameUs: Long get() = 500_000L / grid.fps

    /** Starts at plan time [t0]; the compositor reaches [t0] one lead after [nowNs] (decks start now). */
    fun start(t0: Long, nowNs: Long) {
        startT = t0
        originNs = nowNs + leadUs * 1000L
        running = true
    }

    /** Stops the clock. */
    fun stop() {
        running = false
    }

    /** The compositor's plan time at [nowNs]. */
    fun planTime(nowNs: Long): Long = startT + Math.floorDiv(nowNs - originNs, 1000L)

    /** The decks' plan time at [nowNs] (compositor + lead). */
    fun deckTime(nowNs: Long): Long = planTime(nowNs) + leadUs

    /** The output frame on the clock at [nowNs] (frameIndexNearest of the plan time, D-35). */
    fun frameAt(nowNs: Long): Long = grid.frameIndexNearest(planTime(nowNs))

    /** Stops the clock's progress for [elapsedNs] (a rebuffering deck). */
    fun hold(elapsedNs: Long) {
        originNs += elapsedNs
    }

    /**
     * Follows the audio master: when [masterT] (audio plan time at [nowNs]) differs from the clock
     * by more than [toleranceUs], the clock jumps to it. Returns the correction applied (µs, 0 = none).
     */
    fun follow(masterT: Long, nowNs: Long, toleranceUs: Long = halfFrameUs): Long {
        val diff = masterT - planTime(nowNs)
        if (kotlin.math.abs(diff) <= toleranceUs) return 0L
        originNs -= diff * 1000L
        return diff
    }

    companion object {
        /** Decks lead the compositor by 2 output frames (AND-01). */
        const val LEAD_FRAMES = 2

        /** Longest single clock stop for a rebuffering deck. */
        const val MAX_STALL_MS = 2_000L
    }
}

/** The hold/miss rule (file header). */
object HoldMiss {
    /** What to do with output frame k. */
    enum class Verdict { DRAW, WAIT, MISS }

    /**
     * [missing]: some active slot has not latched its rule frame; [passed]: some deck is already past
     * its rule frame (it will never come).
     */
    fun verdict(missing: Boolean, passed: Boolean): Verdict = when {
        passed -> Verdict.MISS
        missing -> Verdict.WAIT
        else -> Verdict.DRAW
    }

    /** Output frames skipped between the last handled frame [lastK] and the newly handled [k]. */
    fun skipped(lastK: Long, k: Long): LongRange = if (k > lastK + 1) (lastK + 1) until k else LongRange.EMPTY
}
