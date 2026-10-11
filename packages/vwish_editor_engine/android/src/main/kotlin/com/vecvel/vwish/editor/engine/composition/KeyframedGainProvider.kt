// OWNER: AND-08
@file:OptIn(UnstableApi::class, ExperimentalApi::class)

// Sample-exact gain envelope of one audio segment (ARCH §11.6 Audio row, D-37) for Media3's
// `GainProcessor`: `gain(t)` is linear between the plan's `[tUs, g]` keys (0–2, i.e. up to
// +6.02 dB) and held outside them; output sample p at rate R sits at timeline time
// `t = timelineUsAtPositionZero + p·1e6/R` (exact rational instant, no ε). `isUnityUntil` reports
// the unity spans so GainProcessor copies them untouched. GainProcessor sees the item's samples
// after its speed change (the speed processor is a pre-processing stage), so positions advance in
// timeline time from the item's start: Transformer (Media3 1.11.1) flushes an item's processors
// with position 0 at the item start, whatever its place in the sequence or its clip start
// (measured by CompositionExportTest.gainProcessorPositionsAreItemRelative).

package com.vecvel.vwish.editor.engine.composition

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.audio.GainProcessor
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import com.vecvel.vwish.editor.engine.plan.Keyframes

/** Gain provider over timeline µs (file header). */
class KeyframedGainProvider(
    private val gain: Keyframes,
    /** Timeline time of sample position 0. */
    val timelineUsAtPositionZero: Long,
) : GainProcessor.GainProvider {
    init {
        require(!gain.isEmpty()) { "a gain envelope needs at least one key" }
    }

    /** Timeline µs of sample [samplePosition] at [sampleRate]. */
    fun timeOf(samplePosition: Long, sampleRate: Int): Double =
        timelineUsAtPositionZero + samplePosition.toDouble() * 1_000_000.0 / sampleRate

    /** The envelope at sample [samplePosition] in double precision. */
    fun gainAt(samplePosition: Long, sampleRate: Int): Double = gain.valueAt(timeOf(samplePosition, sampleRate))

    override fun getGainFactorAtSamplePosition(samplePosition: Long, sampleRate: Int): Float =
        gainAt(samplePosition, sampleRate).toFloat()

    override fun isUnityUntil(samplePosition: Long, sampleRate: Int): Long {
        val t = timeOf(samplePosition, sampleRate)
        if (gain.valueAt(t) != 1.0) return C.TIME_UNSET
        val n = gain.size
        // j = last key at or before t (-1 when t is before every key).
        var j = -1
        while (j + 1 < n && gain.timeAt(j + 1) <= t) j++
        var e: Int
        if (j < 0) {
            e = 0
        } else {
            val spanStartsUnity = gain.valueOf(j) == 1.0
            val spanEndsUnity = j == n - 1 || gain.valueOf(j + 1) == 1.0
            if (!(spanStartsUnity && spanEndsUnity)) return samplePosition + 1 // an isolated unity sample
            e = j
        }
        while (e + 1 < n && gain.valueOf(e + 1) == 1.0) e++
        if (e == n - 1) return C.TIME_END_OF_SOURCE
        // Unity through key e (inclusive): the first sample strictly after its time.
        val rel = gain.timeAt(e) - timelineUsAtPositionZero
        val q = Math.floorDiv(rel * sampleRate, 1_000_000L) + 1
        return maxOf(q, samplePosition + 1)
    }

    companion object {
        /**
         * Timeline time of GainProcessor's sample position 0 for an item that starts at
         * [itemStartUs] (composition time): Transformer counts each item's output samples from 0
         * at the item start (after its speed change). AND-16's ExoPlayer audio chain must check
         * its own origin before reusing this.
         */
        fun originForItem(itemStartUs: Long): Long = itemStartUs

        /** The provider of a segment that starts at composition time [itemStartUs]. */
        fun forItem(gain: Keyframes, itemStartUs: Long): KeyframedGainProvider =
            KeyframedGainProvider(gain, originForItem(itemStartUs))
    }
}
