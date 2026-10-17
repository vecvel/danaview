@file:OptIn(UnstableApi::class, ExperimentalApi::class)

package com.vecvel.danaview.spike.engine

import android.graphics.PixelFormat
import android.hardware.HardwareBuffer
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.spike.engine.Scenarios.json
import java.util.Random
import kotlin.math.abs
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The AND-16 contingency engine prototype ([ContingencyEngineProto]) on the canonical grid-cut
 * composition that CompositionPlayer 1.11.1 cannot play through (PlayerTopologyTest): playback on
 * the frame clock with per-frame barcode checks, and exact seeks through the slot players.
 * Sizes AND-16 (AND-01.md "Contingency").
 */
@RunWith(AndroidJUnit4::class)
class ContingencyEngineTest {
    private val ctx = TestMedia.target
    private val seqs = listOf(1, 2, 3)

    /** Output surface standing in for the SurfaceProducer; images are consumed and dropped. */
    private class Sink(w: Int, h: Int) : AutoCloseable {
        val thread = HandlerThread("contingency-sink").apply { start() }
        val reader: ImageReader = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 3, HardwareBuffer.USAGE_GPU_COLOR_OUTPUT).apply {
            setOnImageAvailableListener({ it.acquireLatestImage()?.close() }, Handler(thread.looper))
        }
        override fun close() {
            reader.close()
            thread.quitSafely()
        }
    }

    /** Source-frame error of each mismatch: decoded barcode minus the rule frame (null = wrong layer/background). */
    private fun errors(plan: SpikePlan, frames: List<ProbeFrame>, times: LongArray): Map<String, Int> {
        val hist = HashMap<String, Int>()
        for (f in frames) {
            val k = GridTime.frameIndexNearest(f.ptsUs, plan.fps)
            for (seq in seqs) {
                val want = Scenarios.expected(plan, seq, k, times)
                val got = f.regions["s$seq"]?.reading
                val key = when {
                    want == null && got == Barcode.Background -> "gapOk"
                    want == null -> "gapShowsContent"
                    got is Barcode.Value -> (got.n - want).toString()
                    else -> "noContent"
                }
                hist.merge(key, 1, Int::plus)
            }
        }
        return hist
    }

    private fun playback(
        fps: Int,
        source: ContingencyEngineProto.FrameSource,
        standby: Boolean = true,
        leadFrames: Int = 2,
        hold: Boolean = true,
        rate: Double = 1.0,
        stall: Boolean = true,
    ): JSONObject {
        val plan = Scenarios.gridCut(fps)
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val times = TestMedia.videoSampleTimesUs("barcode_$fps.mp4")
        // Output frames on either side of every layer edge (cuts at k ≡ 1, 2 mod 3).
        val edges = plan.layers.flatMap { listOf(it.k0, it.k1) }.filter { it in 1 until plan.durFrames }.toSortedSet()
        val boundaryKs = edges.flatMap { listOf(it - 1, it) }.toSortedSet()
        Sink(plan.canvasW, plan.canvasH).use { sink ->
            ContingencyEngineProto(ctx, plan, store, Scenarios.regions(1, 2, 3), source, leadFrames = leadFrames, standby = standby, holdLateFrames = hold, stallOnRebuffer = stall).use { e ->
                e.attach(sink.reader.surface)
                val r = e.play(0, (plan.durUs / 1000 / rate).toLong() + 30_000, rate)
                val frames = e.frames.toList()
                val check = Scenarios.check(plan, frames, times, seqs)
                val hist = errors(plan, frames, times)
                val exactLayerFrames = hist["0"] ?: 0
                val layerFrames = hist.filterKeys { it != "gapOk" && it != "gapShowsContent" }.values.sum()
                val composedKs = frames.map { GridTime.frameIndexNearest(it.ptsUs, plan.fps) }.toSet()
                val edgesSeen = edges.count { (it - 1) in composedKs && it in composedKs }
                return JSONObject().put("frameSource", source.name).put("standbyDecks", standby).put("leadFrames", leadFrames).put("holdLateFrames", hold).put("fps", fps).put("clockRate", rate).put("stallOnRebuffer", stall).put("ended", r.ended).put("wallMs", r.wallMs)
                    .put("rebuffers", r.rebuffers).put("rebufferMs", r.rebufferMs)
                    .put("edges", edges.size).put("boundaryFrames", boundaryKs.size).put("boundaryFramesComposited", boundaryKs.count { it in composedKs })
                    .put("edgesWithBothSidesComposited", edgesSeen)
                    .put("compositionMs", plan.durUs / 1000).put("expectedFrames", plan.durFrames)
                    .put("composedFrames", r.composedFrames).put("skippedOutputFrames", r.skippedFrames).put("heldAttempts", r.heldAttempts).put("missedFrames", r.missedFrames)
                    .put("firstHoldReasons", Results.arr(e.holdReasons.toList()))
                    .put("composedRatio", r.composedFrames.toDouble() / plan.durFrames)
                    .put("compositeMs", Results.stats(r.compositeMs))
                    .put("sourceFrameErrorHistogram", JSONObject(hist as Map<*, *>))
                    .put("layerFramesExact", exactLayerFrames).put("layerFrames", layerFrames)
                    .put("slots", JSONArray(r.slots.map { JSONObject().put("seq", it.seq).put("seeks", it.seeks).put("prerolls", it.prerolls).put("staleImages", it.staleImages).put("driftCorrections", it.driftCorrections).put("latched", it.latched).put("behind", it.behind).put("ahead", it.ahead).put("recoveries", it.recoveries) }))
                    .put("barcode", check.json())
            }
        }
    }

    /**
     * The grid-cut case on the contingency path. The AND-16 configuration (IMAGE_READER decks, a
     * standby deck per slot, players 2 frames ahead, late output frames held instead of drawn
     * with a wrong slot frame) must show the rule frame of every layer on every composited frame
     * at 24, 30 and 60 fps (V-N18 playback); late frames are dropped, never shown wrong.
     *
     * Real time (`and16`): the drop and rebuffer rates depend on the shared emulator host
     * (recorded; the device budgets are QA-04's). Slow clock (`and16_slow_clock`, frame clock and
     * decks at 0.25×): the same engine with 4× the wall time per frame, so most frames — including
     * both sides of every cut — are composited and verified even on an overloaded host. The same
     * engine without the rebuffer stall or without holding, and ARCH's original contingency (one
     * deck per slot, no lead, no hold, no stall; with ImageReader or SurfaceTexture), run in real
     * time and are recorded for the report.
     */
    @Test
    fun gridCutPlayback_contingency() {
        val runs = JSONArray()
        for (fps in listOf(24, 30, 60)) runs.put(playback(fps, ContingencyEngineProto.FrameSource.IMAGE_READER).put("config", "and16"))
        for (fps in listOf(24, 30, 60)) runs.put(playback(fps, ContingencyEngineProto.FrameSource.IMAGE_READER, rate = SLOW_CLOCK).put("config", "and16_slow_clock"))
        runs.put(playback(30, ContingencyEngineProto.FrameSource.IMAGE_READER, stall = false).put("config", "and16_no_stall"))
        runs.put(playback(30, ContingencyEngineProto.FrameSource.IMAGE_READER, hold = false).put("config", "and16_no_hold"))
        runs.put(playback(30, ContingencyEngineProto.FrameSource.IMAGE_READER, standby = false, leadFrames = 0, hold = false, stall = false).put("config", "single_deck_no_lead"))
        runs.put(playback(30, ContingencyEngineProto.FrameSource.SURFACE_TEXTURE, standby = false, leadFrames = 0, hold = false, stall = false).put("config", "surface_texture"))
        Results.write("AND16_proto_playback", JSONObject().put("device", android.os.Build.MODEL).put("runs", runs))
        var verified = 0
        var edgesBothSides = 0
        var edges = 0
        for (i in 0 until runs.length()) {
            val r = runs.getJSONObject(i)
            // Plays through every secondary boundary to the end (the CompositionPlayer stall is gone).
            assertTrue(r.toString(), r.getBoolean("ended"))
            val hist = r.getJSONObject("sourceFrameErrorHistogram")
            // Gating follows the plan: a gap never shows content.
            assertEquals(r.toString(), 0, hist.optInt("gapShowsContent", 0))
            val config = r.getString("config")
            if (config.startsWith("and16") && config != "and16_no_hold") {
                // Held, never wrong: every composited frame shows every layer's rule frame.
                assertEquals("grid-cut playback: $r", 0, r.getJSONObject("barcode").getInt("mismatches"))
            }
            if (config == "and16_slow_clock") {
                verified += r.getInt("composedFrames")
                edgesBothSides += r.getInt("edgesWithBothSidesComposited")
                edges += r.getInt("edges")
            }
        }
        // Non-vacuous: the slow-clock runs verified most frames, and both sides of most cuts.
        val expected = listOf(24, 30, 60).sumOf { it * 4 }
        assertTrue("slow clock verified $verified of $expected frames: $runs", verified * 2 >= expected)
        assertTrue("slow clock verified both sides of $edgesBothSides of $edges cuts: $runs", edgesBothSides * 2 >= edges)
    }

    private companion object {
        /** Frame clock and deck speed of the slow-clock correctness pass. */
        const val SLOW_CLOCK = 0.25
    }

    /** V-N18 exact seek 200/200 on the grid-cut composition (contingency path). */
    @Test
    fun exactSeek_contingency() {
        val plan = Scenarios.gridCut(30)
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val times = TestMedia.videoSampleTimesUs("barcode_30.mp4")
        val rnd = Random(20261010)
        val latencies = ArrayList<Double>()
        val failures = ArrayList<String>()
        var ok = 0
        val n = 200
        Sink(plan.canvasW, plan.canvasH).use { sink ->
            ContingencyEngineProto(ctx, plan, store, Scenarios.regions(1, 2, 3)).use { e ->
                e.attach(sink.reader.surface)
                // Warm-up (players prepared and decoders up), not counted.
                check(e.seekExact(60, 30_000) >= 0) { "warm-up seek timed out" }
                repeat(n) { i ->
                    val k = rnd.nextInt(plan.durFrames.toInt()).toLong()
                    e.frames.clear()
                    val ms = e.seekExact(k, 10_000)
                    if (ms < 0) {
                        failures += "#$i k=$k timeout"
                        return@repeat
                    }
                    latencies += ms
                    val f = e.frames.lastOrNull()
                    val mm = if (f == null) listOf("k=$k no frame") else Scenarios.checkFrame(plan, k, f.regions, times, seqs)
                    if (mm.isEmpty()) ok++ else failures += mm
                }
            }
        }
        Results.write(
            "AND16_proto_exact_seek",
            JSONObject().put("seeks", n).put("correct", ok).put("latencyMs", Results.stats(latencies)).put("failures", Results.arr(failures.take(20))),
        )
        assertEquals(failures.joinToString("\n"), n, ok)
    }

    /**
     * V-N18 scrub on the contingency path: a drag over off-grid positions (47 ms steps, each
     * position → k = frameIndexNearest) as one exact seek per position, then exact seeks after the
     * drag. Every composited frame carries pts = P(k) (the frame clock is ours) and shows the rule
     * frames.
     */
    @Test
    fun scrubThenExactSeek_contingency() {
        val plan = Scenarios.gridCut(30)
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val times = TestMedia.videoSampleTimesUs("barcode_30.mp4")
        val latencies = ArrayList<Double>()
        val mismatches = ArrayList<String>()
        var offGrid = 0
        var scrubFrames = 0
        Sink(plan.canvasW, plan.canvasH).use { sink ->
            ContingencyEngineProto(ctx, plan, store, Scenarios.regions(1, 2, 3)).use { e ->
                e.attach(sink.reader.surface)
                // Warm-up (players prepared and decoders up), not part of the scrub.
                check(e.seekExact(60, 30_000) >= 0) { "warm-up seek timed out" }
                e.frames.clear()
                var posMs = 0L
                while (posMs < plan.durUs / 1000 - 100) {
                    val k = GridTime.frameIndexNearest(posMs * 1000, plan.fps)
                    val ms = e.seekExact(k, 10_000)
                    if (ms >= 0) latencies += ms else mismatches += "scrub k=$k timeout"
                    posMs += 47
                }
                for (k in listOf(38L, 64L, 7L)) if (e.seekExact(k, 10_000) < 0) mismatches += "post-scrub seek $k timeout"
                val frames = e.frames.toList()
                scrubFrames = frames.size
                for (f in frames) {
                    val k = GridTime.frameIndexNearest(f.ptsUs, plan.fps)
                    if (abs(f.ptsUs - GridTime.platformTimeOfFrame(k, plan.fps)) > 1000) offGrid++
                    mismatches += Scenarios.checkFrame(plan, k, f.regions, times, seqs)
                }
            }
        }
        Results.write(
            "VN18_scrub_contingency",
            JSONObject().put("frames", scrubFrames).put("ptsOffGridOver1ms", offGrid).put("seekLatencyMs", Results.stats(latencies))
                .put("mismatches", mismatches.size).put("firstMismatches", Results.arr(mismatches.take(12))),
        )
        assertTrue("no frames while scrubbing", scrubFrames > 0)
        assertEquals(0, offGrid)
        assertTrue(mismatches.joinToString("\n"), mismatches.isEmpty())
    }

    /**
     * V-N19 on the contingency path: a structural edit there rebuilds slot playlists instead of
     * calling setComposition. Upper bound: a cold engine (EGL, 2 decks per slot, prepare) → the
     * exact frame at the playhead, with 2, 4 and 6 slots; then warm exact seeks on that engine.
     */
    @Test
    fun structuralRebuild_contingency_vn19() {
        val runs = JSONArray()
        for (n in listOf(2, 4, 6)) {
            val plan = Scenarios.fullLength(30, n, seconds = 3)
            val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
            val times = TestMedia.videoSampleTimesUs("barcode_30.mp4")
            val regions = Scenarios.gridRegions(n)
            val warm = ArrayList<Double>()
            val mismatches = ArrayList<String>()
            var coldMs: Double
            var coldTimeoutState: String? = null
            var coldReseeks = 0
            var warmReseeks = 0
            Sink(plan.canvasW, plan.canvasH).use { sink ->
                val t0 = System.nanoTime()
                ContingencyEngineProto(ctx, plan, store, regions).use { e ->
                    e.attach(sink.reader.surface)
                    val ms = e.seekExact(15, 90_000)
                    coldMs = if (ms < 0) -1.0 else (System.nanoTime() - t0) / 1e6
                    if (ms < 0) coldTimeoutState = e.debugState()
                    coldReseeks = e.slotStats().sumOf { it.reseeks }
                    e.frames.lastOrNull()?.let { mismatches += Scenarios.checkFrame(plan, 15, it.regions, times, (1..n).toList()) }
                    for (k in listOf(45L, 20L, 70L, 33L, 52L)) {
                        val w = e.seekExact(k, 10_000)
                        warm += w
                        e.frames.lastOrNull()?.let { mismatches += Scenarios.checkFrame(plan, k, it.regions, times, (1..n).toList()) }
                    }
                    warmReseeks = e.slotStats().sumOf { it.reseeks } - coldReseeks
                }
            }
            runs.put(
                JSONObject().put("slots", n).put("decoders", 2 * n).put("coldRebuildToFrameMs", coldMs)
                    .put("coldTimeoutState", coldTimeoutState ?: JSONObject.NULL)
                    .put("coldStuckDeckReseeks", coldReseeks).put("warmStuckDeckReseeks", warmReseeks)
                    .put("warmExactSeekMs", Results.stats(warm.filter { it >= 0 })).put("warmTimeouts", warm.count { it < 0 })
                    .put("mismatches", Results.arr(mismatches)),
            )
        }
        Results.write("VN19_contingency_rebuild", JSONObject().put("device", android.os.Build.MODEL).put("runs", runs))
        // Correctness and completion are asserted; timing is recorded (it depends on the shared host).
        // Without the stuck-deck watchdog in seekExact, a 4- or 6-slot cold start on the loaded
        // emulator left a deck in BUFFERING with no frame for the whole 90 s timeout.
        for (i in 0 until runs.length()) {
            val r = runs.getJSONObject(i)
            assertEquals(r.toString(), 0, r.getJSONArray("mismatches").length())
            assertEquals(r.toString(), 0, r.getInt("warmTimeouts"))
            assertTrue(r.toString(), r.getDouble("coldRebuildToFrameMs") > 0)
        }
    }
}
