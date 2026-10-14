// OWNER: AND-10
//
// Preview quality governor (ARCH §12.2 "Adaptive preview", §13.2/§13.3 "Quality", §13.4; D-43(e)
// point 2). The preview renders at canvas × {1, 1/2, 1/4}, the long side capped by the tier's
// `maxPreviewLongSide` (640 / 960 / 1280 / 1920). `PreviewQuality.auto` (the default) lets this
// governor step the level down full → half → quarter under load and back up after a sustained
// recovery; `full|half|quarter` pin it (UX-18's preview quality option) and load never changes a
// pinned level. Rules (the same thresholds as iOS's governor, ARCH §13.2):
//
// - load = output frames dropped during playback: more than 10% of the frames of the last 2 s
//   (at least [Policy.minFrames] of them) steps down one level, at most once per window;
// - recovery = 10 s of playback without such a window steps up one level (never above the
//   requested level);
// - thermal: PowerManager status SEVERE or worse caps every level at half, pinned ones included
//   (ARCH §13.3 "Thermal SEVERE forces <= half"); it lifts when the status drops below SEVERE.
//
// Each automatic change is returned as a [QualityGovernor.Change]; the session resizes the
// SurfaceProducer and reports it with `degraded(q)` (ARCH §12.2: "reporting each step").
// Pure logic with an injected clock, confined to the caller's thread (danaview-preview).

package com.vecvel.danaview.editor.engine.preview

import android.os.SystemClock
import com.vecvel.danaview.editor.engine.pigeon.PreviewQualityMsg
import kotlin.math.max
import kotlin.math.roundToInt

/** A preview render level: canvas ÷ [divisor] (ARCH §12.2). */
enum class QualityLevel(val divisor: Int, val msg: PreviewQualityMsg) {
    FULL(1, PreviewQualityMsg.FULL),
    HALF(2, PreviewQualityMsg.HALF),
    QUARTER(4, PreviewQualityMsg.QUARTER),
    ;

    /** The next coarser level (QUARTER stays). */
    fun down(): QualityLevel = if (this == QUARTER) QUARTER else entries[ordinal + 1]

    /** The next finer level (FULL stays). */
    fun up(): QualityLevel = if (this == FULL) FULL else entries[ordinal - 1]

    companion object {
        /** The pinned level of [q], or null for `auto`. */
        fun pinned(q: PreviewQualityMsg): QualityLevel? = when (q) {
            PreviewQualityMsg.AUTO -> null
            PreviewQualityMsg.FULL -> FULL
            PreviewQualityMsg.HALF -> HALF
            PreviewQualityMsg.QUARTER -> QUARTER
        }

        /** The coarser of [a] and [b]. */
        fun coarser(a: QualityLevel, b: QualityLevel): QualityLevel = if (a.ordinal >= b.ordinal) a else b
    }
}

/** Adaptive preview quality (file header). */
class QualityGovernor(
    requested: PreviewQualityMsg,
    /** Monotonic ms. */
    private val clock: () -> Long = { SystemClock.uptimeMillis() },
    private val policy: Policy = Policy(),
) {
    /** Thresholds (ARCH §13.2: > 10% missed over 2 s steps down, 10 s clean steps up). */
    data class Policy(
        val windowMs: Long = 2_000,
        val stepDownDropRatio: Double = 0.10,
        val minFrames: Int = 12,
        val recoverCleanMs: Long = 10_000,
    )

    /** Why the level changed. */
    enum class Reason { LOAD, RECOVERY, THERMAL, REQUEST }

    /** A change of the effective level. */
    data class Change(val from: QualityLevel, val to: QualityLevel, val reason: Reason)

    /** The requested quality (auto or a pinned level). */
    var requested: PreviewQualityMsg = requested
        private set

    // The automatic level (auto only); a pinned request ignores it.
    private var autoLevel = QualityLevel.FULL
    private var thermalCap: QualityLevel? = null

    // Playback frames of the current window: (time ms, dropped).
    private val window = ArrayDeque<Pair<Long, Boolean>>()
    private var dropsInWindow = 0
    private var lastTroubleMs = clock()
    private var lastChangeMs = Long.MIN_VALUE / 2

    /** The level the preview renders at now. */
    val level: QualityLevel
        get() {
            val base = QualityLevel.pinned(requested) ?: autoLevel
            return thermalCap?.let { QualityLevel.coarser(base, it) } ?: base
        }

    /** Whether the level is chosen automatically. */
    val isAuto: Boolean get() = requested == PreviewQualityMsg.AUTO

    /** Whether a thermal cap is active. */
    val thermalCapped: Boolean get() = thermalCap != null

    /** Sets the requested quality (setQuality); the automatic level restarts at full. */
    fun setRequested(q: PreviewQualityMsg): Change? = changeBy(Reason.REQUEST) {
        requested = q
        autoLevel = QualityLevel.FULL
        resetWindow()
    }

    /**
     * Applies a PowerManager thermal status (THERMAL_STATUS_*: 0 none … 3 severe … 6 shutdown).
     * SEVERE (3) or worse caps the level at half.
     */
    fun setThermalStatus(status: Int): Change? = changeBy(Reason.THERMAL) {
        thermalCap = if (status >= THERMAL_STATUS_SEVERE) QualityLevel.HALF else null
    }

    /** Playback (re)started: load and recovery are measured over playback only. */
    fun onPlaybackStarted() {
        resetWindow()
        lastTroubleMs = clock()
    }

    /** One output frame of playback was shown ([dropped] = false) or dropped. */
    fun onFrame(dropped: Boolean): Change? {
        val now = clock()
        window.addLast(now to dropped)
        if (dropped) dropsInWindow++
        while (window.isNotEmpty() && now - window.first().first > policy.windowMs) {
            if (window.removeFirst().second) dropsInWindow--
        }
        if (!isAuto) return null
        val n = window.size
        val troubled = n >= policy.minFrames && dropsInWindow > policy.stepDownDropRatio * n
        if (troubled) {
            lastTroubleMs = now
            if (autoLevel != QualityLevel.QUARTER && now - lastChangeMs >= policy.windowMs) {
                return changeBy(Reason.LOAD) {
                    autoLevel = autoLevel.down()
                    resetWindow()
                }
            }
            return null
        }
        if (autoLevel != QualityLevel.FULL && now - max(lastTroubleMs, lastChangeMs) >= policy.recoverCleanMs) {
            return changeBy(Reason.RECOVERY) {
                autoLevel = autoLevel.up()
                lastTroubleMs = now
            }
        }
        return null
    }

    /** Drop ratio of the current window (0 when empty; tests and logs). */
    val windowDropRatio: Double get() = if (window.isEmpty()) 0.0 else dropsInWindow.toDouble() / window.size

    private inline fun changeBy(reason: Reason, block: () -> Unit): Change? {
        val before = level
        block()
        val after = level
        if (after == before) return null
        lastChangeMs = clock()
        return Change(before, after, reason)
    }

    private fun resetWindow() {
        window.clear()
        dropsInWindow = 0
    }

    companion object {
        /** PowerManager.THERMAL_STATUS_SEVERE. */
        const val THERMAL_STATUS_SEVERE = 3

        /**
         * Render size of a [canvasW] × [canvasH] canvas at [level]: canvas ÷ divisor, the long side
         * capped at [maxLongSide] (aspect kept), both sides even and at least 2.
         */
        fun renderSize(canvasW: Int, canvasH: Int, level: QualityLevel, maxLongSide: Int): Pair<Int, Int> {
            require(canvasW > 0 && canvasH > 0) { "canvas size" }
            var w = canvasW.toDouble() / level.divisor
            var h = canvasH.toDouble() / level.divisor
            val long = max(w, h)
            if (maxLongSide > 0 && long > maxLongSide) {
                val k = maxLongSide / long
                w *= k
                h *= k
            }
            return even(w) to even(h)
        }

        private fun even(v: Double): Int = max(2, (v / 2.0).roundToInt() * 2)
    }
}
