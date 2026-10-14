@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-11

// End-to-end exports through the production ExportCoordinator on the emulator (ARCH §14.3, §14.4,
// D-38, D-39; BUILD_PLAN AND-11 acceptance criteria). Every number logged here is an EMULATOR
// measurement (tag DanaviewExportTest), never a device number.
// - H.264 and HEVC conformance (V-N13): MP4, `avc1` / `hvc1` sample entries (never `hev1`), size,
//   frame count and PTS on the export grid, rotation 0, AAC-LC 48 kHz stereo, the encoder that ran
//   recorded, and the preflight's softwareEncoder warning consistent with the result's hardware flag.
// - V-N24: a no-audio plan, an all-muted plan and an images/text-only plan (image, solid, sprite)
//   each get a silent AAC 48 kHz stereo track covering the video.
// - gridFps 30 exported at 24 fps: every output frame on the 24 fps grid shows its plan rule frame
//   (barcodes, software-first decoders).
// - A/V offset (clap_flash_av.mp4): flash frames against click onsets ≤ 1 frame and ≤ 20 ms.
// - Portrait retry (ARCH §14.1) with an injected encoder refusal of portrait formats: one landscape
//   retry with rotation metadata and the `portraitRetried` warning; refusing both ways fails with
//   encoderSizeLimit and leaves no file.
// - Cancel deletes the partial output and leaves no record; a missing source fails with
//   mediaOffline; a completion with no Dart listener keeps a completedWhileDetached record and its
//   file survives the next launch's work/ wipe until the record is consumed (D-39); a record left
//   by a dead process is reported interrupted once (the real process kill is ExportProcessDeathTest).

package com.vecvel.danaview.editor.engine.export

import android.media.MediaFormat
import android.media.metrics.LogSessionId
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.Format
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Codec
import androidx.media3.transformer.ExportException
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.composition.OutputReader
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineThreads
import com.vecvel.danaview.editor.engine.media.WorkExemptions
import com.vecvel.danaview.editor.engine.pigeon.DetachedHandoffMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportJobStateKindMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportPhaseMsg
import com.vecvel.danaview.editor.engine.pigeon.VideoCodecMsg
import com.vecvel.danaview.editor.engine.plan.AudioSeg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.Keyframes
import com.vecvel.danaview.editor.engine.plan.MapSegment
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanLayer
import com.vecvel.danaview.editor.engine.plan.PlanLayerKind
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.PlanValidator
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class ExportConformanceTest {
    private val harnesses = ArrayList<ExportHarness>()

    private fun harness(name: String, fixedRoot: Boolean = false) = ExportHarness(name, fixedRoot).also { harnesses += it }

    @After
    fun tearDown() {
        harnesses.forEach { it.close() }
    }

    // ---- plans ----

    private fun validated(plan: RenderPlan): RenderPlan = plan.also { assertEquals(emptyList<Any>(), PlanValidator.validate(it)) }

    /** frame_counter_1080p30 shown at [w] x [h] for [frames] output frames at 30 fps (no audio). */
    private fun counterPlan(w: Int = 1280, h: Int = 720, frames: Long = 60, audio: List<AudioSeg> = emptyList(), extraAssets: Map<String, PlanAsset> = emptyMap()): RenderPlan {
        val g = FrameGrid.of(30)
        return validated(
            RenderPlan(
                rev = 1, target = PlanTarget.EXPORT, canvas = PlanCanvas(w, h, 30), durUs = g.timeOfFrame(frames),
                assets = mapOf("md_src" to PlanAsset(PlanAssetKind.VIDEO, ExportPlans.media("frame_counter_1080p30.mp4"), fp = "fc1080", w = 1920, h = 1080, durUs = 8_000_000)) + extraAssets,
                layers = listOf(ExportPlans.mediaLayer("it_v#v", 10, 0, g, 0, frames, 0, 30, base = PlanSize(w.toDouble(), h.toDouble()))),
                audio = audio,
            ),
        )
    }

    private fun assertSilentAac48kStereo(h: ExportHarness, out: File, videoUs: Long, name: String) {
        val track = ExportedFile.audio(out)
        assertEquals("$name audio mime", "audio/mp4a-latm", track.mime)
        assertEquals("$name sample rate", 48_000, track.format.getInteger(MediaFormat.KEY_SAMPLE_RATE))
        assertEquals("$name channels", 2, track.format.getInteger(MediaFormat.KEY_CHANNEL_COUNT))
        val pcm = ExportedFile.decodeAudio(h.ctx, out)
        assertEquals(48_000, pcm.sampleRate)
        assertEquals(2, pcm.channels)
        Log.i(EXPORT_TEST_TAG, "$name: AAC ${pcm.sampleRate} Hz x${pcm.channels}, ${pcm.durationUs} us of audio for $videoUs us of video, peak ${pcm.peak()}, rms ${pcm.rmsDb()} dBFS")
        assertTrue("$name: silent (peak ${pcm.peak()})", pcm.peak() < 0.001f)
        // Measured on the API 35 emulator (2026-10-14): the AAC track ends 41-49 ms before the video
        // (ffprobe 1.950708 s for 2.000 s; 4.958708 s for 5.000 s): Transformer's audio tail, reported to
        // the Mac for QA-11. The A/V offset inside the export is checked by avOffsetWithinOneFrameAnd20ms.
        assertTrue("$name: audio covers the video (${pcm.durationUs} us vs $videoUs us)", pcm.durationUs >= videoUs - 100_000)
    }

    private fun assertOnGrid(out: File, fps: Int, frames: Int, name: String) {
        val pts = ExportedFile.videoPts(out)
        assertEquals("$name frame count", frames, pts.size)
        val g = FrameGrid.of(fps)
        for (k in 0 until frames) assertTrue("$name pts of frame $k: ${pts[k]}", abs(pts[k] - g.platformTimeOfFrame(k.toLong())) <= 100)
    }

    // ---- conformance (V-N13) ----

    /**
     * Conformance of one codec at [w] x [h] (the emulator's software HEVC encoder takes at most
     * 512x512, so HEVC is checked at 512x288).
     */
    private fun conformance(codec: VideoCodecMsg, mime: String, entry: String, notEntry: String?, w: Int = 1280, h0: Int = 720) {
        val h = harness("conf_${codec.name}")
        val plan = counterPlan(w = w, h = h0)
        val s = settings(w = w, h = h0, codec = codec, videoBitrate = if (w >= 1280) 5_000_000 else 1_500_000)
        val pre = h.preflight(plan, s)
        assertTrue(pre.ok)
        val ranked = h.coordinator.selector.ranked(mime).map { "${it.name}(hw=${it.isHardware})" }
        Log.i(EXPORT_TEST_TAG, "$codec encoders on this emulator, ranked: $ranked; preflight warnings ${pre.warnings.map { it.code }}")
        val o = h.export(plan, s, "conf_${codec.name}")
        val r = o.requireResult()
        val out = File(r.path)
        assertEquals(h.output("conf_${codec.name}").absolutePath, r.path)
        assertEquals(out.length(), r.bytes)
        assertEquals(plan.durUs, r.durationUs)
        assertTrue("encoder recorded", r.videoEncoderName.isNotEmpty())
        // The software flag of the preflight matches the encoder that actually ran.
        assertEquals(!r.hardwareEncoder, pre.warnings.any { it.code == ExportWarnings.SOFTWARE_ENCODER })
        assertEquals(!r.hardwareEncoder, o.warnings.contains(ExportWarnings.SOFTWARE_ENCODER))
        val video = ExportedFile.video(out)
        assertEquals(mime, video.mime)
        assertEquals(w, video.format.getInteger(MediaFormat.KEY_WIDTH))
        assertEquals(h0, video.format.getInteger(MediaFormat.KEY_HEIGHT))
        assertEquals(0, ExportedFile.rotation(out))
        assertTrue("$entry sample entry", ExportedFile.hasFourcc(out, entry))
        if (notEntry != null) assertFalse("no $notEntry sample entry", ExportedFile.hasFourcc(out, notEntry))
        assertTrue("MP4 brand", ExportedFile.hasFourcc(out, "ftyp"))
        assertOnGrid(out, 30, 60, codec.name)
        assertSilentAac48kStereo(h, out, plan.durUs, codec.name)
        val kbps = r.bytes * 8 / (plan.durUs / 1000)
        Log.i(EXPORT_TEST_TAG, "$codec conformance ${w}x$h0: ${r.videoEncoderName} hardware=${r.hardwareEncoder}, ${r.bytes} bytes (~$kbps kb/s total for ${s.videoBitrate / 1000} kb/s requested), audio track ${ExportedFile.audio(out).format.getLong(MediaFormat.KEY_DURATION)} us, video track ${video.format.getLong(MediaFormat.KEY_DURATION)} us, ${o.wallMs} ms wall (emulator)")
        h.app.getExternalFilesDir(null)?.let { dir -> out.copyTo(File(dir, "and11_conf_${codec.name}.mp4"), overwrite = true) }
        // Progress: preparing first, finishing at 1.0 last.
        assertEquals(ExportPhaseMsg.PREPARING, o.progress.first().phase)
        assertEquals(ExportPhaseMsg.FINISHING, o.progress.last().phase)
        assertEquals(1.0, o.progress.last().fraction, 0.0)
        assertEquals(60L, o.progress.last().framesTotal)
        assertEquals(emptyList<Any>(), h.activeJobs())
    }

    @Test
    fun h264Conformance() = conformance(VideoCodecMsg.H264, "video/avc", "avc1", null)

    @Test
    fun hevcConformanceWritesHvc1_vn13() = conformance(VideoCodecMsg.HEVC, "video/hevc", "hvc1", "hev1", w = 512, h0 = 288)

    @Test
    fun hevcAboveEveryHevcEncoderSizeIsWrittenAsH264WithTheWarning() {
        val h = harness("hevc_fallback")
        val sel = h.coordinator.selector
        val tooLarge = sel.ranked("video/hevc").none { it.supportsSize(1280, 720) || it.supportsSize(720, 1280) }
        org.junit.Assume.assumeTrue("needs a device whose HEVC encoders all refuse 1280x720 (the x86_64 emulator: max 512x512)", tooLarge)
        val plan = counterPlan()
        val pre = h.preflight(plan, settings(codec = VideoCodecMsg.HEVC))
        assertTrue(pre.ok)
        assertTrue(pre.warnings.any { it.code == ExportWarnings.HEVC_UNAVAILABLE })
        val o = h.export(plan, settings(codec = VideoCodecMsg.HEVC), "hevc_fallback")
        assertEquals("video/avc", ExportedFile.video(File(o.requireResult().path)).mime)
        assertTrue(o.warnings.contains(ExportWarnings.HEVC_UNAVAILABLE))
    }

    // ---- V-N24 ----

    @Test
    fun noAudioAllMutedAndImagesTextOnlyGetSilentAac48kStereo_vn24() {
        val h = harness("vn24")
        val g = FrameGrid.of(30)
        val frames = 60L
        val dur = g.timeOfFrame(frames)

        // (a) No audio at all.
        val noAudio = counterPlan(frames = frames)

        // (b) Everything muted: two audio segments (a WAV tone and the video's own AAC) at gain 0.
        val muted = counterPlan(
            frames = frames,
            audio = listOf(
                AudioSeg(id = "it_own#a", asset = "md_own", t0 = 0, t1 = dur, map = listOf(MapSegment(0, dur, 0, dur)), gain = Keyframes.of(0L to 0.0)),
                AudioSeg(id = "it_tone#a", asset = "md_tone", t0 = 0, t1 = dur, map = listOf(MapSegment(0, dur, 0, dur)), gain = Keyframes.of(0L to 0.0)),
            ),
            extraAssets = mapOf(
                "md_tone" to PlanAsset(PlanAssetKind.AUDIO, ExportPlans.media("tone_1khz.wav"), fp = "tone", durUs = 10_000_000),
                "md_own" to PlanAsset(PlanAssetKind.VIDEO, ExportPlans.media("tone_under_video.mp4"), fp = "tuv", w = 1280, h = 720, durUs = 8_000_000, hasAudio = true),
            ),
        )

        // (c) Images and text only: an image, a solid and a text sprite.
        val imagesOnly = validated(
            RenderPlan(
                rev = 1, target = PlanTarget.EXPORT, canvas = PlanCanvas(1280, 720, 30), durUs = dur,
                assets = mapOf(
                    "im_alpha" to PlanAsset(PlanAssetKind.IMAGE, ExportPlans.media("alpha.png"), fp = "alpha", w = 512, h = 512),
                    "sp_text" to PlanAsset(PlanAssetKind.SPRITE, ExportPlans.sprite("text_box_stroke_shadow.vsprite"), fp = "text", sw = 403, sh = 177, sscale = 1.0),
                ),
                layers = listOf(
                    PlanLayer(id = "it_solid#v", z = 5, t0 = 0, t1 = dur, kind = PlanLayerKind.SOLID, color = 0xFF3366CC.toInt(), base = PlanSize(640.0, 360.0)),
                    PlanLayer(id = "it_image#v", z = 10, t0 = 0, t1 = dur, kind = PlanLayerKind.IMAGE, asset = "im_alpha", base = PlanSize(512.0, 512.0)),
                    PlanLayer(id = "it_text#v", z = 20010, t0 = 0, t1 = g.timeOfFrame(45), kind = PlanLayerKind.SPRITE, asset = "sp_text", base = PlanSize(403.0, 177.0)),
                ).sortedWith(PlanValidator::compareLayers),
                audio = emptyList(),
            ),
        )

        for ((name, plan) in listOf("no_audio" to noAudio, "all_muted" to muted, "images_text_only" to imagesOnly)) {
            val o = h.export(plan, settings(), "vn24_$name")
            val out = File(o.requireResult().path)
            assertOnGrid(out, 30, frames.toInt(), name)
            assertSilentAac48kStereo(h, out, dur, name)
        }
    }

    // ---- grid ----

    @Test
    fun gridFps30ExportedAt24FpsShowsTheRuleFrameOnEveryOutputFrame() {
        val h = harness("grid30at24")
        h.softwareDecoders()
        val g30 = FrameGrid.of(30)
        val g24 = FrameGrid.of(24)
        // Cut at grid frame 31 (1.0333 s): A shows source frame 0.., B source frame 100..; 2.5 s.
        val cut = 31L
        val end = 75L
        val plan = validated(
            RenderPlan(
                rev = 1, target = PlanTarget.EXPORT, canvas = PlanCanvas(1280, 720, fps = 24, gridFps = 30), durUs = g30.timeOfFrame(end),
                assets = mapOf("md_src" to PlanAsset(PlanAssetKind.VIDEO, ExportPlans.media("frame_counter_720p24.mp4"), fp = "fc24", w = 1280, h = 720, durUs = 10_000_000)),
                layers = listOf(
                    ExportPlans.mediaLayer("it_a#v", 10, 0, g30, 0, cut, 0, 24),
                    ExportPlans.mediaLayer("it_b#v", 10, 0, g30, cut, end, 100, 24),
                ),
                audio = emptyList(),
            ),
        )
        val o = h.export(plan, settings(fps = 24), "grid30at24")
        val out = File(o.requireResult().path)
        val frames = g24.let { FrameGrid.ceilDiv(plan.durUs * 24, 1_000_000L) }.toInt()
        assertEquals(60, frames)
        assertOnGrid(out, 24, frames, "grid30at24")
        fun ruleFrame(s: Long): Long {
            var i = Math.floorDiv((s + 500) * 24, 1_000_000L)
            while (Math.floorDiv(2 * (i + 1) * 1_000_000L + 24, 48L) <= s + 500) i++
            while (i > 0 && Math.floorDiv(2 * i * 1_000_000L + 24, 48L) > s + 500) i--
            return i
        }
        fun expected(k: Long): Long {
            val t = g24.timeOfFrame(k)
            val layer = plan.layers.first { it.covers(t) }
            return ruleFrame(layer.map.first().s0 + (t - layer.t0))
        }
        val codes = OutputReader.barcodes(out, frames)
        val wrong = (0 until frames).filter { codes[it]?.toLong() != expected(it.toLong()) }
        Log.i(EXPORT_TEST_TAG, "grid30at24: ${frames - wrong.size}/$frames frames exact (emulator); wrong ${wrong.map { "$it:${codes[it]}!=${expected(it.toLong())}" }}")
        assertEquals("wrong frames", emptyList<Int>(), wrong)
    }

    // ---- A/V offset ----

    @Test
    fun avOffsetWithinOneFrameAnd20ms() {
        val h = harness("avsync")
        h.softwareDecoders()
        val g = FrameGrid.of(30)
        val frames = 150L
        val dur = g.timeOfFrame(frames)
        val plan = validated(
            RenderPlan(
                rev = 1, target = PlanTarget.EXPORT, canvas = PlanCanvas(1280, 720, 30), durUs = dur,
                assets = mapOf("md_clap" to PlanAsset(PlanAssetKind.VIDEO, ExportPlans.media("clap_flash_av.mp4"), fp = "clap", w = 1280, h = 720, durUs = 6_000_000, hasAudio = true)),
                layers = listOf(ExportPlans.mediaLayer("it_clap#v", 10, 0, g, 0, frames, 0, 30, asset = "md_clap")),
                audio = listOf(AudioSeg(id = "it_clap#a", asset = "md_clap", t0 = 0, t1 = dur, map = listOf(MapSegment(0, dur, 0, dur)), gain = Keyframes.of(0L to 1.0))),
            ),
        )
        val o = h.export(plan, settings(), "avsync")
        val out = File(o.requireResult().path)
        val pts = ExportedFile.videoPts(out)
        val luma = ExportedFile.meanLuma(out, pts.size)
        val flashes = luma.indices.filter { luma[it] > 180 }
        assertEquals("flash frames", listOf(30, 75, 120), flashes)
        val pcm = ExportedFile.decodeAudio(h.ctx, out)
        Log.i(EXPORT_TEST_TAG, "avsync: ${pcm.durationUs} us of decoded audio for ${plan.durUs} us of video; audio track ${ExportedFile.audio(out).format.getLong(MediaFormat.KEY_DURATION)} us (emulator)")
        h.app.getExternalFilesDir(null)?.let { dir -> out.copyTo(File(dir, "and11_avsync.mp4"), overwrite = true) }
        val offsets = flashes.map { k ->
            val video = pts[k]
            val audio = pcm.onsetUs(video - 200_000)
            assertNotNull("click near frame $k", audio)
            audio!! - video
        }
        Log.i(EXPORT_TEST_TAG, "A/V offsets (audio onset - flash frame pts, us, emulator): $offsets")
        for (d in offsets) {
            assertTrue("offset $d us > 20 ms", abs(d) <= 20_000)
            assertTrue("offset $d us > 1 frame", abs(d) <= g.timeOfFrame(1))
        }
    }

    // ---- portrait retry (ARCH §14.1) ----

    /** Wraps the encoder factory and refuses video formats matching [refuse] (an injected device refusal). */
    private class RefusingEncoderFactory(private val base: Codec.EncoderFactory, private val refuse: (Format) -> Boolean) : Codec.EncoderFactory {
        val refused = AtomicInteger()
        val accepted = AtomicInteger()

        override fun createForAudioEncoding(format: Format, logSessionId: LogSessionId?): Codec = base.createForAudioEncoding(format, logSessionId)

        override fun createForVideoEncoding(format: Format, logSessionId: LogSessionId?): Codec {
            if (refuse(format)) {
                refused.incrementAndGet()
                throw ExportException.createForCodec(
                    IllegalArgumentException("injected refusal of ${format.width}x${format.height}"),
                    ExportException.ERROR_CODE_ENCODER_INIT_FAILED,
                    ExportException.CodecInfo(format.toString(), true, false, "injected"),
                )
            }
            accepted.incrementAndGet()
            return base.createForVideoEncoding(format, logSessionId)
        }

        override fun isVideoFormatSupported(format: Format): Boolean = base.isVideoFormatSupported(format)

        override fun audioNeedsEncoding(): Boolean = base.audioNeedsEncoding()

        override fun videoNeedsEncoding(): Boolean = base.videoNeedsEncoding()
    }

    private fun portraitPlan(): RenderPlan {
        val g = FrameGrid.of(24)
        return validated(
            RenderPlan(
                rev = 1, target = PlanTarget.EXPORT, canvas = PlanCanvas(720, 1280, 24), durUs = g.timeOfFrame(48),
                assets = mapOf("md_src" to PlanAsset(PlanAssetKind.VIDEO, ExportPlans.media("frame_counter_720p24.mp4"), fp = "fc24", w = 1280, h = 720, durUs = 10_000_000)),
                layers = listOf(ExportPlans.mediaLayer("it_v#v", 10, 0, g, 0, 48, 0, 24, base = PlanSize(720.0, 405.0))),
                audio = emptyList(),
            ),
        )
    }

    @Test
    fun refusedPortraitIsRetriedLandscapeWithRotation() {
        val h = harness("portrait_retry")
        var factory: RefusingEncoderFactory? = null
        h.coordinator.encoderFactoryDecorator = { base -> RefusingEncoderFactory(base) { it.height > it.width }.also { factory = it } }
        val o = h.export(portraitPlan(), settings(w = 720, h = 1280, fps = 24), "portrait_retry")
        val out = File(o.requireResult().path)
        assertTrue("portraitRetried warning", o.warnings.contains(ExportWarnings.PORTRAIT_RETRIED))
        assertEquals("the last factory accepted the landscape buffer", 1, factory!!.accepted.get())
        val video = ExportedFile.video(out)
        val w = video.format.getInteger(MediaFormat.KEY_WIDTH)
        val ht = video.format.getInteger(MediaFormat.KEY_HEIGHT)
        val rotation = ExportedFile.rotation(out)
        Log.i(EXPORT_TEST_TAG, "portrait retry: coded ${w}x$ht, rotation $rotation (emulator)")
        assertEquals("coded landscape", 1280 to 720, w to ht)
        assertTrue("rotation metadata $rotation", rotation == 90 || rotation == 270)
        assertOnGrid(out, 24, 48, "portrait_retry")
        assertSilentAac48kStereo(h, out, portraitPlan().durUs, "portrait_retry")
    }

    @Test
    fun portraitRefusedBothWaysFailsWithEncoderSizeLimit() {
        val h = harness("portrait_refused")
        val factories = ArrayList<RefusingEncoderFactory>()
        h.coordinator.encoderFactoryDecorator = { base -> RefusingEncoderFactory(base) { true }.also { factories += it } }
        val out = h.output("portrait_refused")
        val o = h.export(portraitPlan(), settings(w = 720, h = 1280, fps = 24), "portrait_refused")
        assertNull(o.result)
        assertEquals(EngineErrorCode.encoderSizeLimit.name, o.failure!!.code)
        assertEquals("first attempt and one retry", 2, factories.sumOf { it.refused.get() })
        assertTrue(o.warnings.contains(ExportWarnings.PORTRAIT_RETRIED))
        assertFalse("no partial file", out.exists())
        assertEquals(emptyList<Any>(), h.activeJobs())
    }

    // ---- cancel, errors, records ----

    @Test
    fun cancelDeletesThePartialOutput() {
        val h = harness("cancel")
        val plan = counterPlan(w = 1920, h = 1080, frames = 240)
        val out = h.output("cancel")
        val id = h.start(plan, settings(w = 1920, h = 1080), out)
        val deadline = System.currentTimeMillis() + 120_000
        while (System.currentTimeMillis() < deadline && h.progress(id).none { it.phase == ExportPhaseMsg.RENDERING && it.fraction > 0.05 }) Thread.sleep(20)
        val reached = h.progress(id).last()
        assertEquals("export was rendering before the cancel", ExportPhaseMsg.RENDERING, reached.phase)
        h.cancel(id)
        val o = h.await(id)
        assertEquals(EngineErrorCode.cancelled.name, o.failure!!.code)
        Thread.sleep(500)
        assertFalse("partial output deleted", out.exists())
        assertFalse("work dir of the job deleted", File(h.paths.work, "export-$id").exists())
        assertEquals(emptyList<Any>(), h.activeJobs())
        Log.i(EXPORT_TEST_TAG, "cancel at ${(reached.fraction * 100).toInt()}% (emulator)")
    }

    @Test
    fun missingSourceFailsWithMediaOffline() {
        val h = harness("offline")
        val g = FrameGrid.of(30)
        val plan = validated(
            RenderPlan(
                rev = 1, target = PlanTarget.EXPORT, canvas = PlanCanvas(1280, 720, 30), durUs = g.timeOfFrame(30),
                assets = mapOf("md_src" to PlanAsset(PlanAssetKind.VIDEO, "file://" + File(h.root, "missing.mp4").absolutePath, fp = "gone", w = 1280, h = 720, durUs = 1_000_000)),
                layers = listOf(ExportPlans.mediaLayer("it_v#v", 10, 0, g, 0, 30, 0, 30)),
                audio = emptyList(),
            ),
        )
        val out = h.output("offline")
        val o = h.export(plan, settings(), "offline")
        assertEquals(EngineErrorCode.mediaOffline.name, o.failure!!.code)
        assertEquals("it_v#v", o.failure!!.itemId)
        assertFalse(out.exists())
        assertEquals(emptyList<Any>(), h.activeJobs())
    }

    @Test
    fun completionWithoutADartListenerKeepsTheFileAndAOneShotRecord_d39() {
        val h = harness("detached")
        val plan = counterPlan(frames = 30)
        val out = h.output("detached")
        val id = h.start(plan, settings(), out, DetachedHandoffMsg.KEEP_FOR_LATER)
        h.detach() // the Dart listener goes away mid-export
        val deadline = System.currentTimeMillis() + 300_000
        while (System.currentTimeMillis() < deadline && h.coordinator.job(id) != null) Thread.sleep(50)
        assertNull("job finished", h.coordinator.job(id))
        val record = h.activeJobs().single()
        assertEquals(ExportJobStateKindMsg.COMPLETED_WHILE_DETACHED, record.state)
        assertEquals(out.absolutePath, record.result!!.path)
        assertTrue(out.isFile)
        assertTrue(WorkExemptions.live(h.paths).contains(out.name))
        // The next launch (a new engine context on the same roots) wipes work/ but keeps the file.
        val relaunched = EngineContext(h.app, EngineThreads.android())
        relaunched.installRoots(h.paths)
        assertTrue("survives the work/ wipe", out.isFile)
        // Offered until consumed; then the exemption ends.
        assertEquals(1, h.activeJobs().size)
        h.consume(id)
        assertEquals(emptyList<Any>(), h.activeJobs())
        assertFalse(WorkExemptions.live(h.paths).contains(out.name))
        for (lane in relaunched.threads.started()) lane.quit()
    }

    @Test
    fun aRecordOfADeadProcessIsReportedInterruptedOnce() {
        val h = harness("dead_record")
        ActiveExportStore(File(h.paths.cacheRoot, ActiveExportStore.FILE_NAME), "a-process-that-died")
            .begin("ex_dead", h.output("dead"), settings(), DetachedHandoffMsg.SAVE_TO_GALLERY)
        assertEquals(listOf("ex_dead" to ExportJobStateKindMsg.INTERRUPTED), h.activeJobs().map { it.jobId to it.state })
        assertEquals(1, h.activeJobs().size)
        h.consume("ex_dead")
        assertEquals(emptyList<Any>(), h.activeJobs())
    }
}
