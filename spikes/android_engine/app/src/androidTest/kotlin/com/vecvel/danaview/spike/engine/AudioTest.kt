@file:OptIn(UnstableApi::class, ExperimentalApi::class)

package com.vecvel.danaview.spike.engine

import android.media.MediaFormat
import androidx.media3.common.C
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * V-N23 (preview A/V latency, and whether the audio sink can delay audio) and V-N24 (the clock
 * band's trackTypes give a silent AAC track in Transformer output).
 */
@RunWith(AndroidJUnit4::class)
class AudioTest {
    private val ctx = TestMedia.target
    private val mapper = SpikeCompositionMapper(ctx)

    // ------------------------------------------------------------------ V-N23

    private data class Fit(val a: Double, val b: Double) {
        fun at(wallNs: Long) = a + b * wallNs
    }

    /** Least-squares fit of audio position (µs) against wall clock (ns) over the steady part. */
    private fun fit(samples: List<AudioClockSample>): Fit {
        val s = samples.drop(samples.size / 10)
        val mx = s.map { it.wallNs.toDouble() }.average()
        val my = s.map { it.positionUs.toDouble() }.average()
        var num = 0.0
        var den = 0.0
        for (p in s) {
            num += (p.wallNs - mx) * (p.positionUs - my)
            den += (p.wallNs - mx) * (p.wallNs - mx)
        }
        val b = num / den
        return Fit(my - b * mx, b)
    }

    private fun avRun(leadUs: Long): JSONObject {
        val base = Scenarios.fullLength(30, 1, seconds = 4)
        val plan = base.copy(audio = listOf(SpikeAudio("tone", 0, 0, base.durFrames, TestMedia.uri("tone_440.m4a"), 0)))
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val sink = OffsetAudioSink(DefaultAudioSink.Builder(ctx).build(), leadUs)
        val c = mapper.build(plan, store, Scenarios.videoClock(30))
        PlayerHarness(ctx, plan.canvasW, plan.canvasH, dropLateInput = true, configure = { it.setAudioSink(sink) }).use { h ->
            h.load(c)
            h.awaitReady()
            h.seekAndAwait(0, 10_000)
            sink.clock.clear()
            val t0 = System.nanoTime()
            val ended = h.playToEnd(plan.durUs / 1000 + 30_000)
            val samples = sink.clock.filter { it.wallNs >= t0 }
            val rendered = h.rendered.filter { it.wallNs >= t0 }
            val f = fit(samples)
            // Sink time base: the first buffer after the seek to 0 is composition time 0.
            val baseUs = sink.firstBufferPtsUs.lastOrNull() ?: 0L
            // > 0: video is released later than the audio of the same media time is heard.
            val offsets = rendered.filter { it.releaseTimeNs > 0 }.map { (f.at(it.releaseTimeNs) - baseUs - it.ptsUs) / 1000.0 }
            val readerLatency = h.images.filter { it.wallNs >= t0 }.mapNotNull { img ->
                rendered.firstOrNull { it.releaseTimeNs == img.timestampNs }?.let { (img.wallNs - it.releaseTimeNs) / 1e6 }
            }
            return JSONObject().put("leadUs", leadUs).put("ended", ended)
                .put("audioClockSamples", samples.size).put("audioRate", f.b * 1000.0)
                .put("sinkBaseUs", baseUs).put("renderedFrames", rendered.size).put("dropped", h.dropped.get())
                .put("videoMinusAudioMs", Results.stats(offsets))
                .put("releaseToImageReaderMs", Results.stats(readerLatency))
        }
    }

    @Test
    fun previewAvLatency_and_audioDelay_vn23() {
        val plain = avRun(0)
        val led = avRun(40_000)
        val p50a = plain.getJSONObject("videoMinusAudioMs").getDouble("p50")
        val p50b = led.getJSONObject("videoMinusAudioMs").getDouble("p50")
        val shift = p50a - p50b
        Results.write(
            "VN23_av_latency",
            JSONObject().put("noLead", plain).put("lead40ms", led).put("measuredShiftMs", shift)
                .put("sinkCanDelayAudio", Math.abs(shift - 40) <= 12),
        )
        assertTrue("no audio clock samples: $plain", plain.getInt("audioClockSamples") > 50)
        assertTrue("a 40 ms sink lead must move video 40 ms earlier relative to audio (got $shift)", Math.abs(shift - 40) <= 12)
    }

    // ------------------------------------------------------------------ V-N24

    private fun silentExport(name: String, options: MapperOptions): JSONObject {
        val plan = Scenarios.fullLength(30, 1, seconds = 2)
        val store = ParamStore(plan.gridFps).apply { loadFrom(plan) }
        val o = ExportHarness(ctx).export(mapper.build(plan, store, options.copy(includeAudio = false)), File(TestMedia.outDir, "silent_$name.mp4"))
        val tracks = OutputInspector.tracks(o.file)
        val audio = tracks.firstOrNull { it.mime.startsWith("audio/") }
        val stats = OutputInspector.decodeAudio(o.file)
        val videoDurUs = tracks.first { it.mime.startsWith("video/") }.format.getLong(MediaFormat.KEY_DURATION)
        return JSONObject().put("variant", name).put("tracks", JSONArray(tracks.map { it.mime }))
            .put("audioMime", audio?.mime ?: JSONObject.NULL)
            .put("audioSampleRate", audio?.format?.getInteger(MediaFormat.KEY_SAMPLE_RATE) ?: JSONObject.NULL)
            .put("audioChannels", audio?.format?.getInteger(MediaFormat.KEY_CHANNEL_COUNT) ?: JSONObject.NULL)
            .put("audioDurationUs", audio?.format?.let { if (it.containsKey(MediaFormat.KEY_DURATION)) it.getLong(MediaFormat.KEY_DURATION) else null } ?: JSONObject.NULL)
            .put("videoDurationUs", videoDurUs)
            .put("decodedPeak", stats?.peak ?: JSONObject.NULL).put("decodedRms", stats?.rms ?: JSONObject.NULL)
            .put("decodedFrames", stats?.frames ?: JSONObject.NULL)
    }

    @Test
    fun clockBandTrackTypesGiveSilentAac_vn24() {
        val av = setOf(C.TRACK_TYPE_VIDEO, C.TRACK_TYPE_AUDIO)
        val imageAv = silentExport("image_clock_video_audio", MapperOptions(clockBandTrackTypes = av))
        val videoAv = silentExport("video_clock_video_audio", Scenarios.videoClock(30, MapperOptions(clockBandTrackTypes = av)))
        val imageV = silentExport("image_clock_video_only", MapperOptions(clockBandTrackTypes = setOf(C.TRACK_TYPE_VIDEO)))
        Results.write("VN24_silent_aac", JSONObject().put("runs", JSONArray().put(imageAv).put(videoAv).put(imageV)))
        for (r in listOf(imageAv, videoAv)) {
            assertEquals(r.toString(), MediaFormat.MIMETYPE_AUDIO_AAC, r.getString("audioMime"))
            assertTrue(r.toString(), r.getDouble("decodedPeak") < 1e-3)
            assertTrue(r.toString(), r.getLong("decodedFrames") >= r.getInt("audioSampleRate") * 19L / 10)
        }
        assertNull("control without AUDIO trackType has no audio track", imageV.opt("audioMime")?.takeIf { it != JSONObject.NULL })
        assertNotNull(imageAv)
    }
}
