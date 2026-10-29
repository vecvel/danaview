// OWNER: AND-16
//
// The owner-signed degradations and plug-in points of AND-16 (BUILD_PLAN AND-16 amended criteria,
// D-43(e), D-45), each checked frame by frame through the counters' barcodes:
// - layers over the live budget play as paused-exact stills during playback only, and every layer
//   is exact when paused, scrubbing or after an exact seek;
// - an exact seek while playing shows the nearest decoded frame first and acks only the exact frame;
// - under injected load frames are dropped (reported) and none is late or wrong;
// - the rendered-range hook (test double) is called at the range boundaries and the range plays
//   from its file during playback only;
// - a rotated source plays upright; audio lanes play and the frame clock follows them;
// - with the emulator's hardware decoders (they drop leading B-frames after a seek) no wrong frame
//   is ever shown and exact seeks stay exact.
// Emulator numbers, logged under AND16.

package com.vecvel.danaview.editor.engine.fallback

import android.util.Log
import com.vecvel.danaview.editor.engine.plan.AudioSeg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.Keyframes
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTransform
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import com.vecvel.danaview.editor.engine.preview.fallback.ContingencyPreviewBackend
import com.vecvel.danaview.editor.engine.preview.fallback.RenderedRange
import com.vecvel.danaview.editor.engine.preview.fallback.RenderedRangeHook
import com.vecvel.danaview.editor.engine.preview.fallback.SourceFrameIndex
import com.vecvel.danaview.editor.engine.harness.PerfGate
import java.util.concurrent.CopyOnWriteArrayList
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ContingencyFeaturesTest {
    private val q2 = FallbackPlans.QUADRANTS.take(2)

    /** Slot 0 in the top-left quadrant, slot 1 in the top-right, both over the whole plan. */
    private fun twoLayers(fps: Int = 24, frames: Long = 96): RenderPlan = FallbackPlans.plan(
        fps, frames,
        listOf(
            FallbackPlans.quadLayer("A#v", 0, 0, 0, frames, 10, fps),
            FallbackPlans.quadLayer("B#v", 1, 1, 0, frames, 100, fps),
        ),
    )

    private fun expectedQ(plan: RenderPlan, q: Int, k: Long, pts: LongArray): Int? = FallbackPlans.expectedIn(plan, q, k, pts)

    @Test
    fun overBudgetLayersPlayAsStillsDuringPlaybackOnly() {
        val plan = twoLayers()
        BackendHarness("and16_overbudget", plan, q2, ContingencyPreviewBackend.Config(liveBudget = 1)).use { h ->
            val pts = FallbackPlans.pts(h.engine.ctx, 24)
            // Paused: both layers exact (the over-budget one through an exact still).
            for (k in listOf(10L, 41L, 77L)) {
                assertTrue("seek $k", h.seekExact(k) >= 0)
                val f = h.sink.awaitK(k)
                assertEquals("live layer at $k", expectedQ(plan, 0, k, pts), f.readings["s0"])
                assertEquals("over-budget layer exact when paused at $k", expectedQ(plan, 1, k, pts), f.readings["s1"])
            }
            assertTrue(h.seekExact(20) >= 0)
            h.sink.awaitK(20)
            Thread.sleep(100)
            h.sink.clear()
            // Playback: the live layer shows its rule frames, the over-budget one a paused-exact still.
            h.play(20)
            Thread.sleep(2_500)
            h.pause()
            Thread.sleep(150)
            val frames = h.sink.frames.toList()
            assertTrue("frames played: ${frames.size}", frames.size >= 5)
            for (f in frames) assertEquals("live layer at ${f.k}", expectedQ(plan, 0, f.k, pts), f.readings["s0"])
            val stills = frames.map { it.readings["s1"] }.toSet()
            assertEquals("one still for the over-budget layer: $stills", 1, stills.size)
            val still = stills.single()
            assertNotNull(still)
            // The still is the exact frame of that layer at the frame playback started from.
            assertEquals("paused-exact still of the play-start frame", expectedQ(plan, 1, 20, pts), still)
            // Scrub then exact seek: exact again.
            h.sink.clear()
            h.seekAsync(50, exact = false)
            h.seekAsync(55, exact = false)
            assertTrue(h.seekExact(60) >= 0)
            val f = h.sink.awaitK(60)
            assertEquals(expectedQ(plan, 1, 60, pts), f.readings["s1"])
            assertEquals(expectedQ(plan, 0, 60, pts), f.readings["s0"])
            val stats = h.stats()
            Log.i(AND16_TAG, "over-budget stills (emulator, live budget 1 of 2): ${frames.size} frames played, stills fetched ${stats.stillsFetched}, decks ${stats.deckCount}")
            assertEquals("only the live slot has decks", 2, stats.deckCount)
        }
    }

    @Test
    fun exactSeekWhilePlayingShowsTheNearestFrameFirstThenTheExactOne() {
        val plan = twoLayers()
        BackendHarness("and16_nearest", plan, q2, ContingencyPreviewBackend.Config(liveBudget = 6)).use { h ->
            val pts = FallbackPlans.pts(h.engine.ctx, 24)
            assertTrue(h.seekExact(0, 30_000) >= 0)
            val paused = ArrayList<Double>()
            for (k in listOf(70L, 13L, 52L, 31L)) paused += h.seekExact(k)
            val playing = ArrayList<Double>()
            var nearestBefore = 0
            for ((i, k) in listOf(70L, 13L, 52L, 31L).withIndex()) {
                h.play(if (i % 2 == 0) 5 else 40)
                Thread.sleep(600)
                h.sink.clear()
                val n0 = h.stats().nearestShown
                val ms = h.seekExact(k)
                assertTrue("seek $k while playing", ms >= 0)
                playing += ms
                // The exact frame arrives after any nearest-first frame (both carry P(k)).
                val want0 = expectedQ(plan, 0, k, pts)
                val want1 = expectedQ(plan, 1, k, pts)
                val deadlineK = System.currentTimeMillis() + 5_000
                while (System.currentTimeMillis() < deadlineK && h.sink.frames.none { it.k == k && it.readings["s0"] == want0 }) Thread.sleep(2)
                val atK = h.sink.frames.filter { it.k == k }
                val exactAt = atK.indexOfFirst { it.readings["s0"] == want0 && it.readings["s1"] == want1 }
                assertTrue("acked frame $k is exact: ${atK.map { it.readings }}", exactAt >= 0)
                // The nearest-first frame (when shown) is presented before the exact one and never acked.
                if (h.stats().nearestShown > n0) nearestBefore++
                // Playback continues after the exact frame.
                val deadline = System.currentTimeMillis() + 5_000
                while (System.currentTimeMillis() < deadline && h.sink.frames.none { it.k > k }) Thread.sleep(5)
                assertTrue("playback resumed after the seek to $k", h.sink.frames.any { it.k > k })
                h.pause()
            }
            val p50Paused = Timings(paused).p(0.5)
            val p50Playing = Timings(playing).p(0.5)
            Log.i(AND16_TAG, "exact seek paused ${Timings(paused)} vs while playing ${Timings(playing)} (nearest frame shown first in $nearestBefore/4; +%.0f%% at p50; emulator)".format((p50Playing / p50Paused - 1) * 100))
            assertTrue("the nearest decoded frame was shown first", nearestBefore >= 1)
        }
    }

    @Test
    fun injectedLoadDropsFramesButNeverShowsALateOrWrongOne() {
        val plan = twoLayers()
        val config = ContingencyPreviewBackend.Config(liveBudget = 6)
        BackendHarness("and16_load", plan, q2, config).use { h ->
            val pts = FallbackPlans.pts(h.engine.ctx, 24)
            assertTrue(h.seekExact(0, 30_000) >= 0)
            h.sink.awaitK(0)
            Thread.sleep(100)
            h.sink.clear()
            h.host.dropped.clear()
            config.injectedCompositeDelayMs = 70
            val ended = h.playToEnd(0, 30_000)
            config.injectedCompositeDelayMs = 0
            Thread.sleep(150)
            val frames = h.sink.frames.toList()
            val wrong = frames.filter { it.readings["s0"] != expectedQ(plan, 0, it.k, pts) || it.readings["s1"] != expectedQ(plan, 1, it.k, pts) }
            val late = frames.zipWithNext().count { (a, b) -> b.k <= a.k }
            Log.i(AND16_TAG, "injected 70 ms/frame at 24 fps (emulator): presented ${frames.size}/96, dropped ${h.host.dropped.size}, wrong ${wrong.size}, out of order $late")
            assertTrue(ended)
            assertTrue("frames were dropped under load", h.host.dropped.size >= 20)
            assertEquals("no wrong frame: ${wrong.take(3).map { "${it.k}:${it.readings}" }}", 0, wrong.size)
            assertEquals("no late frame", 0, late)
            assertTrue("dropped and presented frames are disjoint", frames.none { it.k in h.host.dropped })
        }
    }

    @Test
    fun renderedRangeHookIsCalledAtBoundariesAndThePlaybackUsesTheRangeFile() {
        val fps = 24
        val frames = 96L
        val main = FallbackPlans.mainLayer(fps, frames, offset = 10)
        val plan = FallbackPlans.plan(fps, frames, listOf(main))
        val calls = CopyOnWriteArrayList<Pair<Long, RenderedRange?>>()
        val rangeUri = FallbackPlans.counterAsset(fps).uri
        val hook = object : RenderedRangeHook {
            override fun ranges(rev: Long): List<RenderedRange> = listOf(RenderedRange(24, 48, rangeUri))
            override fun onBoundary(k: Long, entered: RenderedRange?) {
                calls += k to entered
            }
        }
        val full = listOf(Region("full", 0, 0, 640, 360))
        BackendHarness("and16_range", plan, full, ContingencyPreviewBackend.Config(liveBudget = 6, rangeHook = hook)).use { h ->
            val pts = FallbackPlans.pts(h.engine.ctx, fps)
            // Paused exact seek inside the range keeps the normal decks (live composition).
            assertTrue(h.seekExact(30, 30_000) >= 0)
            assertEquals(FallbackPlans.expected(plan, main, 30, pts), h.sink.awaitK(30).readings["full"])
            Thread.sleep(100)
            h.sink.clear()
            assertTrue(h.playToEnd(0, 30_000))
            Thread.sleep(150)
            val shown = h.sink.frames.toList()
            val inRange = shown.filter { it.k in 24 until 48 }
            val outside = shown.filter { it.k !in 24 until 48 }
            val rangeWrong = inRange.filter { it.readings["full"] != (it.k - 24).toInt() }
            val liveWrong = outside.filter { it.readings["full"] != FallbackPlans.expected(plan, main, it.k, pts) }
            Log.i(AND16_TAG, "rendered range [24, 48) (emulator): ${inRange.size} range frames, ${outside.size} live frames, hook calls ${calls.map { "${it.first}:${it.second != null}" }}")
            val minInRange = PerfGate.atLeast(5, 1)
            assertTrue("range frames shown (${inRange.size}, need $minInRange, ${PerfGate.mode})", inRange.size >= minInRange)
            assertEquals("range frames come from the range file", emptyList<SinkFrame>(), rangeWrong)
            assertEquals(emptyList<SinkFrame>(), liveWrong)
            assertTrue("hook entered the range", calls.any { it.second != null && it.first in 24 until 48 })
            assertTrue("hook left the range", calls.any { it.second == null && it.first >= 48 })
            val enter = calls.indexOfFirst { it.second != null }
            val leave = calls.indexOfLast { it.second == null && it.first >= 48 }
            assertTrue("enter before leave", enter in 0 until leave)
            assertTrue(h.stats().rangeFrames >= inRange.size)
        }
    }

    @Test
    fun rotatedSourcePlaysUpright() {
        val fps = 30
        val frames = 60L
        val g = FrameGrid.of(fps)
        val t1 = g.timeOfFrame(frames)
        val asset = PlanAsset(PlanAssetKind.VIDEO, FallbackPlans.uri("rotated_90.mov"), fp = "fp-rot", w = 1280, h = 720, rot = 90)
        // Display size 720×1280 contained in 640×360: 202.5×360, centred.
        val layer = PlanLayer(
            id = "rot#v", z = 0, seq = 0, t0 = 0, t1 = t1, kind = PlanLayerKind.MEDIA, asset = "rot",
            map = listOf(MapSegment(0, t1, 0, t1)), base = PlanSize(202.5, 360.0), xf = PlanTransform(cx = 320.0, cy = 180.0),
        )
        val plan = FallbackPlans.plan(fps, frames, listOf(layer), assets = mapOf("rot" to asset))
        val region = listOf(Region("rot", 219, 0, 202, 360))
        BackendHarness("and16_rot", plan, region, ContingencyPreviewBackend.Config(liveBudget = 6)).use { h ->
            val pts = SourceFrameIndex(h.engine.ctx.appContext).frameTimes(asset.uri)
            for (k in listOf(15L, 44L)) {
                assertTrue(h.seekExact(k, 30_000) >= 0)
                assertEquals("upright barcode at $k", FallbackPlans.expected(plan, layer, k, pts), h.sink.awaitK(k).readings["rot"])
            }
        }
    }

    @Test
    fun audioLanesPlayAndTheFrameClockFollowsThem() {
        val fps = 24
        val frames = 72L
        val g = FrameGrid.of(fps)
        val main = FallbackPlans.mainLayer(fps, frames, offset = 10)
        val tone = PlanAsset(PlanAssetKind.AUDIO, FallbackPlans.uri("tone_440hz.wav"), fp = "fp-tone")
        val t1 = g.timeOfFrame(frames)
        val seg = AudioSeg(
            id = "a1", asset = "tone", t0 = 0, t1 = t1, map = listOf(MapSegment(0, t1, 0, t1)),
            gain = Keyframes.of(0L to 0.5, t1 to 1.5),
        )
        val plan = FallbackPlans.plan(fps, frames, listOf(main), assets = mapOf("counter" to FallbackPlans.counterAsset(fps), "tone" to tone)).copy(audio = listOf(seg))
        val full = listOf(Region("full", 0, 0, 640, 360))
        BackendHarness("and16_audio", plan, full, ContingencyPreviewBackend.Config(liveBudget = 6)).use { h ->
            val pts = FallbackPlans.pts(h.engine.ctx, fps)
            assertTrue(h.seekExact(0, 30_000) >= 0)
            h.sink.awaitK(0)
            Thread.sleep(100)
            h.sink.clear()
            assertTrue(h.playToEnd(0, 30_000))
            Thread.sleep(150)
            val shown = h.sink.frames.toList()
            val wrong = shown.filter { it.readings["full"] != FallbackPlans.expected(plan, main, it.k, pts) }
            val stats = h.stats()
            Log.i(AND16_TAG, "audio lane + video (emulator): ${shown.size}/$frames frames, audio clock reads ${stats.audioClockReads}, clock corrections to the audio master ${stats.audioFollows}, failures ${h.host.failures.size}")
            assertEquals(emptyList<SinkFrame>(), wrong)
            val minShown = PerfGate.atLeast(10, 2)
            assertTrue("frames shown (${shown.size}/$frames, need $minShown, ${PerfGate.mode})", shown.size >= minShown)
            assertTrue("no failure", h.host.failures.isEmpty())
            assertTrue("the audio deck played and the clock read it", stats.audioClockReads > 0)
        }
    }

    @Test
    fun hardwareDecodersNeverShowAWrongFrameAndExactSeeksStayExact() {
        val plan = FallbackPlans.gridCut(30)
        BackendHarness("and16_hw", plan, FallbackPlans.QUADRANTS.take(3), ContingencyPreviewBackend.Config(liveBudget = 6), hardwareDecoders = true).use { h ->
            val pts = FallbackPlans.pts(h.engine.ctx, 30)
            // B-frame positions of the 1080p30 counter (k ≡ 1 mod 3 in the first GOPs) and others.
            val ks = listOf(7L, 10L, 31L, 34L, 60L, 61L, 64L, 92L, 100L)
            for (k in ks) {
                assertTrue("seek $k", h.seekExact(k, 30_000) >= 0)
                val f = h.sink.awaitK(k)
                for (q in 0..2) assertEquals("k=$k s$q", FallbackPlans.expectedIn(plan, q, k, pts), f.readings["s$q"])
            }
            Thread.sleep(100)
            h.sink.clear()
            assertTrue(h.playToEnd(0, 30_000))
            Thread.sleep(150)
            val shown = h.sink.frames.toList()
            val wrong = shown.filter { f -> (0..2).any { q -> f.readings["s$q"] != FallbackPlans.expectedIn(plan, q, f.k, pts) } }
            val stats = h.stats()
            Log.i(AND16_TAG, "hardware decoders (emulator goldfish): exact ${ks.size}/${ks.size} (still fallbacks ${stats.exactStillFallbacks}), playback ${shown.size}/120 presented, wrong ${wrong.size}")
            assertEquals(emptyList<SinkFrame>(), wrong)
        }
    }
}
