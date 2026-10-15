// OWNER: AND-11

// The AAC track of every Android export ends at the video's last frame (owner decision 2026-10-15,
// ARCH §14.3 "Facts recorded 2026-10-15", §14.4, D-38): |audio end − video end| ≤ one AAC frame
// (1024/48000 s = 21.333 ms), measured from the written MP4 with the platform MediaExtractor (last
// sample time + last sample duration: 1/fps for video, 1024 samples for AAC; ExportedFile.spans).
// Before the fix the AAC track ended 41–49 ms early on the API 35 emulator.
// Cases (through the production ExportCoordinator, single pass): a silent track (no audio) at
// 30 fps over 2 s and 5 s, a 24 fps export with a tone under the whole plan, a 60 fps export with a
// tone, an odd 61-frame 30 fps export whose audio stops before the end (trailing audio gap), and
// speed-changed clips (video and audio at 2× and 0.5×). The conformance fixtures (H.264, HEVC, V-N24,
// portrait retry, A/V offset) check the same bound in ExportConformanceTest; the precompose route in
// AND-19's PrecomposeExportTest. Numbers logged (tag DanaviewExportTest) are EMULATOR numbers.

package com.vecvel.danaview.editor.engine.export

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.plan.AudioSeg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.Keyframes
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class ExportAvDurationTest {
    private val harnesses = ArrayList<ExportHarness>()

    private fun harness(name: String) = ExportHarness(name).also { harnesses += it }

    @After
    fun tearDown() {
        harnesses.forEach { it.close() }
    }

    private class Source(val name: String, val fps: Int, val w: Int, val h: Int, val durUs: Long)

    private val c24 = Source("frame_counter_720p24.mp4", 24, 1280, 720, 10_000_000)
    private val c30 = Source("frame_counter_1080p30.mp4", 30, 1920, 1080, 8_000_000)
    private val c60 = Source("frame_counter_720p60.mp4", 60, 1280, 720, 8_000_000)

    private val toneAsset = "md_tone" to PlanAsset(PlanAssetKind.AUDIO, ExportPlans.media("tone_1khz.wav"), fp = "tone", durUs = 10_000_000)

    /** [src] shown full canvas for [frames] output frames at [fps] (source rate [rate]) with [audio]. */
    private fun plan(fps: Int, frames: Long, src: Source, audio: List<AudioSeg> = emptyList(), rate: Double = 1.0, extra: Map<String, PlanAsset> = emptyMap()): RenderPlan {
        val g = FrameGrid.of(fps)
        val layers: List<PlanLayer> = listOf(ExportPlans.mediaLayer("it_v#v", 10, 0, g, 0, frames, 0, src.fps, base = PlanSize(1280.0, 720.0), rate = rate))
        val p = RenderPlan(
            rev = 1, target = PlanTarget.EXPORT, canvas = PlanCanvas(1280, 720, fps), durUs = g.timeOfFrame(frames),
            assets = mapOf("md_src" to PlanAsset(PlanAssetKind.VIDEO, ExportPlans.media(src.name), fp = src.name, w = src.w, h = src.h, durUs = src.durUs)) + extra,
            layers = layers,
            audio = audio,
        )
        assertEquals(emptyList<Any>(), PlanValidator.validate(p))
        return p
    }

    /** The tone over plan time [t0, t1) at [rate] (source from 0), gain 0.5. */
    private fun tone(t0: Long, t1: Long, rate: Double = 1.0, id: String = "it_tone#a") =
        AudioSeg(id = id, asset = "md_tone", t0 = t0, t1 = t1, map = listOf(MapSegment(t0, t1, 0, Math.round((t1 - t0) * rate))), gain = Keyframes.of(0L to 0.5))

    private fun check(h: ExportHarness, plan: RenderPlan, name: String) {
        val o = h.export(plan, settings(fps = plan.canvas.fps, videoBitrate = if (plan.canvas.fps > 30) 7_500_000 else 5_000_000), name)
        val out = File(o.requireResult().path)
        val fps = plan.canvas.fps
        val frames = EncoderSettings.from(settings(fps = fps)).frameCount(plan.durUs).toInt()
        val s = ExportedFile.assertAudioSpansVideo(out, fps, name)
        assertEquals("$name frame count", frames, s.video.samples)
        val pcm = ExportedFile.decodeAudio(h.ctx, out)
        android.util.Log.i(EXPORT_TEST_TAG, "$name: plan ${plan.durUs} us; decoded ${pcm.durationUs} us of audio (priming removed) (emulator)")
        h.app.getExternalFilesDir(null)?.let { dir -> out.copyTo(File(dir, "and11_avdur_$name.mp4"), overwrite = true) }
    }

    @Test
    fun silentTrackSpansTheVideoAt30fps2sAnd5s() {
        val h = harness("avdur_silent")
        check(h, plan(30, 60, c30), "silent30_2s")
        check(h, plan(30, 150, c30), "silent30_5s")
    }

    @Test
    fun toneUnderA24fpsExportEndsWithTheVideo() {
        val h = harness("avdur_24")
        val g = FrameGrid.of(24)
        check(h, plan(24, 48, c24, audio = listOf(tone(0, g.timeOfFrame(48))), extra = mapOf(toneAsset)), "tone24_2s")
    }

    @Test
    fun toneUnderA60fpsExportEndsWithTheVideo() {
        val h = harness("avdur_60")
        val g = FrameGrid.of(60)
        check(h, plan(60, 120, c60, audio = listOf(tone(0, g.timeOfFrame(120))), extra = mapOf(toneAsset)), "tone60_2s")
    }

    @Test
    fun audioStoppingBeforeTheEndIsPaddedToAnOddLength() {
        val h = harness("avdur_odd")
        val g = FrameGrid.of(30)
        // 61 frames (2.0333 s, not a whole number of AAC frames); the tone stops at frame 40.
        check(h, plan(30, 61, c30, audio = listOf(tone(0, g.timeOfFrame(40))), extra = mapOf(toneAsset)), "tail_gap30_61f")
    }

    @Test
    fun speedChangedClipsEndWithTheVideo() {
        val h = harness("avdur_speed")
        val g = FrameGrid.of(30)
        val dur = g.timeOfFrame(60)
        check(h, plan(30, 60, c30, audio = listOf(tone(0, dur, rate = 2.0)), rate = 2.0, extra = mapOf(toneAsset)), "speed2x")
        check(h, plan(30, 60, c30, audio = listOf(tone(0, dur, rate = 0.5)), rate = 0.5, extra = mapOf(toneAsset)), "speed0_5x")
    }
}
