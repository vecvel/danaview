@file:OptIn(UnstableApi::class, ExperimentalApi::class)

package com.vecvel.vwish.spike.engine

import android.media.MediaCodecList
import android.media.MediaFormat
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import kotlin.math.abs
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * V-N25: six overlay lanes of short, non-overlapping PiP clips. Unpacked (6 or 12 sequences) vs
 * packed (1 or 2 slots, ARCH §13.5): decoder instances, memory and dropped frames, from which the
 * `maxVisualSequences` tier values (D-14) are set.
 */
@RunWith(AndroidJUnit4::class)
class PackingTest {
    private val ctx = TestMedia.target
    private val mapper = SpikeCompositionMapper(ctx)
    private val clips = 12
    private val clipFrames = 12L

    private fun lane(c: Int) = c % 6

    private fun plan(slotOf: (Int) -> Int): SpikePlan {
        val src = "barcode_30.mp4"
        val times = TestMedia.videoSampleTimesUs(src)
        val layers = (0 until clips).map { c ->
            SpikeLayer("c$c", slotOf(c), c * clipFrames, (c + 1) * clipFrames, TestMedia.uri(src), times[10 + c * 25], Scenarios.gridRect(lane(c)))
        }
        return SpikePlan(Scenarios.W, Scenarios.H, 30, 30, clips * clipFrames, layers)
    }

    private val configs: List<Pair<String, (Int) -> Int>> = listOf(
        "unpacked_12" to { c -> c + 1 },
        "unpacked_6" to { c -> lane(c) + 1 },
        "packed_2" to { c -> c % 2 + 1 },
        "packed_1" to { _ -> 1 },
    )

    private fun lanes() = (0 until 6).map { ProbeRegion("lane$it", Scenarios.gridRect(it)) }

    /** Per-lane expected content: the clip of that lane active at k, else background. */
    private fun mismatches(plan: SpikePlan, frames: List<ProbeFrame>): List<String> {
        val times = TestMedia.videoSampleTimesUs("barcode_30.mp4")
        val out = ArrayList<String>()
        for (f in frames) {
            val k = GridTime.frameIndexNearest(f.ptsUs, plan.fps)
            if (k < 0 || k >= plan.durFrames) continue
            for (l in 0 until 6) {
                val clip = plan.layers.firstOrNull { lane(it.id.drop(1).toInt()) == l && k >= it.k0 && k < it.k1 }
                val want = clip?.let { TestMedia.ruleFrame(times, it.srcStartUs + GridTime.timeOfFrame(k, 30) - GridTime.timeOfFrame(it.k0, 30)) }
                val got = f.regions["lane$l"]?.reading
                val ok = if (want == null) got == Barcode.Background else got == Barcode.Value(want)
                if (!ok) out += "k=$k lane$l want=${want ?: "bg"} got=$got"
            }
        }
        return out
    }

    /**
     * For each composited mismatch: what the sequence carrying that lane's clip handed the
     * compositor around that output frame (sequence-level probe readings at k − 1, k, k + 1), and
     * every source frame of a clip that never reached the compositor.
     */
    private fun diagnose(plan: SpikePlan, mm: List<String>, seqProbes: Map<Int, ProbeEffect>): JSONObject {
        val times = TestMedia.videoSampleTimesUs("barcode_30.mp4")
        val near = JSONArray()
        for (m in mm.take(6)) {
            val k = m.substringAfter("k=").substringBefore(" ").toLong()
            val l = m.substringAfter("lane").substringBefore(" ").toInt()
            val clip = plan.layers.firstOrNull { lane(it.id.drop(1).toInt()) == l && k >= it.k0 && k < it.k1 } ?: continue
            val frames = seqProbes[clip.seq]?.frames?.toList().orEmpty()
                .filter { abs(GridTime.frameIndexNearest(it.ptsUs, plan.fps) - k) <= 1 }
                .map { "k=${GridTime.frameIndexNearest(it.ptsUs, plan.fps)} pts=${it.ptsUs} ${it.regions["lane$l"]?.reading}" }
            near.put(JSONObject().put("mismatch", m).put("seq", clip.seq).put("sequenceFrames", Results.arr(frames)))
        }
        val missing = JSONArray()
        for (clip in plan.layers) {
            val l = lane(clip.id.drop(1).toInt())
            val seen = seqProbes[clip.seq]?.frames?.toList().orEmpty().mapNotNull { (it.regions["lane$l"]?.reading as? Barcode.Value)?.n }.toSet()
            for (k in clip.k0 until clip.k1) {
                val want = TestMedia.ruleFrame(times, clip.srcStartUs + GridTime.timeOfFrame(k, 30) - GridTime.timeOfFrame(clip.k0, 30))
                if (want !in seen) missing.put("${clip.id} seq${clip.seq} k=$k src=$want")
            }
        }
        return JSONObject().put("nearMismatches", near).put("sourceFramesNeverHandedToCompositor", missing)
    }

    private fun avcMaxInstances(): Int = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
        .filter { !it.isEncoder && it.supportedTypes.any { t -> t.equals(MediaFormat.MIMETYPE_VIDEO_AVC, true) } }
        .maxOfOrNull { it.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC).maxSupportedInstances } ?: -1

    /**
     * Transformer export of the six-lane case per configuration, with the gap fill AND-08 adopts
     * (transparent image items at the output fps, AND-01 V-N18 finding) and, for packed_2, with
     * Media3 `addGap` for comparison (recorded, not asserted).
     */
    @Test
    fun sixLanePip_export_vn25() {
        val runs = JSONArray()
        val variants = configs.map { Triple(it.first, it.second, GapFill.TRANSPARENT_IMAGE) } +
            configs.filter { it.first == "packed_2" }.map { Triple(it.first, it.second, GapFill.GAP) }
        for ((name, slotOf, gapFill) in variants) {
            val plan = plan(slotOf)
            val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
            val probe = ProbeEffect(plan.canvasW, plan.canvasH, plan.bgRgb(), lanes())
            val c = mapper.build(plan, store, MapperOptions(probe = probe, includeAudio = false, epsilon = EpsilonMode.SNAP_TO_RULE_FRAME, gapFill = gapFill))
            val json = JSONObject().put("config", name).put("gapFill", gapFill.name).put("visualSequences", plan.visualSequenceCount)
            SystemProbe().use { sp ->
                try {
                    val o = ExportHarness(ctx).export(c, File(TestMedia.outDir, "pip_${name}_$gapFill.mp4"), timeoutSec = 600)
                    val mm = mismatches(plan, probe.frames.toList())
                    val badKs = mm.map { it.substringAfter("k=").substringBefore(" ").toLong() }.toSortedSet()
                    json.put("exported", true).put("wallMs", o.wallMs).put("realtimeFactor", plan.durUs / 1000.0 / o.wallMs)
                        .put("frames", o.result.videoFrameCount).put("mismatches", mm.size).put("badFrames", JSONArray(badKs.toList()))
                        .put("firstMismatches", Results.arr(mm.take(6)))
                } catch (e: Throwable) {
                    json.put("exported", false).put("error", e.toString()).put("cause", e.cause?.toString() ?: "")
                }
                json.put("codecs", sp.codecStats()).put("memory", sp.memory())
            }
            runs.put(json)
        }
        Results.write("VN25_pip_export", JSONObject().put("avcDecoderMaxInstances", avcMaxInstances()).put("runs", runs))
        for (i in 0 until runs.length()) {
            val r = runs.getJSONObject(i)
            if (r.getString("gapFill") != GapFill.TRANSPARENT_IMAGE.name) continue
            assertTrue(r.toString(), r.getBoolean("exported"))
            assertEquals(r.toString(), 0, r.getInt("mismatches"))
        }
    }

    /**
     * The packed_2 export (the configuration AND-08 produces for this case) repeated, with
     * sequence-level probes on both slots: frame-exact every time? A one-frame error under heavy
     * host load (load average 35–48) in one sixLanePip_export_vn25 run (k=68 showed the previous
     * source frame mid-clip) is the question; the probes tell a frame lost before the compositor
     * from a wrong secondary-frame choice in it.
     */
    @Test
    fun packedExport_repeated_vn25() {
        val runs = JSONArray()
        val plan = plan { c -> c % 2 + 1 }
        var total = 0
        repeat(REPEATS) { i ->
            val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
            val probe = ProbeEffect(plan.canvasW, plan.canvasH, plan.bgRgb(), lanes())
            val seqProbes = (1..plan.visualSequenceCount).associateWith { ProbeEffect(plan.canvasW, plan.canvasH, plan.bgRgb(), lanes()) }
            val c = mapper.build(
                plan, store,
                MapperOptions(probe = probe, includeAudio = false, epsilon = EpsilonMode.SNAP_TO_RULE_FRAME, gapFill = GapFill.TRANSPARENT_IMAGE, sequenceProbes = seqProbes),
            )
            val o = ExportHarness(ctx).export(c, File(TestMedia.outDir, "pip_packed_2_repeat.mp4"), timeoutSec = 600)
            val mm = mismatches(plan, probe.frames.toList())
            total += mm.size
            val diag = diagnose(plan, mm, seqProbes)
            runs.put(
                JSONObject().put("run", i).put("wallMs", o.wallMs).put("frames", o.result.videoFrameCount).put("mismatches", mm.size)
                    .put("firstMismatches", Results.arr(mm.take(6)))
                    .put("sequenceFrames", JSONObject(seqProbes.mapKeys { "seq${it.key}" }.mapValues { it.value.frames.size } as Map<*, *>))
                    .put("diagnosis", diag),
            )
        }
        Results.write("VN25_pip_export_repeat", JSONObject().put("repeats", REPEATS).put("mismatches", total).put("runs", runs))
        assertEquals(runs.toString(), 0, total)
    }

    private companion object {
        const val REPEATS = 8
    }

    /**
     * Player footprint: prepare, then 2 s of playback from 0 (multi-sequence seeks fail in Media3
     * 1.11.1, R1). Every configuration has item transitions or gaps in secondary sequences, so
     * playback stalls at the first one (PlayerTopologyTest); the prepared footprint (one ExoPlayer
     * + decoder per sequence) is what the measurement is for.
     */
    @Test
    fun sixLanePip_playerFootprint_vn25() {
        val runs = JSONArray()
        for ((name, slotOf) in configs) {
            val plan = plan(slotOf)
            val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
            val c = mapper.build(plan, store, Scenarios.videoClock(30, MapperOptions(includeAudio = false, epsilon = EpsilonMode.SNAP_TO_RULE_FRAME)))
            val json = JSONObject().put("config", name).put("visualSequences", plan.visualSequenceCount)
            SystemProbe().use { sp ->
                try {
                    PlayerHarness(ctx, plan.canvasW, plan.canvasH, dropLateInput = true).use { h ->
                        val t0 = System.nanoTime()
                        h.load(c)
                        h.awaitReady()
                        json.put("prepareMs", (System.nanoTime() - t0) / 1e6)
                        val t1 = System.nanoTime()
                        h.run { h.player.play() }
                        Thread.sleep(2000)
                        h.run { h.player.pause() }
                        val r = h.rendered.filter { it.wallNs >= t1 }
                        json.put("renderedIn2s", r.size).put("droppedFrames", h.dropped.get())
                            .put("maxRenderedK", GridTime.frameIndexNearest(r.maxOfOrNull { it.ptsUs } ?: -1, 30))
                    }
                } catch (e: Throwable) {
                    json.put("error", e.toString()).put("cause", e.cause?.toString() ?: "")
                }
                json.put("codecs", sp.codecStats()).put("memory", sp.memory())
            }
            runs.put(json)
        }
        Results.write("VN25_pip_player", JSONObject().put("avcDecoderMaxInstances", avcMaxInstances()).put("runs", runs))
        assertEquals(configs.size, runs.length())
    }
}
