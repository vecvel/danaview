@file:OptIn(UnstableApi::class, ExperimentalApi::class)

package com.vecvel.danaview.spike.engine

import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlin.math.abs
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * V-N3 (does experimentalRedrawLastFrame re-run effects of a secondary sequence?) and V-N19
 * (setComposition → first frame at 2/4/6 sequences; PausedFrameRenderer prototype showing a
 * secondary-sequence effect change; transient round-trip latency). Uses the full-length topology
 * CompositionPlayer can play (PlayerTopologyTest).
 */
@RunWith(AndroidJUnit4::class)
class PausedEditTest {
    private val ctx = TestMedia.target
    private val mapper = SpikeCompositionMapper(ctx)
    /** Frame the paused tests pause at (the paused frame is the first one at or after it). */
    private val k0 = 45L

    private fun greyOf(img: ReaderImage, regions: List<ProbeRegion>, plan: SpikePlan, seq: Int): Float =
        Barcode.r(Scenarios.readImage(img, regions, plan.bgRgb()).getValue("s$seq").grey)

    private fun redraw(replayableCache: Boolean): JSONObject {
        val plan = Scenarios.fullLength(30, 3)
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val rec = EffectRecorder()
        val regions = Scenarios.gridRegions(3)
        val c = mapper.build(plan, store, Scenarios.videoClock(30, MapperOptions(recorder = rec, includeAudio = false)))
        // With the replayable cache, the redraw runs on Media3's playback thread and
        // MultipleInputVideoGraph.redraw() throws UnsupportedOperationException there, which would
        // kill the process: capture uncaught exceptions for the duration of this run.
        val uncaught = java.util.concurrent.atomic.AtomicReference<Throwable?>()
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { _, e -> uncaught.compareAndSet(null, e) }
        val h = PlayerHarness(ctx, plan.canvasW, plan.canvasH, replayableCache = replayableCache)
        try {
            h.readRows = Scenarios.rowsFor(regions)
            h.load(c)
            h.awaitReady()
            val t0 = System.nanoTime()
            // Multi-sequence seeks fail in Media3 1.11.1 (R1): play to frame k and pause instead.
            val paused = h.playUntilFrame(k0, plan.fps, 15_000) ?: error("frame $k0 never rendered")
            val before = h.imageOf(paused, t0) ?: error("no image")
            Thread.sleep(500)
            val greyBefore = greyOf(h.images.last(), regions, plan, 2)
            // Param edit on secondary sequence 2 (input 2), then ask Media3 to redraw.
            store.update(2) { it.copy(tint = floatArrayOf(0.25f, 0.25f, 0.25f)) }
            rec.clear()
            val imagesBefore = h.images.size
            val t1 = System.nanoTime()
            // Without the replayable cache: checkState(enableReplayableCache) on the caller's thread.
            val callError = try {
                h.run { h.player.experimentalRedrawLastFrame() }
                null
            } catch (e: IllegalStateException) {
                "IllegalStateException (redraw needs the replayable cache)"
            }
            Thread.sleep(2000)
            val playbackThreadError = uncaught.get()?.let { "${it.javaClass.simpleName} at ${it.stackTrace.firstOrNull()}" }
            val after = h.images.filter { it.wallNs >= t1 }
            val greyAfter = if (after.isEmpty()) greyBefore else greyOf(after.last(), regions, plan, 2)
            val seq2Calls = rec.of(2).size
            return JSONObject().put("replayableCache", replayableCache)
                .put("redrawError", callError ?: playbackThreadError ?: JSONObject.NULL)
                .put("newImages", h.images.size - imagesBefore)
                .put("effectCallsAfterRedraw", JSONObject().put("seq1", rec.of(1).size).put("seq2", seq2Calls).put("seq3", rec.of(3).size))
                .put("seq2GreyBefore", greyBefore).put("seq2GreyAfter", greyAfter)
                .put("pixelsChanged", abs(greyAfter - greyBefore) > 0.1f)
                .put("redrawRerunsSecondaryEffects", seq2Calls > 0)
                .put("beforeImageTs", before.timestampNs)
                .put("pausedK", GridTime.frameIndexNearest(paused.ptsUs, plan.fps))
        } finally {
            // After a playback-thread crash the release times out; the player is abandoned.
            if (uncaught.get() == null) h.close() else runCatching { h.close() }
            Thread.setDefaultUncaughtExceptionHandler(previous)
        }
    }

    @Test
    fun redrawLastFrame_secondarySequence_vn3() {
        val runs = JSONArray().put(redraw(false)).put(redraw(true))
        Results.write("VN03_redraw_last_frame", JSONObject().put("runs", runs))
        // Recorded, not required: D-36 never relies on redraw. The expected answer (ARCH): redraw
        // does not re-run a secondary sequence's effects; without the replayable cache it throws.
        val noCache = runs.getJSONObject(0)
        val cache = runs.getJSONObject(1)
        assertTrue(runs.toString(), !noCache.isNull("redrawError"))
        assertTrue("redraw re-ran secondary effects with the replayable cache: revisit D-36: $runs", !cache.getBoolean("pixelsChanged"))
    }

    // ------------------------------------------------------------ V-N19 setComposition latency

    private fun shifted(plan: SpikePlan, rep: Int): SpikePlan =
        plan.copy(layers = plan.layers.map { if (it.seq == 1) it.copy(srcStartUs = it.srcStartUs + (rep + 1) * 100_000L) else it })

    @Test
    fun setCompositionLatency_vn19() {
        val runs = JSONArray()
        for (n in listOf(2, 4, 6)) {
            val plan = Scenarios.fullLength(30, n, seconds = 3)
            val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
            val options = Scenarios.videoClock(30, MapperOptions(includeAudio = false))
            val paused = ArrayList<Double>()
            val playing = ArrayList<Double>()
            var openMs = 0.0
            var pausedK = -1L
            var error: String? = null
            try {
                PlayerHarness(ctx, plan.canvasW, plan.canvasH, dropLateInput = true).use { h ->
                    val t00 = System.nanoTime()
                    h.load(mapper.build(plan, store, options))
                    h.awaitReady()
                    h.awaitRendered(t00, 10_000) { true } ?: error("no first frame")
                    openMs = (System.nanoTime() - t00) / 1e6
                    // Multi-sequence seeks fail in Media3 1.11.1 (R1): play to frame 15 and pause.
                    val p = h.playUntilFrame(15, plan.fps, 10_000) ?: error("frame 15 never rendered")
                    pausedK = GridTime.frameIndexNearest(p.ptsUs, plan.fps)
                    val posMs = GridTimingTest.seekMs(pausedK, plan.fps)
                    // Paused structural edit: setComposition(c, position) → first frame at the playhead.
                    repeat(3) { rep ->
                        val c = mapper.build(shifted(plan, rep), store, options)
                        val t0 = System.nanoTime()
                        h.run { h.player.setComposition(c, posMs) }
                        val f = h.awaitRendered(t0, 10_000) { GridTime.frameIndexNearest(it.ptsUs, plan.fps) == pausedK }
                        paused += if (f == null) -1.0 else (f.wallNs - t0) / 1e6
                    }
                    // Structural edit during playback → playing again (first new frame after the rebuild).
                    repeat(3) { rep ->
                        h.run { h.player.play() }
                        Thread.sleep(500)
                        val pos = h.positionMs()
                        val c = mapper.build(shifted(plan, rep + 3), store, options)
                        val t0 = System.nanoTime()
                        h.run {
                            h.player.setComposition(c, pos)
                            h.player.play()
                        }
                        val f = h.awaitRendered(t0, 10_000) { true }
                        playing += if (f == null) -1.0 else (f.wallNs - t0) / 1e6
                        h.run { h.player.pause() }
                    }
                }
            } catch (t: Throwable) {
                error = generateSequence(t) { it.cause }.take(4).joinToString(" <- ") { "${it.javaClass.simpleName}: ${it.message}" }
            }
            runs.put(
                JSONObject().put("sequences", n).put("openToFirstFrameMs", openMs).put("pausedK", pausedK)
                    .put("error", error ?: JSONObject.NULL)
                    .put("pausedSetCompositionToFrameMs", JSONArray(paused)).put("playingSetCompositionToFrameMs", JSONArray(playing)),
            )
        }
        Results.write("VN19_set_composition_latency", JSONObject().put("device", android.os.Build.MODEL).put("runs", runs))
        // The R1 finding: with MultipleInputVideoGraph a paused setComposition(c, position) never
        // renders the frame at the playhead (and the player errors on a later release). If every
        // rebuild renders, CompositionPlayer may be a go again: rerun AND-01.
        for (i in 0 until runs.length()) {
            val r = runs.getJSONObject(i)
            val paused = r.getJSONArray("pausedSetCompositionToFrameMs")
            val allRendered = paused.length() == 3 && (0 until 3).all { paused.getDouble(it) > 0 } && r.isNull("error")
            assertTrue("setComposition now renders at ${r.getInt("sequences")} sequences: R1 may be a go, rerun AND-01: $r", !allRendered)
        }
    }

    // ------------------------------------------------------------ V-N19 PausedFrameRenderer

    @Test
    fun pausedFrameRenderer_secondaryEffectChange_vn19() {
        val plan = Scenarios.fullLength(30, 3)
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val regions = Scenarios.gridRegions(3)
        val times = TestMedia.videoSampleTimesUs("barcode_30.mp4")
        val seqs = listOf(1, 2, 3)
        val c = mapper.build(plan, store, Scenarios.videoClock(30, MapperOptions(includeAudio = false, epsilon = EpsilonMode.SNAP_TO_RULE_FRAME)))
        val json = JSONObject()
        PlayerHarness(ctx, plan.canvasW, plan.canvasH).use { h ->
            h.readRows = Scenarios.rowsFor(regions)
            h.load(c)
            h.awaitReady()
            // 1. Player frame at k (reference): played to k and paused (multi-sequence seeks fail, R1).
            var t0 = System.nanoTime()
            val pausedFrame = h.playUntilFrame(k0, plan.fps, 15_000) ?: error("frame $k0 never rendered")
            val k = GridTime.frameIndexNearest(pausedFrame.ptsUs, plan.fps)
            json.put("pausedK", k)
            val playerImg = h.imageOf(pausedFrame, t0) ?: error("no player image")
            val playerRead = Scenarios.readImage(playerImg, regions, plan.bgRgb())
            assertTrue(Scenarios.checkFrame(plan, k, playerRead, times, seqs).joinToString(), Scenarios.checkFrame(plan, k, playerRead, times, seqs).isEmpty())

            // 2. Hand the surface to the paused renderer (D-36: player surface detached).
            val detachT = System.nanoTime()
            h.detachSurface()
            PausedFrameRendererProto(ctx, plan, store).use { pfr ->
                pfr.attach(h.reader.surface)
                val handoffMs = (System.nanoTime() - detachT) / 1e6
                val prefetch = pfr.prefetch(k)
                t0 = System.nanoTime()
                val glMs = pfr.render(k)
                val first = h.awaitImage(t0, 3000) ?: error("paused renderer produced no image")
                val pfrRead = Scenarios.readImage(first, regions, plan.bgRgb())
                val mm = Scenarios.checkFrame(plan, k, pfrRead, times, seqs)
                val greyDiff = seqs.maxOf { abs(Barcode.r(pfrRead.getValue("s$it").grey) - Barcode.r(playerRead.getValue("s$it").grey)) }
                json.put("handoffMs", handoffMs).put("prefetch", JSONObject().put("layers", prefetch.layers).put("wallMs", prefetch.wallMs).put("framePtsMs", JSONObject(prefetch.framePtsMs as Map<*, *>)))
                    .put("firstRenderGlMs", glMs).put("firstFrameMismatches", JSONArray(mm)).put("greyDiffVsPlayer", greyDiff.toDouble())
                assertTrue("paused frame differs from the rule: $mm", mm.isEmpty())
                assertTrue("paused frame grey differs from player by $greyDiff", greyDiff <= 0.04f)

                // 3. Transients on secondary sequence 2: param change → image on the surface.
                val trips = ArrayList<Double>()
                val gl = ArrayList<Double>()
                var lastTint = 1f
                for (i in 0 until 20) {
                    lastTint = if (i % 2 == 0) 0.3f + 0.02f * i else 1f - 0.01f * i
                    val tint = lastTint
                    t0 = System.nanoTime()
                    store.update(2) { it.copy(tint = floatArrayOf(tint, tint, tint)) }
                    gl += pfr.render(k)
                    val img = h.awaitImage(t0, 3000) ?: error("no image for transient $i")
                    trips += (img.wallNs - t0) / 1e6
                    val read = Scenarios.readImage(img, regions, plan.bgRgb())
                    val g2 = Barcode.r(read.getValue("s2").grey)
                    val g1 = Barcode.r(read.getValue("s1").grey)
                    assertTrue("seq2 grey $g2 for tint $tint", abs(g2 - 128f / 255f * tint) <= 0.05f)
                    assertTrue("seq1 unchanged $g1", abs(g1 - 128f / 255f) <= 0.05f)
                }
                json.put("transientRoundTripMs", Results.stats(trips)).put("transientGlMs", Results.stats(gl))

                // 4. Paused structural edit: seq 3 switches to another source time (one EXACT extraction).
                val newPlan = plan.copy(layers = plan.layers.map { if (it.seq == 3) it.copy(srcStartUs = it.srcStartUs + 2_000_000) else it })
                t0 = System.nanoTime()
                val pfr2Ms: Double
                PausedFrameRendererProto(ctx, newPlan, store).use { pfr2 ->
                    pfr.detach()
                    pfr2.attach(h.reader.surface)
                    pfr2.prefetch(k)
                    pfr2.render(k)
                    val img = h.awaitImage(t0, 5000) ?: error("no image after structural edit")
                    pfr2Ms = (img.wallNs - t0) / 1e6
                    val read = Scenarios.readImage(img, regions, newPlan.bgRgb())
                    val mm2 = Scenarios.checkFrame(newPlan, k, read, times, listOf(3))
                    json.put("structuralEditToFrameMs", pfr2Ms).put("structuralMismatches", JSONArray(mm2))
                    assertTrue("structural edit frame: $mm2", mm2.isEmpty())
                    pfr2.detach()
                }
            }
            // 5. Reattach the player and play on a few frames: its effects read the same store, so
            //    seq 2 keeps the last tint.
            t0 = System.nanoTime()
            h.attachSurface()
            val resumed = h.playUntilFrame(k + 3, plan.fps, 10_000) ?: error("no player frame after reattach")
            val back = h.imageOf(resumed, t0) ?: error("no player image after reattach")
            val g2 = Barcode.r(Scenarios.readImage(back, regions, plan.bgRgb()).getValue("s2").grey)
            json.put("reattachMs", (back.wallNs - t0) / 1e6).put("playerSeq2GreyAfterReattach", g2.toDouble())
        }
        Results.write("VN19_paused_frame_renderer", json)
    }
}
