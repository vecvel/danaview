// OWNER: AND-19
//
// PrecomposePlanner on the JVM (BUILD_PLAN AND-19 "JVM tests for the planner (slot split, disk
// estimate)"): the greedy bottom-up split under maxVisualSequences and codec instances − 2, the
// intermediate counted as one always-active slot, non-media lanes kept in order, forced progress
// when nothing fits, agreement with AND-11's routing rule, intermediate settings (all-intra, 4×),
// the padded duration, the disk estimate and the progress weights.

package com.vecvel.danaview.editor.engine.precompose

import com.vecvel.danaview.editor.engine.export.DecoderBudget
import com.vecvel.danaview.editor.engine.export.EncoderSettings
import com.vecvel.danaview.editor.engine.export.ExportVideoCodec
import com.vecvel.danaview.editor.engine.export.MultiPassRouting
import com.vecvel.danaview.editor.engine.export.precompose.IntermediateColor
import com.vecvel.danaview.editor.engine.export.precompose.MediaSpan
import com.vecvel.danaview.editor.engine.export.precompose.PlannerLane
import com.vecvel.danaview.editor.engine.export.precompose.PrecomposePlan
import com.vecvel.danaview.editor.engine.export.precompose.PrecomposePlanner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

class PrecomposePlannerTest {
    private val exportSettings = EncoderSettings(ExportVideoCodec.H264, 1280, 720, 30, 5_000_000, 192_000, 2000)

    private fun split(plan: com.vecvel.danaview.editor.engine.plan.RenderPlan, budget: DecoderBudget): PrecomposePlan =
        PrecomposePlanner.plan(PrecomposePlanner.lanes(PrecomposePlans.map(plan)), budget)

    private fun ranges(p: PrecomposePlan): List<Pair<Int, Int>> = p.passes.map { it.from to it.to }

    /** Every lane is drawn by exactly one pass, bottom-up and in order; each pass but the first reads the previous one. */
    private fun assertCovers(p: PrecomposePlan) {
        var next = 0
        for ((i, pass) in p.passes.withIndex()) {
            assertEquals("pass ${pass.number} starts where the previous ended", next, pass.from)
            assertTrue("pass ${pass.number} takes lanes", pass.to > pass.from)
            assertEquals(i + 1, pass.number)
            assertEquals(i > 0, pass.readsIntermediate)
            next = pass.to
        }
        assertEquals(next, p.finalFrom)
    }

    @Test
    fun sixOverlappingSlotsUnderTwoVisualSequencesTakeFivePasses() {
        val p = split(PrecomposePlans.overlapping(6), DecoderBudget(maxVisualSequences = 2, maxDecoderInstances = 0))
        assertEquals(listOf(0 to 2, 2 to 3, 3 to 4, 4 to 5), ranges(p))
        assertEquals(5, p.finalFrom)
        assertEquals(6, p.laneCount)
        assertEquals(4, p.intermediateCount)
        assertEquals(5, p.totalPasses)
        assertEquals(0, p.overBudgetPasses)
        assertEquals(listOf(2, 2, 2, 2), p.passes.map { it.load.slots })
        assertEquals(MultiPassRouting.Load(2, 2), p.finalLoad)
        assertCovers(p)
    }

    @Test
    fun threeVisualSequencesTakeThreePasses() {
        val p = split(PrecomposePlans.overlapping(6), DecoderBudget(3, 0))
        assertEquals(listOf(0 to 3, 3 to 5), ranges(p))
        assertEquals(5, p.finalFrom)
        assertEquals(MultiPassRouting.Load(2, 2), p.finalLoad)
        assertCovers(p)
    }

    @Test
    fun theDecoderInstanceLimitSplitsByPeakOverlap() {
        // 16 instances → 14 decoders: fits; 6 instances → 4 decoders for 6 overlapping layers.
        assertEquals(0, split(PrecomposePlans.overlapping(6), DecoderBudget(10, 16)).intermediateCount)
        val p = split(PrecomposePlans.overlapping(6), DecoderBudget(10, 6))
        assertEquals(listOf(0 to 4), ranges(p))
        assertEquals(MultiPassRouting.Load(slots = 4, peakDecoders = 4), p.passes[0].load)
        assertEquals(MultiPassRouting.Load(slots = 3, peakDecoders = 3), p.finalLoad)
        assertCovers(p)
    }

    @Test
    fun sparseSlotsCountOneDecoderAtATime() {
        // Six slots whose layers never overlap in time: peak 1, so only the slot count matters.
        val sparse = PrecomposePlans.plan(List(6) { i -> PrecomposePlans.Slot(listOf(i * 10L to i * 10L + 10)) })
        val lanes = PrecomposePlanner.lanes(PrecomposePlans.map(sparse))
        assertEquals(MultiPassRouting.Load(6, 1), PrecomposePlanner.load(lanes, 0, 6, readsIntermediate = false))
        assertEquals(MultiPassRouting.Load(7, 2), PrecomposePlanner.load(lanes, 0, 6, readsIntermediate = true))
        assertEquals(0, PrecomposePlanner.plan(lanes, DecoderBudget(6, 3)).intermediateCount)
        val p = PrecomposePlanner.plan(lanes, DecoderBudget(4, 0))
        assertEquals(listOf(0 to 4), ranges(p))
        assertEquals(MultiPassRouting.Load(3, 2), p.finalLoad)
    }

    @Test
    fun nonMediaLanesStayInOrderAndRideWithTheSlotsBelowTheCut() {
        // A solid below slot 0 and an image between slot 1 (z 20) and slot 2 (z 30).
        val plan = PrecomposePlans.overlapping(
            4,
            extra = listOf(PrecomposePlans.solid("it_solid#v", 5, 0, 60), PrecomposePlans.image("it_logo#v", 25, 0, 60)),
        )
        val lanes = PrecomposePlanner.lanes(PrecomposePlans.map(plan))
        assertEquals(listOf(false, true, true, false, true, true), lanes.map { it.isSlot })
        val p = PrecomposePlanner.plan(lanes, DecoderBudget(2, 0))
        assertEquals(listOf(0 to 3, 3 to 5), ranges(p))
        assertEquals(5, p.finalFrom)
        assertCovers(p)
    }

    @Test
    fun aBudgetOfOneStillTerminatesWithForcedSteps() {
        val p = split(PrecomposePlans.overlapping(3), DecoderBudget(1, 0))
        assertEquals(listOf(0 to 1, 1 to 2, 2 to 3), ranges(p))
        assertEquals(listOf(false, true, true), p.passes.map { it.overBudget })
        assertEquals(2, p.overBudgetPasses)
        assertEquals(3, p.finalFrom)
        assertFalse(p.finalOverBudget)
        assertCovers(p)
        // A zero budget is treated as one slot.
        assertEquals(ranges(p), ranges(split(PrecomposePlans.overlapping(3), DecoderBudget(0, 0))))
    }

    @Test
    fun aStackThatFitsNeedsNoIntermediate() {
        val p = split(PrecomposePlans.overlapping(2), DecoderBudget(2, 0))
        assertEquals(0, p.intermediateCount)
        assertEquals(1, p.totalPasses)
        assertEquals(0, p.finalFrom)
        assertEquals(MultiPassRouting.Load(2, 2), p.finalLoad)
    }

    @Test
    fun theSplitAgreesWithTheCoordinatorsRoutingAndEveryPassFitsOnRandomPlans() {
        val rnd = Random(19)
        repeat(300) { round ->
            val slots = 1 + rnd.nextInt(8)
            val frames = 90L
            val plan = PrecomposePlans.plan(
                List(slots) {
                    val ranges = ArrayList<Pair<Long, Long>>()
                    var k = rnd.nextInt(20).toLong()
                    while (k < frames - 2) {
                        val len = 1L + rnd.nextInt(30)
                        val end = minOf(frames, k + len)
                        ranges += k to end
                        k = end + rnd.nextInt(15)
                    }
                    if (ranges.isEmpty()) ranges += 0L to frames
                    PrecomposePlans.Slot(ranges)
                },
                frames = frames,
            )
            val budget = DecoderBudget(1 + rnd.nextInt(4), if (rnd.nextBoolean()) 0 else 3 + rnd.nextInt(6))
            val lanes = PrecomposePlanner.lanes(PrecomposePlans.map(plan))
            val whole = PrecomposePlanner.load(lanes, 0, lanes.size, false)
            assertEquals("round $round load", MultiPassRouting.load(plan), whole)
            val p = PrecomposePlanner.plan(lanes, budget)
            assertEquals("round $round routing", MultiPassRouting.needsMultiPass(whole, budget) && budget.maxVisualSequences >= 1, p.intermediateCount > 0)
            assertCovers(p)
            for (pass in p.passes) {
                assertEquals(pass.overBudget, !PrecomposePlanner.fits(pass.load, budget))
                // Greedy: one more slot lane would not have fitted (or the pass was forced).
                val nextSlot = (pass.to until lanes.size).firstOrNull { lanes[it].isSlot }
                if (!pass.overBudget && nextSlot != null) {
                    assertFalse(PrecomposePlanner.fits(PrecomposePlanner.load(lanes, pass.from, nextSlot + 1, pass.readsIntermediate), budget))
                }
            }
            // Only the forced single-slot steps of a 1-slot or 1-decoder budget run over it.
            if (budget.maxVisualSequences >= 2 && budget.maxDecoders >= 2) assertEquals("round $round", 0, p.overBudgetPasses)
        }
    }

    @Test
    fun loadCountsTheIntermediateAsOneAlwaysActiveSlot() {
        val lanes = listOf(
            PlannerLane(true, listOf(MediaSpan(0, 100))),
            PlannerLane(false),
            PlannerLane(true, listOf(MediaSpan(50, 150), MediaSpan(150, 200))),
        )
        assertEquals(MultiPassRouting.Load(2, 2), PrecomposePlanner.load(lanes, 0, 3, false))
        assertEquals(MultiPassRouting.Load(1, 1), PrecomposePlanner.load(lanes, 1, 3, false))
        assertEquals(MultiPassRouting.Load(2, 2), PrecomposePlanner.load(lanes, 1, 3, true))
        assertEquals(MultiPassRouting.Load(1, 1), PrecomposePlanner.load(lanes, 1, 2, true))
        // Back-to-back layers [50, 150) and [150, 200) never overlap.
        assertEquals(MultiPassRouting.Load(1, 1), PrecomposePlanner.load(lanes, 2, 3, false))
    }

    @Test
    fun intermediatesAreAllIntraAtFourTimesTheExportBitrate() {
        val i = PrecomposePlanner.intermediateSettings(exportSettings)
        assertEquals(20_000_000, i.videoBitrate)
        assertEquals(0, i.keyframeIntervalMs)
        assertEquals(0f, i.iFrameIntervalSeconds)
        assertEquals(exportSettings.copy(videoBitrate = 20_000_000, keyframeIntervalMs = 0), i)
        assertEquals("intermediates are BT.601 (planner header)", IntermediateColor.BT601, PrecomposePlanner.Options().color)
        val gop = PrecomposePlanner.intermediateSettings(exportSettings, PrecomposePlanner.Options(bitrateFactor = 6, allIntra = false))
        assertEquals(30_000_000, gop.videoBitrate)
        assertEquals(2000, gop.keyframeIntervalMs)
        assertEquals(Int.MAX_VALUE, PrecomposePlanner.intermediateSettings(exportSettings.copy(videoBitrate = 1_000_000_000)).videoBitrate)
    }

    @Test
    fun thePaddedDurationIsOneGridFrameLonger() {
        assertEquals(2_033_334L, PrecomposePlanner.paddedDurationUs(PrecomposePlans.overlapping(2, frames = 60)))
        val p24 = PrecomposePlans.plan(listOf(PrecomposePlans.Slot(listOf(0L to 48L))), frames = 48, fps = 24)
        assertEquals(2_041_667L, PrecomposePlanner.paddedDurationUs(p24))
        val grid30at60 = PrecomposePlans.plan(listOf(PrecomposePlans.Slot(listOf(0L to 30L))), frames = 30, fps = 60, gridFps = 30)
        assertEquals(1_033_334L, PrecomposePlanner.paddedDurationUs(grid30at60))
    }

    @Test
    fun diskEstimateCountsTheIntermediatesAliveAtOnce() {
        val plan = PrecomposePlans.overlapping(6, frames = 60) // 2.000 s; padded 2.033334 s
        val oneIntermediate = 5_185_001L // 20 Mb/s · 2.033334 s / 8 · 1.02
        val output = 1_323_960L // (5 Mb/s + 192 kb/s) · 2 s / 8 · 1.02
        assertEquals(output, exportSettings.estimatedBytes(plan.durUs))

        val five = split(plan, DecoderBudget(2, 0))
        val d5 = PrecomposePlanner.diskEstimate(five, exportSettings, plan)
        assertEquals(oneIntermediate, d5.intermediateBytes)
        assertEquals(2 * oneIntermediate, d5.peakIntermediateBytes)
        assertEquals(output, d5.outputBytes)
        assertEquals(maxOf(2 * oneIntermediate, oneIntermediate + output), d5.peakBytes)
        assertEquals(d5.peakBytes - output, d5.extraBytes)

        val two = split(plan, DecoderBudget(10, 6))
        val d2 = PrecomposePlanner.diskEstimate(two, exportSettings, plan)
        assertEquals(1, two.intermediateCount)
        assertEquals(oneIntermediate, d2.peakIntermediateBytes)
        assertEquals(oneIntermediate + output, d2.peakBytes)

        val none = split(PrecomposePlans.overlapping(2), DecoderBudget(2, 0))
        val d0 = PrecomposePlanner.diskEstimate(none, exportSettings, plan)
        assertEquals(0L, d0.extraBytes)
        assertEquals(output, d0.peakBytes)

        // The output dominates when the export bitrate is high and only one intermediate is alive.
        val gop = PrecomposePlanner.Options(bitrateFactor = 1, allIntra = false)
        val d1 = PrecomposePlanner.diskEstimate(two, exportSettings, plan, gop)
        assertEquals(PrecomposePlanner.intermediateBytes(exportSettings, PrecomposePlanner.paddedDurationUs(plan)) + output, d1.peakBytes)
    }

    @Test
    fun progressWeightsCoverEveryPass() {
        val p = split(PrecomposePlans.overlapping(6), DecoderBudget(2, 0))
        val w = PrecomposePlanner.passWeights(p)
        assertEquals(5, w.size)
        assertTrue(w.all { it > 0 })
        // Pass 1 draws two lanes over the background; later passes one lane over the intermediate.
        assertEquals(3.0, w[0], 0.0)
        assertEquals(3.0, w[1], 0.0)
        assertEquals(3.5, w[4], 0.0)
        val single = PrecomposePlanner.passWeights(split(PrecomposePlans.overlapping(2), DecoderBudget(2, 0)))
        assertEquals(1, single.size)
    }
}
