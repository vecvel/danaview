// OWNER: AND-16
//
// The pure parts of the contingency engine, run on the device runtime (AND-16 owns no JVM test
// directory): the slot plan (live budget per tier, still layers, unavailable sources, rule-frame
// clip starts, slot diff, audio lanes per stream), rule-frame lookups, the frame clock (lead,
// stall, audio follow, frameIndexNearest), hold/miss, the deck texture transforms (rotation and
// crop) and the envelope gain processor.

package com.vecvel.danaview.editor.engine.fallback

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import com.vecvel.danaview.editor.engine.pigeon.DeviceTierMsg
import com.vecvel.danaview.editor.engine.plan.AudioSeg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.Keyframes
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.preview.fallback.DeckTextures
import com.vecvel.danaview.editor.engine.preview.fallback.EnvelopeGainProcessor
import com.vecvel.danaview.editor.engine.preview.fallback.FrameClock
import com.vecvel.danaview.editor.engine.preview.fallback.HoldMiss
import com.vecvel.danaview.editor.engine.preview.fallback.RuleFrameMath
import com.vecvel.danaview.editor.engine.preview.fallback.RuleFrames
import com.vecvel.danaview.editor.engine.preview.fallback.SlotPlanner
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FallbackLogicTest {
    /** A counter at [fps] with frames at floor(n·1e6/fps); "bad" URIs throw. */
    private class FakeRules(private val fps: Int, private val frames: Int = 400) : RuleFrames {
        val table = LongArray(frames) { Math.floorDiv(it * 1_000_000L, fps.toLong()) }
        override fun rule(uri: String, sourceUs: Long): Long {
            if (uri.contains("bad")) throw IOException("offline")
            return RuleFrameMath.rule(table, sourceUs)
        }
        override fun frameTimes(uri: String): LongArray = table
        override fun durationUs(uri: String): Long? = if (uri.contains("bad")) throw IOException("offline") else frames * 1_000_000L / fps
    }

    @Test
    fun ruleFrameIsTheGreatestPtsWithinEpsilon() {
        val pts = longArrayOf(0, 41_666, 83_333, 125_000)
        assertEquals(0L, RuleFrameMath.rule(pts, 0))
        assertEquals(41_666L, RuleFrameMath.rule(pts, 41_667)) // P(1) at 24 fps
        assertEquals(41_666L, RuleFrameMath.rule(pts, 41_166)) // s + 500 µs reaches it
        assertEquals(0L, RuleFrameMath.rule(pts, 41_165))
        assertEquals(125_000L, RuleFrameMath.rule(pts, 9_000_000))
        assertEquals(0L, RuleFrameMath.rule(pts, -5_000))
        assertEquals(83_333L, RuleFrameMath.next(pts, 41_666))
        assertEquals(null, RuleFrameMath.next(pts, 125_000))
    }

    @Test
    fun liveBudgetFollowsTheTierAndTheDeviceCap() {
        assertEquals(2, SlotPlanner.liveBudget(DeviceTierMsg.MINIMAL, null))
        assertEquals(2, SlotPlanner.liveBudget(DeviceTierMsg.LOW, 3))
        assertEquals(4, SlotPlanner.liveBudget(DeviceTierMsg.MID, 4))
        assertEquals(6, SlotPlanner.liveBudget(DeviceTierMsg.HIGH, 6))
        assertEquals(3, SlotPlanner.liveBudget(DeviceTierMsg.HIGH, 3))
        assertEquals(1, SlotPlanner.liveBudget(DeviceTierMsg.MINIMAL, 1))
        assertEquals("an unknown cap (0) does not cap", 4, SlotPlanner.liveBudget(DeviceTierMsg.MID, 0))
    }

    private fun plan4(): RenderPlan {
        val layers = listOf(
            FallbackPlans.quadLayer("A#v", 0, 0, 0, 30, 10, 24),
            FallbackPlans.quadLayer("B#v", 0, 0, 30, 60, 100, 24),
            FallbackPlans.quadLayer("C#v", 1, 1, 0, 60, 20, 24),
            FallbackPlans.quadLayer("D#v", 2, 2, 10, 50, 30, 24),
            FallbackPlans.quadLayer("E#v", 3, 3, 0, 60, 40, 24),
        )
        val assets = mapOf("counter" to PlanAsset(PlanAssetKind.VIDEO, "file:///counter.mp4", fp = "c", w = 1280, h = 720))
        return FallbackPlans.plan(24, 60, layers, assets = assets)
    }

    @Test
    fun slotPlanKeepsTheLowestSlotsLiveAndTurnsTheRestIntoStills() {
        val rules = FakeRules(24)
        val p = plan4()
        val sp = SlotPlanner.plan(p, rules, useProxies = false, liveBudget = 2)
        assertEquals(listOf(0, 1, 2, 3), sp.slots.map { it.seq })
        assertEquals(listOf(true, true, false, false), sp.slots.map { it.live })
        assertEquals(setOf("D#v", "E#v"), sp.stillLayers)
        assertEquals(listOf("A#v", "B#v"), sp.slot(0)!!.items.map { it.layer!!.id })
        // Clip start snaps to the rule frame of the first source time (SNAP_TO_RULE_FRAME).
        val a = sp.slot(0)!!.items[0]
        assertEquals(RuleFrameMath.rule(rules.table, Math.floorDiv(10 * 1_000_000L, 24)), a.clipStartUs)
        assertTrue(a.clipEndUs > a.clipStartUs)
        val g = FrameGrid.of(24)
        assertEquals(0, sp.slot(0)!!.activeAt(g.timeOfFrame(29)))
        assertEquals(1, sp.slot(0)!!.activeAt(g.timeOfFrame(30)))
        assertEquals(-1, sp.slot(0)!!.activeAt(g.timeOfFrame(60)))
        assertEquals(1, sp.slot(0)!!.nextAfter(g.timeOfFrame(5)))
        // Deck positions: floor((rule − clipStart) / 1000) ms (V-N18).
        assertEquals(41L, a.positionMs(a.clipStartUs + 41_666))
        assertEquals(0L, a.positionMs(a.clipStartUs))
        // Full budget: every slot live.
        assertTrue(SlotPlanner.plan(p, rules, false, 6).stillLayers.isEmpty())
    }

    @Test
    fun holdAndUnreadableLayersNeverDecode() {
        val p0 = plan4()
        val held = p0.layers.map { if (it.id == "C#v") it.copy(hold = true) else it }
        val p = p0.copy(layers = held, assets = p0.assets + ("bad" to PlanAsset(PlanAssetKind.VIDEO, "file:///bad.mp4", fp = "b")))
            .let { pl -> pl.copy(layers = pl.layers.map { if (it.id == "B#v") it.copy(asset = "bad") else it }) }
        val sp = SlotPlanner.plan(p, FakeRules(24), false, 6)
        assertTrue("hold layer is a still", "C#v" in sp.stillLayers)
        assertEquals(setOf("B#v"), sp.unavailable)
        assertEquals(listOf("A#v"), sp.slot(0)!!.items.map { it.layer!!.id })
    }

    @Test
    fun slotDiffNamesOnlyTheChangedSlots() {
        val rules = FakeRules(24)
        val p = plan4()
        val a = SlotPlanner.plan(p, rules, false, 6)
        assertEquals(setOf(0, 1, 2, 3), SlotPlanner.changedSlots(null, a))
        // A param-only change (position) keeps every slot.
        val moved = p.copy(rev = 2, layers = p.layers.map { if (it.id == "C#v") it.copy(xf = it.xf.copy(cx = 10.0)) else it })
        assertEquals(emptySet<Int>(), SlotPlanner.changedSlots(a, SlotPlanner.plan(moved, rules, false, 6)))
        // A trim of D changes slot 2 only.
        val g = FrameGrid.of(24)
        val trimmed = p.copy(rev = 3, layers = p.layers.map { l ->
            if (l.id == "D#v") l.copy(t1 = g.timeOfFrame(40), map = listOf(l.map[0].let { MapSegment(it.t0, g.timeOfFrame(40), it.s0, it.s0 + g.timeOfFrame(40) - it.t0) })) else l
        })
        assertEquals(setOf(2), SlotPlanner.changedSlots(a, SlotPlanner.plan(trimmed, rules, false, 6)))
        // A budget change flips live slots.
        assertEquals(setOf(2, 3), SlotPlanner.changedSlots(a, SlotPlanner.plan(p, rules, false, 2)))
    }

    @Test
    fun audioLanesAreColouredPerStream() {
        val g = FrameGrid.of(24)
        fun seg(id: String, k0: Long, k1: Long, stream: Int = 0) = AudioSeg(
            id = id, asset = "tone", stream = stream, t0 = g.timeOfFrame(k0), t1 = g.timeOfFrame(k1),
            map = listOf(MapSegment(g.timeOfFrame(k0), g.timeOfFrame(k1), 0, g.timeOfFrame(k1) - g.timeOfFrame(k0))), gain = Keyframes.constant(1.0),
        )
        val p = plan4().copy(
            assets = plan4().assets + ("tone" to PlanAsset(PlanAssetKind.AUDIO, "file:///tone.wav", fp = "t")),
            audio = listOf(seg("a", 0, 30), seg("b", 10, 40), seg("c", 30, 60), seg("d", 0, 60, stream = 1)),
        )
        val lanes = SlotPlanner.audioLanes(p, null)
        assertEquals(3, lanes.size)
        assertEquals(listOf("a", "c"), lanes[0].items.map { it.seg.id })
        assertEquals(listOf("b"), lanes[1].items.map { it.seg.id })
        assertEquals(1, lanes[2].stream)
        // Source ↔ plan time on a 2× segment.
        val map = listOf(MapSegment(1_000_000, 2_000_000, 0, 2_000_000))
        assertEquals(1_000_000L, SlotPlanner.sourceAt(map, 1_500_000))
        assertEquals(1_500_000L, SlotPlanner.planTimeOf(map, 1_000_000))
        assertEquals(90, SlotPlanner.normalizeRotation(-270))
        assertEquals(270, SlotPlanner.normalizeRotation(-90))
    }

    @Test
    fun frameClockLeadsStallsAndFollowsTheAudioMaster() {
        val c = FrameClock(FrameGrid.of(30))
        assertEquals(66_666L, c.leadUs)
        c.start(1_000_000, 0)
        // The compositor reaches t0 one lead after start; the decks are at t0 now.
        assertEquals(1_000_000L - 66_666L, c.planTime(0))
        assertEquals(1_000_000L, c.deckTime(0))
        assertEquals(1_000_000L, c.planTime(66_666_000))
        // frameIndexNearest: half a frame early already names the frame (D-35).
        assertEquals(30L, c.frameAt(66_666_000))
        assertEquals(31L, c.frameAt(66_666_000 + 17_000_000))
        // A 100 ms stall holds the clock.
        val before = c.planTime(200_000_000)
        c.hold(100_000_000)
        assertEquals(before - 100_000, c.planTime(200_000_000))
        // Audio master: within half a frame no change, beyond it the clock jumps.
        val now = 300_000_000L
        assertEquals(0L, c.follow(c.planTime(now) + 10_000, now))
        assertEquals(40_000L, c.follow(c.planTime(now) + 40_000, now))
        assertEquals(HoldMiss.Verdict.DRAW, HoldMiss.verdict(missing = false, passed = false))
        assertEquals(HoldMiss.Verdict.WAIT, HoldMiss.verdict(missing = true, passed = false))
        assertEquals(HoldMiss.Verdict.MISS, HoldMiss.verdict(missing = true, passed = true))
        assertEquals(LongRange(5, 7), HoldMiss.skipped(4, 8))
        assertTrue(HoldMiss.skipped(4, 5).isEmpty())
    }

    @Test
    fun deckTexturesRotateAndCropIntoTheBuffer() {
        fun at(m: FloatArray, u: Float, v: Float) = DeckTextures.apply(m, u, v).let { floatArrayOf(it.first, it.second) }
        // 0°: identity inside the crop (1280×720 visible of a 1280×736 buffer).
        val m0 = DeckTextures.transform(1280, 736, 0, 0, 1280, 720, 0)
        assertArrayEquals(floatArrayOf(1f, 720f / 736f), at(m0, 1f, 1f), 1e-6f)
        // 90° (cw display): display top-left is the buffer's bottom-left; top-right its top-left.
        val m90 = DeckTextures.transform(1280, 720, 0, 0, 1280, 720, 90)
        assertArrayEquals(floatArrayOf(0f, 1f), at(m90, 0f, 0f), 1e-6f)
        assertArrayEquals(floatArrayOf(0f, 0f), at(m90, 1f, 0f), 1e-6f)
        assertArrayEquals(floatArrayOf(1f, 0f), at(m90, 1f, 1f), 1e-6f)
        val m180 = DeckTextures.transform(100, 100, 0, 0, 100, 100, 180)
        assertArrayEquals(floatArrayOf(1f, 1f), at(m180, 0f, 0f), 1e-6f)
        val m270 = DeckTextures.transform(100, 100, 0, 0, 100, 100, 270)
        assertArrayEquals(floatArrayOf(1f, 0f), at(m270, 0f, 0f), 1e-6f)
        val t = DeckTextures.texture(7, 1280, 720, 0, 0, 1280, 720, 90)
        assertEquals(720, t.width)
        assertEquals(1280, t.height)
    }

    @Test
    fun envelopeGainFollowsThePlanTimeOfEachSample() {
        val p = EnvelopeGainProcessor()
        // 1 kHz mono PCM16; gain 0 → 2 linearly over plan time 0..1 s; the segment starts at plan
        // time 0 with source 0 (1×).
        p.setSchedule(EnvelopeGainProcessor.Schedule(500_000, { it }, Keyframes.of(0L to 0.0, 1_000_000L to 2.0)))
        p.configure(AudioProcessor.AudioFormat(1000, 1, C.ENCODING_PCM_16BIT))
        p.flush(AudioProcessor.StreamMetadata.DEFAULT)
        val n = 64
        val input = ByteBuffer.allocateDirect(n * 2).order(ByteOrder.nativeOrder())
        repeat(n) { input.putShort(10_000) }
        input.flip()
        p.queueInput(input)
        val out = p.output.order(ByteOrder.nativeOrder())
        // Source 500 ms = plan 500 ms: gain 1.0.
        assertEquals(10_000, out.getShort(0).toInt())
        // Clamped at +6 dB: still a valid 16-bit sample.
        p.setSchedule(EnvelopeGainProcessor.Schedule(1_000_000, { it }, Keyframes.constant(2.0)))
        p.flush(AudioProcessor.StreamMetadata.DEFAULT)
        val loud = ByteBuffer.allocateDirect(4).order(ByteOrder.nativeOrder())
        loud.putShort(30_000).putShort(-30_000).flip()
        p.queueInput(loud)
        val o2 = p.output.order(ByteOrder.nativeOrder())
        assertEquals(Short.MAX_VALUE.toInt(), o2.getShort(0).toInt())
        assertEquals(Short.MIN_VALUE.toInt(), o2.getShort(2).toInt())
        assertFalse(p.isEnded)
    }
}
