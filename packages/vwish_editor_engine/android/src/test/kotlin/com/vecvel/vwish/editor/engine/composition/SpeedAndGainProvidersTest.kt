@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-08

// SegmentSpeedProvider and KeyframedGainProvider (ARCH §13.3 "Items", §11.6 Audio, D-35, D-37):
// - every fitted item integrates to its P(k)-anchored duration EXACTLY under Media3 1.11.1's own
//   SpeedProviderUtil (the AND-08 criterion is ±1 µs), for constant speeds 0.1…10, the owner's
//   preset speeds, speed ramps (multi-segment maps), long slow items and capped source ends;
// - the provider's speed segments follow the plan map in clip-relative source time;
// - the gain provider reports unity spans exactly (GainProcessor copies them).

package com.vecvel.vwish.editor.engine.composition

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.SpeedProviderUtil
import androidx.media3.common.util.UnstableApi
import com.vecvel.vwish.editor.engine.plan.FrameGrid
import com.vecvel.vwish.editor.engine.plan.Keyframes
import com.vecvel.vwish.editor.engine.plan.MapSegment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random
import kotlin.math.abs

class SpeedAndGainProvidersTest {
    /** Media3's own item duration for [fit]. */
    private fun media3Duration(fit: FittedSpeed): Long =
        fit.provider?.let { SpeedProviderUtil.getDurationAfterSpeedProviderApplied(it, fit.inputDurationUs) } ?: fit.inputDurationUs

    /** A one-segment map of [frames] grid frames from frame [k0] at [rate]. */
    private fun constantMap(grid: FrameGrid, k0: Long, frames: Long, s0: Long, rate: Double): List<MapSegment> {
        val t0 = grid.timeOfFrame(k0)
        val t1 = grid.timeOfFrame(k0 + frames)
        return listOf(MapSegment(t0, t1, s0, s0 + Math.round((t1 - t0) * rate)))
    }

    private fun anchored(grid: FrameGrid, k0: Long, k1: Long) = grid.platformTimeOfFrame(k1) - grid.platformTimeOfFrame(k0)

    @Test
    fun constantSpeedsIntegrateExactly() {
        val speeds = listOf(0.1, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0, 10.0, 0.3333, 1.7)
        var checked = 0
        for (fps in FrameGrid.RATES) {
            val g = FrameGrid.of(fps)
            for (rate in speeds) {
                for (k0 in listOf(0L, 1L, 2L, 31L, 1000L, 86401L)) {
                    for (frames in listOf(1L, 2L, 7L, 31L, 300L, 18001L)) {
                        val map = constantMap(g, k0, frames, 12_345L, rate)
                        val d = anchored(g, k0, k0 + frames)
                        val fit = SpeedFit.fit(map, d)
                        assertEquals("fps=$fps rate=$rate k0=$k0 n=$frames", d, media3Duration(fit))
                        assertEquals(d, fit.provider?.outputDurationUs(fit.inputDurationUs) ?: fit.inputDurationUs)
                        // The clip end moves by at most a few µs × rate.
                        val planned = map[0].s1 - map[0].s0
                        assertTrue("end moved ${fit.inputDurationUs - planned}", abs(fit.inputDurationUs - planned) <= 2 + 2 * rate)
                        if (rate == 1.0) assertNull("1x needs no speed provider", fit.provider)
                        checked++
                    }
                }
            }
        }
        assertTrue(checked >= 2800)
    }

    @Test
    fun speedRampsIntegrateExactlyAndKeepTheirBreakpoints() {
        val rnd = Random(84L)
        for (fps in FrameGrid.RATES) {
            val g = FrameGrid.of(fps)
            repeat(200) {
                val k0 = rnd.nextInt(100_000).toLong()
                var k = k0
                var s = rnd.nextInt(1_000_000).toLong()
                val map = ArrayList<MapSegment>()
                repeat(1 + rnd.nextInt(40)) {
                    val n = 1L + rnd.nextInt(30)
                    val rate = 0.1 + rnd.nextDouble() * 9.9
                    val t0 = g.timeOfFrame(k)
                    val t1 = g.timeOfFrame(k + n)
                    val s1 = s + maxOf(1L, Math.round((t1 - t0) * rate))
                    map += MapSegment(t0, t1, s, s1)
                    k += n
                    s = s1
                }
                val d = anchored(g, k0, k)
                val fit = SpeedFit.fit(map, d)
                assertEquals("fps=$fps ramp of ${map.size}", d, media3Duration(fit))
                val p = fit.provider ?: return@repeat
                // Breakpoints are the plan's source offsets from the clip start; speeds are its rates.
                var offset = 0L
                for (seg in map.dropLast(1)) {
                    assertEquals(seg.rate.toFloat(), p.getSpeed(offset), 0f)
                    offset += seg.s1 - seg.s0
                }
                assertEquals(C.TIME_UNSET, p.getNextSpeedChangeTimeUs(fit.inputDurationUs))
                assertTrue(abs(fit.inputDurationUs - (map.last().s1 - map.first().s0)) <= 300)
            }
        }
    }

    @Test
    fun longSlowItemsAndCappedSourcesIntegrateExactly() {
        val g = FrameGrid.of(30)
        // One hour at 0.1x and at 0.25x: float ulps alone are too coarse, the tail segment fits.
        for (rate in listOf(0.1, 0.25, 0.3, 0.75)) {
            val map = constantMap(g, 1, 108_000, 0, rate)
            val d = anchored(g, 1, 108_001)
            assertEquals("rate=$rate", d, media3Duration(SpeedFit.fit(map, d)))
        }
        // The source ends just before the planned clip end (rule-frame shift): the clip stays inside.
        val map = constantMap(g, 0, 90, 0, 1.0)
        val d = anchored(g, 0, 90)
        val fit = SpeedFit.fit(map, d, maxInputUs = map[0].s1 - 400)
        assertTrue(fit.inputDurationUs <= map[0].s1 - 400)
        assertEquals(d, media3Duration(fit))
    }

    @Test
    fun providerSegmentsAndLookups() {
        val p = SegmentSpeedProvider(longArrayOf(0, 1000, 5000), floatArrayOf(1f, 2f, 0.5f))
        assertEquals(1f, p.getSpeed(-5), 0f)
        assertEquals(1f, p.getSpeed(999), 0f)
        assertEquals(2f, p.getSpeed(1000), 0f)
        assertEquals(0.5f, p.getSpeed(9_000_000), 0f)
        assertEquals(1000L, p.getNextSpeedChangeTimeUs(0))
        assertEquals(5000L, p.getNextSpeedChangeTimeUs(1000))
        assertEquals(C.TIME_UNSET, p.getNextSpeedChangeTimeUs(5000))
        assertEquals(SpeedProviderUtil.getDurationAfterSpeedProviderApplied(p, 7000), p.outputDurationUs(7000))
    }

    @Test
    fun gainUnitySpans() {
        val rate = 48_000
        // Unity held before the first key, then a ramp to 2 from 1 s to 2 s, then a dip back to 1.
        val g = KeyframedGainProvider(Keyframes.of(500_000L to 1.0, 1_000_000L to 1.0, 2_000_000L to 2.0, 3_000_000L to 1.0), 0L)
        // Unity through t = 1 s (sample 48000 is exactly 1 s): the first non-unity sample is 48001.
        assertEquals(48_001L, g.isUnityUntil(0, rate))
        assertEquals(48_001L, g.isUnityUntil(48_000, rate))
        assertEquals(C.TIME_UNSET, g.isUnityUntil(48_001, rate))
        // Held at 1 after the last key: unity to the end of the source.
        assertEquals(C.TIME_END_OF_SOURCE, g.isUnityUntil(144_000, rate))
        // A constant unity envelope is inactive; a constant boost is not.
        assertEquals(C.TIME_END_OF_SOURCE, KeyframedGainProvider(Keyframes.constant(1.0), 0L).isUnityUntil(0, rate))
        assertEquals(C.TIME_UNSET, KeyframedGainProvider(Keyframes.constant(2.0), 0L).isUnityUntil(0, rate))
        assertEquals(2f, KeyframedGainProvider(Keyframes.constant(2.0), 0L).getGainFactorAtSamplePosition(12_345, rate), 0f)
        // An isolated unity sample inside a ramp (0.5 -> 1.5 crosses 1 at t = 1 s).
        val ramp = KeyframedGainProvider(Keyframes.of(0L to 0.5, 2_000_000L to 1.5), 0L)
        assertEquals(1.0, ramp.gainAt(48_000, rate), 0.0)
        assertEquals(48_001L, ramp.isUnityUntil(48_000, rate))
        // A non-zero origin shifts sample positions in timeline time.
        val shifted = KeyframedGainProvider(Keyframes.of(1_000_000L to 0.0, 2_000_000L to 2.0), 1_000_000L)
        assertEquals(1.0, shifted.gainAt(24_000, rate), 1e-12)
    }
}
