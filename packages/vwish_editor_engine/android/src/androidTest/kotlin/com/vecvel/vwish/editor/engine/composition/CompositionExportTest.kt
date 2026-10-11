@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-08

// End-to-end Transformer exports of mapped compositions on the emulator (ARCH §13.3, D-35, D-37,
// D-38; AND-01 §6.7). No AND-09 effects are involved: every source is canvas-size, so the
// compositor's plain blend shows exactly which layer the gating chose.
// - Grid cuts at 24, 25, 30, 48 and 60 fps (frame_counter_720p24/25/48/60.mp4 and
//   clap_flash_av.mp4, barcode = frame number; B-pyramid sources): cuts at k ≡ 1, 2 (mod 3), a top
//   slot with transparent-image gaps, rule-frame clip starts, a 2× item capped at the project fps;
//   output frames at P(k) and the decoded output barcode of EVERY frame equals the plan's rule
//   frame (ARCH §11.5). Exports decode with software decoders first (CompositionTestSupport
//   header: the emulator's default H.264 decoder drops B-pyramid frames even in a plain
//   transcode); [plainTranscodeControl] keeps that measurement repeatable.
// - A plan without audio exports an AAC track (clock band trackTypes {VIDEO, AUDIO}, D-38).
// - Gain: a 2× audio item starting at 0.5 s (after a sequence gap, clipped from 1 s of its source)
//   with a gain step at 1.25 s (timeline) is quiet before the step and loud after it, which pins
//   GainProcessor's sample positions to the item start after the speed change
//   (KeyframedGainProvider.originForItem).
// - Audio stream (ARCH §11.2 AudioSeg.stream): a two-audio-track MP4 muxed on the device from two
//   ENG-05 fixtures (track 0: tone_under_video.mp4's 1 kHz AAC; track 1: sample_h264_aac.mkv's
//   440 Hz AAC; MediaMuxer stream copy, no re-encode) exports the tone of the stream the segment
//   names, through AudioStreamAssetLoaderFactory with the production decoder factory.

package com.vecvel.vwish.editor.engine.composition

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Contrast
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.vwish.editor.engine.harness.FixtureTree
import com.vecvel.vwish.editor.engine.harness.TestFixtures
import com.vecvel.vwish.editor.engine.plan.AudioSeg
import com.vecvel.vwish.editor.engine.plan.FrameGrid
import com.vecvel.vwish.editor.engine.plan.Keyframes
import com.vecvel.vwish.editor.engine.plan.MapSegment
import com.vecvel.vwish.editor.engine.plan.ParamSnapshot
import com.vecvel.vwish.editor.engine.plan.PlanAsset
import com.vecvel.vwish.editor.engine.plan.PlanAssetKind
import com.vecvel.vwish.editor.engine.plan.PlanCanvas
import com.vecvel.vwish.editor.engine.plan.PlanLayer
import com.vecvel.vwish.editor.engine.plan.PlanLayerKind
import com.vecvel.vwish.editor.engine.plan.PlanSize
import com.vecvel.vwish.editor.engine.plan.PlanTarget
import com.vecvel.vwish.editor.engine.plan.PlanValidator
import com.vecvel.vwish.editor.engine.plan.RenderPlan
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.log10

@RunWith(AndroidJUnit4::class)
class CompositionExportTest {
    private val ctx = TestFixtures.targetContext
    private val outDir = File(ctx.cacheDir, "and08_exports")
    private val images = PngCompositionImages(File(ctx.cacheDir, "and08_images"))

    @After
    fun cleanUp() {
        outDir.deleteRecursively()
    }

    private fun uriOf(media: String): String = "file://" + TestFixtures.copyToCache(FixtureTree.ENGINE, "media/$media").absolutePath

    private fun media(id: String, z: Int, seq: Int, grid: FrameGrid, k0: Long, k1: Long, sourceFrame: Long, sourceFps: Int, rate: Double = 1.0): PlanLayer {
        val t0 = grid.timeOfFrame(k0)
        val t1 = grid.timeOfFrame(k1)
        // The source time of a source frame: its rational time floored (the rule frame is ≤ s + 500 µs).
        val s0 = Math.floorDiv(sourceFrame * 1_000_000L, sourceFps.toLong())
        return PlanLayer(
            id = id, z = z, seq = seq, t0 = t0, t1 = t1, kind = PlanLayerKind.MEDIA, asset = "md_src",
            map = listOf(MapSegment(t0, t1, s0, s0 + Math.round((t1 - t0) * rate))), base = PlanSize(1280.0, 720.0),
        )
    }

    private fun export(plan: RenderPlan, name: String): Pair<CompositionSpec, File> {
        assertEquals(emptyList<Any>(), PlanValidator.validate(plan))
        val timeline = ExtractorSourceTimeline(ctx)
        val spec = timeline.use { CompositionMapper(it).map(plan) }
        val built = Media3Composition.build(spec, images, EffectChainFactory.NONE, AtomicReference(ParamSnapshot.of(plan)))
        val out = File(outDir, "$name.mp4")
        val (_, ms) = ExportRunner.export(built.composition, out)
        Log.i(TAG, "$name: export ${ms} ms (emulator)")
        return spec to out
    }

    /** Exports a grid-cut plan and checks the barcode of every output frame. */
    private fun gridCuts(fps: Int, source: String, sourceFps: Int) {
        val g = FrameGrid.of(fps)
        // Cuts at k ≡ 1 and 2 (mod 3): main A [0, c1), B [c1, c2), C (2x) [c2, n); top D [c1 + 1, c2 + 1).
        val c1 = fps + 1L
        val c2 = 2L * fps + 1
        val n = 3L * fps
        val layers = listOf(
            media("it_a#v", 10, 0, g, 0, c1, 0, sourceFps),
            media("it_b#v", 10, 0, g, c1, c2, 100, sourceFps),
            media("it_c#v", 10, 0, g, c2, n, 20, sourceFps, rate = 2.0),
            media("it_d#v", 10010, 1, g, c1 + 1, c2 + 1, 140, sourceFps),
        ).sortedWith(PlanValidator::compareLayers)
        val plan = RenderPlan(
            rev = 1, target = PlanTarget.EXPORT, canvas = PlanCanvas(1280, 720, fps), durUs = g.timeOfFrame(n),
            assets = mapOf("md_src" to PlanAsset(PlanAssetKind.VIDEO, uriOf(source), fp = "src", w = 1280, h = 720)),
            layers = layers, audio = emptyList(),
        )
        val (spec, out) = export(plan, "grid_cuts_$fps")
        // Output frames sit on the output grid at P(k).
        val pts = OutputReader.videoPts(out)
        assertEquals("frame count", n.toInt(), pts.size)
        for (k in 0 until n.toInt()) assertTrue("pts of frame $k", abs(pts[k] - g.platformTimeOfFrame(k.toLong())) <= 100)
        // D-38: a plan without audio still has an AAC track.
        assertTrue("silent AAC track", OutputReader.trackMimes(out).any { it == "audio/mp4a-latm" })

        val ratio = sourceFps.toDouble() / fps
        fun expected(k: Long): Long = when {
            k in (c1 + 1) until (c2 + 1) -> 140 + Math.round((k - c1 - 1) * ratio)
            k < c1 -> Math.round(k * ratio)
            k < c2 -> 100 + Math.round((k - c1) * ratio)
            else -> 20 + Math.round(2 * (k - c2) * ratio)
        }
        val codes = OutputReader.barcodes(out, n.toInt())
        val wrong = (0 until n.toInt()).filter { codes[it]?.toLong() != expected(it.toLong()) }
        Log.i(TAG, "grid cuts $fps fps: ${n - wrong.size}/$n frames exact; slots ${spec.slotSequences.size}")
        assertTrue(
            "frames with a wrong source frame: " + wrong.joinToString { "k=$it got ${codes[it]} want ${expected(it.toLong())}" },
            wrong.isEmpty(),
        )
    }

    @Test
    fun gridCutExport24fpsEveryFrameExact() = gridCuts(24, "frame_counter_720p24.mp4", 24)

    @Test
    fun gridCutExport25fpsEveryFrameExact() = gridCuts(25, "frame_counter_720p25.mp4", 25)

    @Test
    fun gridCutExport30fpsEveryFrameExact() = gridCuts(30, "clap_flash_av.mp4", 30)

    @Test
    fun gridCutExport48fpsEveryFrameExact() = gridCuts(48, "frame_counter_720p48.mp4", 48)

    @Test
    fun gridCutExport60fpsEveryFrameExact() = gridCuts(60, "frame_counter_720p60.mp4", 60)

    /**
     * Control for the readback path: a plain one-item transcode (no composition; a near-identity
     * contrast effect forces decode + encode) of a B-pyramid source returns every barcode with
     * software decoders. The same transcode with the platform's default decoder is only recorded
     * (on the emulator it loses B-frames, see the support file header).
     */
    @Test
    fun plainTranscodeControl() {
        val uri = uriOf("frame_counter_720p24.mp4")
        val item = EditedMediaItem.Builder(MediaItem.fromUri(uri))
            .setRemoveAudio(true)
            .setEffects(Effects(emptyList(), listOf(Contrast(0.01f))))
            .build()
        val composition = Composition.Builder(EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_VIDEO)).addItem(item).build()).build()
        val frames = 48
        fun run(software: Boolean): List<Int?> {
            val out = File(outDir, "plain_${if (software) "sw" else "default"}.mp4")
            ExportRunner.export(composition, out, softwareDecoders = software)
            return OutputReader.barcodes(out, frames)
        }
        val soft = run(true)
        val default = run(false)
        val missingDefault = (0 until frames).filter { it !in default }
        val decoders = MediaCodecUtil.getDecoderInfos(MimeTypes.VIDEO_H264, false, false).joinToString { "${it.name}${if (it.softwareOnly) "(sw)" else ""}" }
        Log.i(TAG, "plain transcode: H.264 decoders [$decoders]; software-first exact=${soft == (0 until frames).toList()}; default missing frames $missingDefault (emulator)")
        assertEquals("software decoder returns every frame", (0 until frames).toList(), soft)
    }

    @Test
    fun gainProcessorPositionsAreItemRelative() {
        val g = FrameGrid.of(30)
        val t0 = g.timeOfFrame(15) // 0.5 s
        val t1 = g.timeOfFrame(60) // 2.0 s
        val step = 1_250_000L
        val seg = AudioSeg(
            id = "it_tone#a", asset = "md_tone", t0 = t0, t1 = t1,
            map = listOf(MapSegment(t0, t1, 1_000_000, 1_000_000 + 2 * (t1 - t0))), // 2x from 1 s, pitch kept
            gain = Keyframes.of(t0 to 0.25, step to 0.25, (step + 1) to 1.0),
        )
        val plan = RenderPlan(
            rev = 1, target = PlanTarget.EXPORT, canvas = PlanCanvas(1280, 720, 30), durUs = t1,
            assets = mapOf("md_tone" to PlanAsset(PlanAssetKind.AUDIO, uriOf("tone_1khz.wav"), fp = "tone")),
            layers = emptyList(), audio = listOf(seg),
        )
        val (_, out) = export(plan, "gain_positions")
        val pcm = requireNotNull(OutputReader.decodeAudio(out)) { "no audio track" }
        val toneRms = 0.25118864315 / Math.sqrt(2.0) // −12 dBFS peak sine
        fun db(x: Double) = 20 * log10(x)
        val silence = pcm.rms(50_000, 400_000)
        val quiet = pcm.rms(600_000, 1_150_000)
        val loud = pcm.rms(1_350_000, 1_900_000)
        Log.i(TAG, "gain: silence ${"%.5f".format(silence)}, quiet ${"%.2f".format(db(quiet))} dBFS, loud ${"%.2f".format(db(loud))} dBFS")
        assertTrue("silence before the item", silence < 0.003)
        assertEquals("gain 0.25 before the step (−12.04 dB)", db(toneRms * 0.25), db(quiet), 1.5)
        assertEquals("gain 1 after the step", db(toneRms), db(loud), 1.5)
    }

    /**
     * An audio-only MP4 with two AAC tracks, stream-copied from two fixtures: track 0 = the 1 kHz
     * tone of tone_under_video.mp4, track 1 = the 440 Hz tone of sample_h264_aac.mkv.
     */
    private fun twoStreamFile(): File {
        val out = File(outDir, "two_streams.mp4")
        out.parentFile?.mkdirs()
        val muxer = MediaMuxer(out.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val sources = listOf("tone_under_video.mp4", "sample_h264_aac.mkv").map { name ->
            MediaExtractor().apply {
                setDataSource(TestFixtures.copyToCache(FixtureTree.ENGINE, "media/$name").absolutePath)
                val track = (0 until trackCount).first { getTrackFormat(it).getString(MediaFormat.KEY_MIME) == MimeTypes.AUDIO_AAC }
                selectTrack(track)
            }
        }
        try {
            val tracks = sources.map { muxer.addTrack(it.getTrackFormat((0 until it.trackCount).first { t -> it.getTrackFormat(t).getString(MediaFormat.KEY_MIME) == MimeTypes.AUDIO_AAC })) }
            muxer.start()
            val buffer = ByteBuffer.allocate(1 shl 20)
            val info = MediaCodec.BufferInfo()
            for ((source, track) in sources.zip(tracks)) {
                while (true) {
                    val size = source.readSampleData(buffer, 0)
                    if (size < 0) break
                    info.set(0, size, source.sampleTime, if (source.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                    muxer.writeSampleData(track, buffer, info)
                    source.advance()
                }
            }
            muxer.stop()
        } finally {
            muxer.release()
            sources.forEach { it.release() }
        }
        return out
    }

    /** Zero-crossing frequency of channel 0 of [pcm] over [fromUs, toUs). */
    private fun toneHz(pcm: OutputReader.Pcm, fromUs: Long, toUs: Long): Double {
        val a = ((fromUs - pcm.firstPtsUs) * pcm.sampleRate / 1_000_000L).toInt().coerceAtLeast(0)
        val b = ((toUs - pcm.firstPtsUs) * pcm.sampleRate / 1_000_000L).toInt().coerceAtMost(pcm.samples.size / pcm.channels)
        var crossings = 0
        for (i in a + 1 until b) {
            val prev = pcm.samples[(i - 1) * pcm.channels]
            val cur = pcm.samples[i * pcm.channels]
            if ((prev < 0f) != (cur < 0f)) crossings++
        }
        return crossings / 2.0 / ((b - a).toDouble() / pcm.sampleRate)
    }

    @Test
    fun audioSegmentExportsTheStreamItNames() {
        val file = twoStreamFile()
        val g = FrameGrid.of(30)
        val t1 = g.timeOfFrame(60) // 2 s
        fun exportStream(stream: Int): Double {
            val plan = RenderPlan(
                rev = 1, target = PlanTarget.EXPORT, canvas = PlanCanvas(1280, 720, 30), durUs = t1,
                assets = mapOf("md_two" to PlanAsset(PlanAssetKind.AUDIO, "file://" + file.absolutePath, fp = "two")),
                layers = emptyList(),
                audio = listOf(
                    AudioSeg(id = "it_two#a", asset = "md_two", stream = stream, t0 = 0, t1 = t1, map = listOf(MapSegment(0, t1, 0, t1)), gain = Keyframes.of(0L to 1.0)),
                ),
            )
            assertEquals(emptyList<Any>(), PlanValidator.validate(plan))
            val spec = ExtractorSourceTimeline(ctx).use { CompositionMapper(it).map(plan) }
            val built = Media3Composition.build(spec, images, EffectChainFactory.NONE, AtomicReference(ParamSnapshot.of(plan)))
            assertEquals(stream != 0, built.selectsAudioStreams)
            val out = File(outDir, "stream_$stream.mp4")
            ExportRunner.exportWith(built.composition, out) { it.setAssetLoaderFactory(AudioStreamAssetLoaderFactory(ctx)) }
            val pcm = requireNotNull(OutputReader.decodeAudio(out)) { "no audio track" }
            val hz = toneHz(pcm, 300_000, 1_700_000)
            Log.i(TAG, "audio stream $stream: ${"%.1f".format(hz)} Hz")
            return hz
        }
        assertEquals("stream 0 is the 1 kHz track", 1000.0, exportStream(0), 25.0)
        assertEquals("stream 1 is the 440 Hz track", 440.0, exportStream(1), 15.0)
    }

    private companion object {
        const val TAG = "AND08Export"
    }
}
