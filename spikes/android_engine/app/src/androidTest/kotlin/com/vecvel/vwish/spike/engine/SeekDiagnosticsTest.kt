@file:OptIn(UnstableApi::class, ExperimentalApi::class)

package com.vecvel.vwish.spike.engine

import android.graphics.ImageFormat
import android.hardware.HardwareBuffer
import android.media.ImageReader
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * V-N18 seek semantics and the R1 seek finding, separated from the grid-cut composition:
 *  - [compositionPlayerSeekByTopology]: the spike's compositions (clock band, compositor
 *    settings, effects) of one or two sequences: none answers an exact seek.
 *  - [compositionPlayerSeekIsolation]: the minimal reproduction: plain compositions seek exactly
 *    with CompositionPlayer's default (single-input) graph and never with MultipleInputVideoGraph.
 *  - [exoPlayerExactSeekSemantics]: the same question for a plain `ExoPlayer` with
 *    `SeekParameters.EXACT`, which is what the AND-16 slot players use.
 */
@RunWith(AndroidJUnit4::class)
class SeekDiagnosticsTest {
    private val ctx = TestMedia.target
    private val mapper = SpikeCompositionMapper(ctx)
    private val ks = listOf(1L, 2, 4, 5, 13, 14, 37, 38, 40, 41, 62, 64, 91, 92, 100, 101)

    private fun cause(t: Throwable): String =
        generateSequence(t) { it.cause }.take(5).joinToString(" <- ") { "${it.javaClass.simpleName}: ${it.message}" }

    /** Seeks to floor and ceil ms of P(k) for every k; records the frame index shown. */
    private fun seekRun(seekAndAwait: (Long) -> Long?, fps: Int, ks: List<Long> = this.ks): JSONObject {
        var floorHits = 0
        var ceilHits = 0
        var answered = 0
        val rows = JSONArray()
        for (k in ks) {
            val row = JSONObject().put("k", k)
            for ((name, ms) in listOf("floor" to GridTime.platformMsFloor(k, fps), "ceil" to GridTime.platformMsCeil(k, fps))) {
                seekAndAwait(if (k > 20) 0 else 3000)
                val pts = seekAndAwait(ms)
                if (pts == null) {
                    row.put(name, JSONObject.NULL)
                    continue
                }
                answered++
                val got = GridTime.frameIndexNearest(pts, fps)
                row.put(name, JSONObject().put("ms", ms).put("pts", pts).put("k", got))
                if (got == k && name == "floor") floorHits++
                if (got == k && name == "ceil") ceilHits++
            }
            rows.put(row)
        }
        val rounding = when {
            answered == 0 -> "unanswered"
            floorHits == ks.size && ceilHits == ks.size -> "either"
            floorHits == ks.size -> "floor"
            ceilHits == ks.size -> "ceil"
            else -> "inconsistent"
        }
        return JSONObject().put("seeks", ks.size * 2).put("answered", answered).put("floorHits", floorHits)
            .put("ceilHits", ceilHits).put("rounding", rounding).put("cases", rows)
    }

    private fun compositionRun(name: String, plan: SpikePlan, options: MapperOptions, dropLate: Boolean = false): JSONObject {
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val out = JSONObject().put("topology", name)
        try {
            PlayerHarness(ctx, plan.canvasW, plan.canvasH, dropLateInput = dropLate).use { h ->
                h.load(mapper.build(plan, store, options))
                h.awaitReady()
                out.put("sequences", sequencesOf(plan, options))
                // Four cases (8 seeks): every topology through MultipleInputVideoGraph fails anyway.
                val r = seekRun({ ms -> h.seekAndAwait(ms, 2000)?.first?.ptsUs }, plan.fps, ks.take(4))
                for (key in r.keys()) out.put(key, r.get(key))
                out.put("error", h.error.get()?.let { cause(it) } ?: JSONObject.NULL)
            }
        } catch (t: Throwable) {
            out.put("sequences", sequencesOf(plan, options)).put("answered", 0).put("rounding", "unanswered").put("error", cause(t))
        }
        return out
    }

    private fun sequencesOf(plan: SpikePlan, o: MapperOptions): Int =
        (if (o.includeClockBand) 1 else 0) + plan.visualSequenceCount + (if (o.includeBackground) 1 else 0) +
            (if (o.includeAudio) plan.audioLaneCount else 0)

    @Test
    fun compositionPlayerSeekByTopology() {
        val fps = 30
        val src = "barcode_30.mp4"
        val one = SpikePlan(Scenarios.W, Scenarios.H, fps, fps, 120, listOf(SpikeLayer("A", 1, 0, 120, TestMedia.uri(src), 0, Scenarios.FULL)))
        val two = one.copy(layers = one.layers + SpikeLayer("B", 2, 0, 120, TestMedia.uri(src), Scenarios.srcAt(src, 4.0), Scenarios.RECTS.getValue(2)))
        val empty = one.copy(layers = emptyList())
        val bare = MapperOptions(includeAudio = false, includeBackground = false)
        val runs = JSONArray()
        // 1 sequence: the H.264 clock band alone.
        runs.put(compositionRun("clock_video_only", empty, Scenarios.videoClock(fps, bare)))
        // 1 sequence: one full-length video item, no clock band.
        runs.put(compositionRun("one_video_sequence", one, bare.copy(includeClockBand = false)))
        // 2 sequences: video primary + background image secondary.
        runs.put(compositionRun("video_plus_background_image", one, MapperOptions(includeAudio = false, includeClockBand = false)))
        // 2 sequences: two full-length video sequences.
        runs.put(compositionRun("two_video_sequences", two, bare.copy(includeClockBand = false)))
        // 2 sequences: clock video band + one full-length video sequence.
        runs.put(compositionRun("clock_video_plus_video", one, Scenarios.videoClock(fps, bare)))
        // Same with Media3's default late-drop policy.
        runs.put(compositionRun("clock_video_plus_video_default_drop", one, Scenarios.videoClock(fps, bare), dropLate = true))
        Results.write("VN18_composition_seek_topologies", JSONObject().put("runs", runs))
        // The R1 finding: through MultipleInputVideoGraph (needed to composite sequences) no
        // topology answers a single exact seek, not even one sequence.
        for (i in 0 until runs.length()) {
            val r = runs.getJSONObject(i)
            assertEquals("CompositionPlayer seek now works (${r.getString("topology")}): R1 may be a go, rerun AND-01: $r", "unanswered", r.getString("rounding"))
        }
    }

    /**
     * Isolates the CompositionPlayer seek failure from the spike's own machinery: plain
     * compositions (no effects, no compositor settings, no clock band) of one or two full-length
     * video sequences, with CompositionPlayer's default video graph and with
     * MultipleInputVideoGraph, late-drop disabled or default. Each run prepares, then makes 6
     * paused exact seeks and records which ones rendered the requested frame.
     */
    @Test
    fun compositionPlayerSeekIsolation() {
        val fps = 30
        val uri = TestMedia.uri("barcode_30.mp4")
        fun seqOf(startUs: Long): androidx.media3.transformer.EditedMediaItemSequence {
            val item = MediaItem.Builder().setUri(Uri.parse(uri))
                .setClippingConfiguration(MediaItem.ClippingConfiguration.Builder().setStartPositionUs(startUs).setEndPositionUs(startUs + 4_000_000).build())
                .build()
            val edited = androidx.media3.transformer.EditedMediaItem.Builder(item)
                .setDurationUs(SpikeCompositionMapper.Companion.SourceDurations.of(ctx, uri)).setRemoveAudio(true).build()
            return androidx.media3.transformer.EditedMediaItemSequence.Builder(setOf(androidx.media3.common.C.TRACK_TYPE_VIDEO)).addItem(edited).build()
        }
        val one = androidx.media3.transformer.Composition.Builder(listOf(seqOf(0))).build()
        val two = androidx.media3.transformer.Composition.Builder(listOf(seqOf(0), seqOf(2_000_000))).build()
        val runs = JSONArray()
        val cases = listOf(
            Triple("one_sequence_default_graph", one, false),
            Triple("one_sequence_multiple_input_graph", one, true),
            Triple("two_sequences_multiple_input_graph", two, true),
        )
        for ((name, comp, mig) in cases) {
            for (dropLate in listOf(false, true)) {
                val out = JSONObject().put("case", name).put("dropLateInput", dropLate)
                var answered = 0
                val got = JSONArray()
                try {
                    PlayerHarness(ctx, Scenarios.W, Scenarios.H, dropLateInput = dropLate, multipleInputVideoGraph = mig).use { h ->
                        h.load(comp)
                        h.awaitReady()
                        out.put("renderedWhilePreparing", h.rendered.size)
                        for (k in listOf(45L, 7L, 90L, 31L, 62L, 15L)) {
                            val t0 = System.nanoTime()
                            val r = h.seekAndAwait(GridTimingTest.seekMs(k, fps), 3000)
                            if (r != null && GridTime.frameIndexNearest(r.first.ptsUs, fps) == k) answered++
                            // Surface images after the seek (a frame may reach the surface without a metadata callback).
                            val images = h.images.count { it.wallNs >= t0 }
                            got.put(JSONObject().put("k", k).put("pts", r?.first?.ptsUs ?: JSONObject.NULL).put("latencyMs", r?.second ?: JSONObject.NULL).put("surfaceImages", images))
                        }
                        // Does playback resume after the seeks?
                        val t1 = System.nanoTime()
                        h.run { h.player.play() }
                        Thread.sleep(1500)
                        h.run { h.player.pause() }
                        out.put("renderedIn1500msAfterSeeks", h.rendered.count { it.wallNs >= t1 })
                            .put("positionMsAfterPlay", h.positionMs())
                        out.put("error", h.error.get()?.let { cause(it) } ?: JSONObject.NULL)
                    }
                } catch (t: Throwable) {
                    out.put("error", cause(t))
                }
                runs.put(out.put("seeks", 6).put("answered", answered).put("results", got))
            }
        }
        Results.write("VN18_composition_seek_isolation", JSONObject().put("runs", runs))
        val all = (0 until runs.length()).map { runs.getJSONObject(it) }
        // The single-input graph seeks exactly (6/6 with Media3's default late-drop policy)...
        assertEquals(all.toString(), 6, all.first { it.getString("case") == "one_sequence_default_graph" && it.getBoolean("dropLateInput") }.getInt("answered"))
        // ...MultipleInputVideoGraph never does, with one or two sequences (R1).
        for (r in all.filter { it.getString("case").endsWith("multiple_input_graph") }) {
            assertEquals("MultipleInputVideoGraph seek now works: R1 may be a go, rerun AND-01: $r", 0, r.getInt("answered"))
        }
    }

    @Test
    fun exoPlayerExactSeekSemantics() {
        val fps = 30
        val thread = HandlerThread("exo-seek").apply { start() }
        val handler = Handler(thread.looper)
        val readerThread = HandlerThread("exo-seek-reader").apply { start() }
        val reader = ImageReader.newInstance(Scenarios.W, Scenarios.H, ImageFormat.PRIVATE, 3, HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE)
        reader.setOnImageAvailableListener({ it.acquireLatestImage()?.close() }, Handler(readerThread.looper))
        val rendered = ConcurrentLinkedQueue<Pair<Long, Long>>()
        val error = AtomicReference<PlaybackException?>()
        fun <T> on(block: () -> T): T {
            val r = AtomicReference<Any?>()
            val latch = CountDownLatch(1)
            handler.post { r.set(block()); latch.countDown() }
            check(latch.await(20, TimeUnit.SECONDS))
            @Suppress("UNCHECKED_CAST")
            return r.get() as T
        }
        // The clock clip: its frame k sits at P(k) like the clock band (checked below).
        val clockTimes = TestMedia.videoSampleTimesUs("clock_30.mp4")
        val offP = clockTimes.withIndex().count { (k, t) -> Math.abs(t - GridTime.platformTimeOfFrame(k.toLong(), fps)) > 1 }
        val player = on {
            ExoPlayer.Builder(ctx).setLooper(thread.looper).build().also { p ->
                p.setSeekParameters(SeekParameters.EXACT)
                p.setVideoSurface(reader.surface)
                p.setVideoFrameMetadataListener { pts, _, _, _ -> rendered.add(pts to System.nanoTime()) }
                p.addListener(object : Player.Listener {
                    override fun onPlayerError(e: PlaybackException) = error.set(e)
                })
                p.setMediaItem(MediaItem.fromUri(Uri.parse(TestMedia.uri("clock_30.mp4"))))
                p.prepare()
            }
        }
        val latencies = ArrayList<Double>()
        val r = try {
            val end = SystemClock.elapsedRealtime() + 20_000
            while (on { player.playbackState } != Player.STATE_READY && SystemClock.elapsedRealtime() < end) Thread.sleep(10)
            seekRun({ ms ->
                val t0 = System.nanoTime()
                on { player.seekTo(ms) }
                var got: Long? = null
                val until = SystemClock.elapsedRealtime() + 3000
                while (got == null && SystemClock.elapsedRealtime() < until && error.get() == null) {
                    got = rendered.firstOrNull { it.second >= t0 }?.first
                    if (got == null) Thread.sleep(2)
                }
                if (got != null) latencies += (rendered.first { it.second >= t0 }.second - t0) / 1e6
                got
            }, fps)
        } finally {
            on { player.release() }
            reader.close()
            thread.quitSafely()
            readerThread.quitSafely()
        }
        r.put("clipFramesOffP", offP).put("latencyMs", Results.stats(latencies)).put("error", error.get()?.let { cause(it) } ?: JSONObject.NULL)
        Results.write("VN18_exoplayer_seek_semantics", r)
        assertEquals("clock clip frames sit on P(k)", 0, offP)
        assertTrue(r.toString(), r.getString("rounding") == "floor" || r.getString("rounding") == "either")
    }
}
