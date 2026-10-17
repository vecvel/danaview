package com.vecvel.danaview.spike.engine

/**
 * Kotlin port of the frame grid of ARCH §5 / D-35 (mirrors packages/danaview_editor_core
 * lib/src/time/time.dart). Plans use `timeOfFrame(k) = ceil(k·1e6/fps)`; Media3's clock band
 * stamps frame k at `P(k) = round(k·1e6/fps)`; platform times map back with
 * `frameIndexNearest(τ) = round(τ·fps/1e6)`.
 */
object GridTime {
    fun floorDiv(a: Long, b: Long): Long {
        require(b > 0)
        val q = a / b
        return if (a % b != 0L && a < 0) q - 1 else q
    }

    fun ceilDiv(a: Long, b: Long): Long {
        require(b > 0)
        val q = a / b
        return if (a % b != 0L && a > 0) q + 1 else q
    }

    /** Plan time of frame [k]: `ceil(k·1e6/fps)`. */
    fun timeOfFrame(k: Long, fps: Int): Long = ceilDiv(k * 1_000_000L, fps.toLong())

    /** Frame containing plan time [t]: `floor(t·fps/1e6)`. */
    fun frameIndexOf(t: Long, fps: Int): Long = floorDiv(t * fps, 1_000_000L)

    /** Platform-time rule: `round(τ·fps/1e6)` (half up). */
    fun frameIndexNearest(tau: Long, fps: Int): Long = floorDiv(tau * fps + 500_000L, 1_000_000L)

    /** Media3 clock-band presentation time of frame [k]: `P(k) = round(k·1e6/fps)`. */
    fun platformTimeOfFrame(k: Long, fps: Int): Long = floorDiv(2 * k * 1_000_000L + fps, 2L * fps)

    /** `floor(k·1e6/fps)`. */
    fun floorTimeOfFrame(k: Long, fps: Int): Long = floorDiv(k * 1_000_000L, fps.toLong())

    /** P(k) in whole milliseconds, floored (seek target when Media3 shows the first frame ≥ position). */
    fun platformMsFloor(k: Long, fps: Int): Long = floorDiv(platformTimeOfFrame(k, fps), 1000L)

    /** P(k) in whole milliseconds, ceiled (seek target when Media3 shows the last frame ≤ position). */
    fun platformMsCeil(k: Long, fps: Int): Long = ceilDiv(platformTimeOfFrame(k, fps), 1000L)
}
