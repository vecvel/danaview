// OWNER: AND-08
//
// The frame grid and the platform-time rule (ARCH §5, D-35), the Kotlin twin of core's
// `FrameRate` (packages/vwish_editor_core/lib/src/time/time.dart). Plans use
// `timeOfFrame(k) = ceil(k·1e6/fps)`; Media3 stamps frame k at `P(k) = round(k·1e6/fps)`; every
// platform time τ becomes a frame with `frameIndexNearest(τ) = round(τ·fps/1e6)` and is evaluated at
// `timeOfFrame(k)` of the output rate, never at τ. Products stay below 2.2·10^16 for projects ≤ 24 h.

package com.vecvel.vwish.editor.engine.plan

/** Integer frame-grid arithmetic of one integer rate (v1 rates: 24, 25, 30, 48, 50, 60). */
class FrameGrid(val fps: Int) {
    init {
        require(fps > 0) { "fps must be positive" }
    }

    /** Plan time of frame [k]: `ceil(k·1e6/fps)`. */
    fun timeOfFrame(k: Long): Long = ceilDiv(k * MICROS, fps.toLong())

    /** Frame containing plan time [t]: `floor(t·fps/1e6)`. */
    fun frameIndexOf(t: Long): Long = Math.floorDiv(t * fps, MICROS)

    /** Platform-time rule: `round(τ·fps/1e6)`, halves up (D-35). */
    fun frameIndexNearest(tau: Long): Long = Math.floorDiv(tau * fps + MICROS / 2, MICROS)

    /** Media3's presentation time of frame [k]: `P(k) = round(k·1e6/fps)` (ARCH §5 rule 3). */
    fun platformTimeOfFrame(k: Long): Long = Math.floorDiv(2 * k * MICROS + fps, 2L * fps)

    /** `floor(k·1e6/fps)` (the rational frame time rounded down). */
    fun floorTimeOfFrame(k: Long): Long = Math.floorDiv(k * MICROS, fps.toLong())

    /** Floor to the start of the frame containing [t]. */
    fun quantize(t: Long): Long = timeOfFrame(frameIndexOf(t))

    /** Whether [t] is a frame start of this grid. */
    fun isOnGrid(t: Long): Boolean = quantize(t) == t

    /** The plan time an output frame stamped with platform time [tau] is evaluated at (D-35). */
    fun frameTimeOf(tau: Long): Long = timeOfFrame(frameIndexNearest(tau))

    override fun equals(other: Any?): Boolean = other is FrameGrid && other.fps == fps

    override fun hashCode(): Int = fps

    override fun toString(): String = "FrameGrid($fps)"

    companion object {
        /** Microseconds per second. */
        const val MICROS: Long = 1_000_000L

        /** The v1 project and output rates (ARCH §11.2 Canvas). */
        val RATES: Set<Int> = setOf(24, 25, 30, 48, 50, 60)

        private val cache = RATES.associateWith { FrameGrid(it) }

        /** A (shared) grid of [fps]. */
        fun of(fps: Int): FrameGrid = cache[fps] ?: FrameGrid(fps)

        /** `ceil(a / b)` for b > 0. */
        fun ceilDiv(a: Long, b: Long): Long = -Math.floorDiv(-a, b)
    }
}
