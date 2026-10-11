// OWNER: AND-08
@file:OptIn(UnstableApi::class, ExperimentalApi::class)

// Piecewise-constant speed of one item from its plan map (ARCH §11.5, §13.3 "Items"), handed to
// `EditedMediaItem.Builder.setSpeed(SpeedParameters(provider, keepPitch))` (Transformer export) and
// to AND-16's slot decks. Media3 calls the provider with INPUT (source) time relative to the clip
// start and sizes the item as `floor(Σ segmentInputUs / speed)` (SpeedProviderUtil
// .getDurationAfterSpeedProviderApplied; EditedMediaItem.getPresentationDurationUs). [SpeedFit]
// chooses the last segment's source length and float speed so that this sum is EXACTLY the
// item's P(k)-anchored output duration (ARCH §5 rule 3, D-35): the clip end moves by at most a
// few µs × rate and the speed by a few float ulps, both invisible, and no boundary drifts.

package com.vecvel.vwish.editor.engine.composition

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import com.vecvel.vwish.editor.engine.plan.MapSegment

/**
 * Speed [speeds]`[i]` from input time [startsUs]`[i]` (µs after the clip start; `startsUs[0] == 0`,
 * strictly increasing) until the next start. Consecutive equal speeds are expected to be merged by
 * the caller ([SpeedFit] does).
 */
class SegmentSpeedProvider(startsUs: LongArray, speeds: FloatArray) : SpeedProvider {
    private val starts = startsUs.copyOf()
    private val values = speeds.copyOf()

    init {
        require(starts.isNotEmpty() && starts.size == values.size) { "one speed per segment" }
        require(starts[0] == 0L) { "the first segment starts at the clip start" }
        require((1 until starts.size).all { starts[it] > starts[it - 1] }) { "segment starts must increase" }
        require(values.all { it > 0f && it.isFinite() }) { "speeds must be positive" }
    }

    /** Number of segments. */
    val segmentCount: Int get() = starts.size

    /** Input start of segment [i] (µs after the clip start). */
    fun startOf(i: Int): Long = starts[i]

    /** Speed of segment [i]. */
    fun speedOf(i: Int): Float = values[i]

    override fun getSpeed(timeUs: Long): Float = values[indexAt(timeUs)]

    override fun getNextSpeedChangeTimeUs(timeUs: Long): Long {
        val i = indexAt(timeUs)
        return if (i + 1 < starts.size) starts[i + 1] else C.TIME_UNSET
    }

    private fun indexAt(timeUs: Long): Int {
        if (timeUs < starts[0]) return 0
        var lo = 0
        var hi = starts.size - 1
        while (lo < hi) {
            val mid = (lo + hi + 1) ushr 1
            if (starts[mid] <= timeUs) lo = mid else hi = mid - 1
        }
        return lo
    }

    /** Output duration of [inputDurationUs] µs of input, computed exactly as Media3 does. */
    fun outputDurationUs(inputDurationUs: Long): Long = mediaOutputDurationUs(this, inputDurationUs)

    companion object {
        /** Media3's `SpeedProviderUtil.getDurationAfterSpeedProviderApplied` (1.11.1), bit for bit. */
        fun mediaOutputDurationUs(provider: SpeedProvider, inputDurationUs: Long): Long {
            var t = 0L
            var out = 0.0
            while (t < inputDurationUs) {
                var next = provider.getNextSpeedChangeTimeUs(t)
                if (next == C.TIME_UNSET) next = Long.MAX_VALUE
                check(next > t)
                out += (minOf(next, inputDurationUs) - t).toDouble() / provider.getSpeed(t).toDouble()
                t = next
            }
            return Math.floor(out).toLong()
        }
    }
}

/**
 * The input (source) side of one item: its clip length and speed provider, or no provider for a
 * constant 1× item (exact: input length == output length).
 */
data class FittedSpeed(
    /** Clip length in source µs (`clipEnd − clipStart`). */
    val inputDurationUs: Long,
    /** The provider, or null at constant 1×. */
    val provider: SegmentSpeedProvider?,
    /** Plan rate of each segment (source µs per timeline µs), for diagnostics and the fps cap. */
    val maxRate: Double,
)

/** Fits an item's map to an exact output duration (file header). */
object SpeedFit {
    /** Largest clip-end adjustment tried, in source µs. */
    private const val MAX_END_ADJUST_US = 256

    /** Float ulps tried around the ideal speed. */
    private const val ULP_STEPS = 3

    /** Source length of the fitted tail segment of a long slow item. */
    private const val TAIL_US = 10_000L

    /**
     * Fits [map] (contiguous segments; their source spans and rates) to [outputDurationUs] µs of
     * output, using at most [maxInputUs] source µs (the clip must end inside the source:
     * `EditedMediaItem` rejects a clip end beyond `setDurationUs`). The clip starts at the first
     * segment's s0 (the caller shifts it to the rule frame). Segment boundaries keep the plan's
     * source offsets and rates; the last segment absorbs the difference between the plan duration
     * and the P(k)-anchored [outputDurationUs].
     */
    fun fit(map: List<MapSegment>, outputDurationUs: Long, maxInputUs: Long = Long.MAX_VALUE): FittedSpeed {
        require(map.isNotEmpty() && outputDurationUs > 0) { "an item needs a map and a positive duration" }
        val rates = map.map { it.rate }
        val maxRate = rates.max()
        // Merge consecutive segments of the same rate (a 1× split by a breakpoint stays exact).
        val starts = ArrayList<Long>()
        val speeds = ArrayList<Double>()
        val lengths = ArrayList<Long>()
        var offset = 0L
        for (s in map) {
            val len = s.s1 - s.s0
            if (speeds.isNotEmpty() && speeds.last() == s.rate) {
                lengths[lengths.size - 1] = lengths.last() + len
            } else {
                starts += offset
                speeds += s.rate
                lengths += len
            }
            offset += len
        }
        if (speeds.size == 1 && speeds[0] == 1.0 && outputDurationUs <= maxInputUs) {
            return FittedSpeed(outputDurationUs, null, maxRate)
        }

        val last = speeds.size - 1
        val floats = FloatArray(speeds.size) { speeds[it].toFloat() }
        var prefix = 0.0
        for (i in 0 until last) prefix += lengths[i].toDouble() / floats[i].toDouble()
        val target = outputDurationUs - prefix
        check(target > 0) { "the earlier segments already exceed the item duration" }
        val prefixInput = starts[last]
        val capLen = maxInputUs - prefixInput
        check(capLen > 0) { "the source ends before the item's last segment" }
        val base = minOf(Math.round(target * speeds[last]), capLen)

        fun exact(len: Long, f: Float): Boolean =
            f > 0f && f.isFinite() && Math.floor(prefix + len.toDouble() / f.toDouble()).toLong() == outputDurationUs

        val lens = adjustments().map { base + it }.filter { it in 1..capLen }.toList()
        val near = lens.take(3)

        fun fitted(len: Long): Float? {
            val ideal = (len.toDouble() / (target + 0.5)).toFloat()
            var up = ideal
            var down = ideal
            for (step in 0..ULP_STEPS) {
                if (exact(len, up)) return up
                if (step > 0 && exact(len, down)) return down
                up = Math.nextUp(up)
                down = Math.nextDown(down)
            }
            return null
        }

        // 1) The nominal float speed with the clip end moved by at most 1 µs.
        for (len in near) {
            if (exact(len, floats[last])) return done(starts, floats, prefixInput + len, maxRate)
        }
        // 2) The float speed fitted (a few ulps off the plan rate), clip end within 1 µs.
        for (len in near) {
            val f = fitted(len) ?: continue
            floats[last] = f
            return done(starts, floats, prefixInput + len, maxRate)
        }
        // 3) Long segments: float ulps are too coarse for 1 µs, so a short tail (at most 10 ms of
        // source) gets its own fitted speed; its ulps move the end by far less than 1 µs.
        for (len in near) {
            val tail = minOf(len / 2, TAIL_US)
            if (tail < 1) continue
            val mainLen = len - tail
            val mainOut = prefix + mainLen.toDouble() / floats[last].toDouble()
            val residual = outputDurationUs - mainOut
            if (residual <= 0) continue
            var f = (tail.toDouble() / (residual + 0.5)).toFloat()
            repeat(64) {
                val total = Math.floor(mainOut + tail.toDouble() / f.toDouble()).toLong()
                if (total == outputDurationUs) {
                    val tailStarts = starts + (prefixInput + mainLen)
                    val tailFloats = floats.copyOf(floats.size + 1).also { it[floats.size] = f }
                    return done(tailStarts, tailFloats, prefixInput + len, maxRate)
                }
                f = if (total < outputDurationUs) Math.nextDown(f) else Math.nextUp(f)
            }
        }
        // 4) Last resort: move the clip end further.
        for (len in lens) {
            val f = fitted(len) ?: continue
            floats[last] = f
            return done(starts, floats, prefixInput + len, maxRate)
        }
        error("no exact speed fit for an item of $outputDurationUs us")
    }

    private fun adjustments(): Sequence<Long> = sequence {
        yield(0L)
        for (a in 1..MAX_END_ADJUST_US) {
            yield(-a.toLong())
            yield(a.toLong())
        }
    }

    private fun done(starts: List<Long>, floats: FloatArray, inputDurationUs: Long, maxRate: Double): FittedSpeed {
        val provider = if (floats.size == 1 && floats[0] == 1f) null else SegmentSpeedProvider(starts.toLongArray(), floats)
        return FittedSpeed(inputDurationUs, provider, maxRate)
    }
}
