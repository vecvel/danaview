// OWNER: AND-07
//
// Reverse renditions on the emulator (BUILD_PLAN AND-07; ARCH §15 'Reverse', 'Reverse preflight'),
// with the ENG-05 fixtures:
// - frame_counter_1080p30 (whole 8 s, 2 s chunks): barcodes strictly decreasing 239..0, every
//   output PTS the mirror of its source frame (E - frame end, ±1 ms), video duration 8 s ±1 frame;
//   the work directory's peak (polled every 10 ms) never exceeds one chunk; the process memory
//   delta (PSS, Java and native heap, sampled during a second, warm run) is recorded and bounded
//   by the IOS-07 1080p figure (40 MB);
// - frame_counter_720p24 partial range [1.51 s, 4.25 s) in 0.5 s chunks (chunk ends inside GOPs:
//   the B-frame clip-end extension): barcodes 101..36, duration ±1 frame;
// - clap_flash_av (AAC with priming in the edit list): every click lands at its mirrored time
//   within ±20 ms, the flash frames at their mirrored frames, the output carries AAC;
// - vfr_720p: every frame keeps its own duration, mirrored;
// - rotated_90.mov: displayed upright (portrait) in reverse order;
// - preflight: a range over 10 min is refused with the `reverseRange` token, low free space with
//   diskFull; neither leaves work files;
// - cancel (direct and through the JobRegistry, mid-job): `cancelled`, no work directory, no
//   `.part`, no output.
// The intermediate Transformer runs software decoders first (ReverseDecoders: the goldfish decoder
// drops a B-frame); `defaultDecodersStillReverse` runs the production choice and records what it
// delivers. Every timing and memory number is an emulator measurement.

package com.vecvel.danaview.editor.engine.reverse

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.media.ReverseMath
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.GeneratedAssetMsg
import com.vecvel.danaview.editor.engine.pigeon.JobKindMsg
import com.vecvel.danaview.editor.engine.pigeon.JobPriorityMsg
import com.vecvel.danaview.editor.engine.pigeon.JobRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.ResolvedMediaMsg
import com.vecvel.danaview.editor.engine.support.FrameBarcode
import com.vecvel.danaview.editor.engine.support.decode
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class ReverseJobTest {
    companion object {
        private const val TAG = "DanaviewReverseTest"
        private lateinit var engine: ReverseEngine

        @BeforeClass
        @JvmStatic
        fun setUp() {
            engine = ReverseEngine("reverse-test")
            engine.ctx.reverse.assetLoaderFactory = ReverseDecoders::softwareFirst
        }

        @AfterClass
        @JvmStatic
        fun tearDown() = engine.close()
    }

    private val intermediateBytes = ArrayList<Long>()

    private fun request(fixture: String, startUs: Long, endUs: Long, name: String, priority: JobPriorityMsg = JobPriorityMsg.INTERACTIVE) = JobRequestMsg(
        kind = JobKindMsg.REVERSE,
        media = ResolvedMediaMsg(uri = ReverseFixtures.file(fixture).absolutePath, fingerprint = "fp-$fixture", isProxy = false),
        priority = priority,
        sourceStartUs = startUs,
        sourceEndUs = endUs,
        outputPath = engine.output(name).absolutePath,
    )

    private fun reverse(
        fixture: String,
        startUs: Long,
        endUs: Long,
        name: String,
        chunkUs: Long = ReverseMath.DEFAULT_CHUNK_US,
        control: ReverseControl = ReverseControl(),
    ): GeneratedAssetMsg {
        val job = engine.ctx.reverse
        job.chunkDurationUs = chunkUs
        intermediateBytes.clear()
        job.onWorkSample = { stage, bytes -> if (stage == "intermediate" || stage == "wav") synchronized(intermediateBytes) { intermediateBytes += bytes } }
        val started = System.nanoTime()
        try {
            val asset = job.run(request(fixture, startUs, endUs, name), control)
            Log.i(TAG, "$name: ${(endUs - startUs) / 1000} ms of source reversed in ${(System.nanoTime() - started) / 1_000_000} ms [emulator]")
            assertEquals(engine.output(name).absolutePath, asset.path)
            assertTrue(File(asset.path).isFile)
            assertEquals(File(asset.path).length(), asset.sizeBytes)
            assertFalse(File(asset.path + ".part").exists())
            assertEquals(1.0, control.lastProgress, 0.0)
            assertEquals("the work directory is gone", emptyList<String>(), engine.workLeftovers())
            return asset
        } finally {
            job.onWorkSample = null
            job.chunkDurationUs = ReverseMath.DEFAULT_CHUNK_US
        }
    }

    private fun assertStrictlyDecreasing(barcodes: List<Int?>, first: Int, last: Int) {
        assertTrue("every frame readable: $barcodes", barcodes.all { it != null })
        for (i in 1 until barcodes.size) assertTrue("strictly decreasing at $i: ${barcodes[i - 1]} -> ${barcodes[i]}", barcodes[i]!! < barcodes[i - 1]!!)
        assertEquals(first, barcodes.first())
        assertEquals(last, barcodes.last())
    }

    @Test
    fun reverses1080p30WithMirroredTimesInBoundedWork() {
        // A first (warm-up) run loads the codecs and Transformer classes; the measured run is the second.
        reverse("frame_counter_1080p30.mp4", 0, 2_000_000, "warm")
        val samplers = Samplers(engine.paths.work)
        val asset = try {
            reverse("frame_counter_1080p30.mp4", 0, 8_000_000, "c30")
        } finally {
            samplers.close()
        }
        assertEquals(8_000_000L, asset.durationUs)
        val clip = Clip(File(asset.path))
        assertEquals(240, clip.videoPts.size)
        assertStrictlyDecreasing(clip.barcodes(), 239, 0)
        // Output frame j is source frame 239 - j at 8 s - end(239 - j).
        for (j in clip.videoPts.indices) {
            val want = 8_000_000L - ReverseFixtures.pts(240 - j, 30)
            assertTrue("frame $j at ${clip.videoPts[j]} µs, want $want", abs(clip.videoPts[j] - want) <= 1_000)
        }
        assertTrue("duration ${clip.videoDurationUs}", abs(clip.videoDurationUs - 8_000_000) <= 33_334)
        assertEquals(1920, clip.width)
        assertEquals(1080, clip.height)
        // Work: one chunk at a time.
        val oneChunk = synchronized(intermediateBytes) { intermediateBytes.maxOrNull() ?: 0L }
        Log.i(TAG, "work peak ${samplers.peakWorkBytes.get() / 1024} KiB, largest chunk ${oneChunk / 1024} KiB, files at once ${samplers.peakWorkFiles.get()}, output ${asset.sizeBytes / 1024} KiB [emulator]")
        assertTrue(oneChunk > 0)
        assertTrue("peak work ${samplers.peakWorkBytes.get()} <= one chunk $oneChunk", samplers.peakWorkBytes.get() <= oneChunk)
        assertTrue(samplers.peakWorkFiles.get() <= 1)
        // Memory (emulator; GPU memory is not visible on the emulator).
        Log.i(TAG, "memory delta at 1080p [emulator]: PSS %.1f MB, native heap %.1f MB, Java heap %.1f MB".format(samplers.pssDeltaMb, samplers.nativeDeltaMb, samplers.javaDeltaMb))
        assertTrue("PSS delta ${samplers.pssDeltaMb} MB <= 40 MB (IOS-07 1080p bound)", samplers.pssDeltaMb <= 40.0)
    }

    @Test
    fun partialRangeWithBFramesInShortChunks() {
        val asset = reverse("frame_counter_720p24.mp4", 1_510_000, 4_250_000, "c24", chunkUs = 500_000)
        val clip = Clip(File(asset.path))
        assertEquals(66, clip.videoPts.size)
        assertStrictlyDecreasing(clip.barcodes(), 101, 36)
        assertTrue("duration ${clip.videoDurationUs}", abs(clip.videoDurationUs - 2_740_000) <= 41_667)
        assertEquals(0L, clip.videoPts.first())
    }

    @Test
    fun clicksAndFlashesAreMirrored() {
        val source = ReverseFixtures.file("clap_flash_av.mp4")
        val asset = reverse("clap_flash_av.mp4", 0, 6_000_000, "clap")
        val clip = Clip(File(asset.path))
        assertEquals("audio/mp4a-latm", clip.audioMime)
        val barcodes = clip.barcodes()
        assertStrictlyDecreasing(barcodes, 179, 0)
        for (flash in intArrayOf(30, 75, 120)) assertEquals(flash, barcodes[179 - flash])
        val sourceClicks = Pcm.of(engine.ctx, source).bursts()
        val out = Pcm.of(engine.ctx, File(asset.path))
        val outClicks = out.bursts()
        Log.i(TAG, "clicks source $sourceClicks, reversed $outClicks (µs) [emulator]")
        assertEquals(3, sourceClicks.size)
        assertEquals(3, outClicks.size)
        // Source burst [on, off] -> reversed [E - off, E - on].
        for ((i, src) in sourceClicks.withIndex()) {
            val got = outClicks[outClicks.size - 1 - i]
            val wantOn = 6_000_000 - src.second
            val wantOff = 6_000_000 - src.first
            assertTrue("click $i onset ${got.first} want $wantOn", abs(got.first - wantOn) <= 20_000)
            assertTrue("click $i end ${got.second} want $wantOff", abs(got.second - wantOff) <= 20_000)
        }
        assertTrue("audio covers the range: ${out.durationUs}", abs(out.durationUs - 6_000_000) <= 50_000)
    }

    @Test
    fun audioOfAPartialRangeIsMirrored() {
        // [0.5 s, 4.5 s): the clicks at 1.0, 2.5 and 4.0 s land at 4.5 s - their ends.
        val source = ReverseFixtures.file("clap_flash_av.mp4")
        val asset = reverse("clap_flash_av.mp4", 500_000, 4_500_000, "clap_part", chunkUs = 700_000)
        val sourceClicks = Pcm.of(engine.ctx, source).bursts()
        val outClicks = Pcm.of(engine.ctx, File(asset.path)).bursts()
        assertEquals(3, outClicks.size)
        for ((i, src) in sourceClicks.withIndex()) {
            val got = outClicks[outClicks.size - 1 - i]
            assertTrue("click $i onset ${got.first} want ${4_500_000 - src.second}", abs(got.first - (4_500_000 - src.second)) <= 20_000)
        }
    }

    @Test
    fun vfrDurationsAreMirrored() {
        val ticks = ReverseFixtures.vfrTicks()
        val endUs = ReverseFixtures.vfrEndTick() * 1_000_000 / 600
        val asset = reverse("vfr_720p.mp4", 0, endUs, "vfr")
        val clip = Clip(File(asset.path))
        val n = ticks.size
        assertEquals(n, clip.videoPts.size)
        assertStrictlyDecreasing(clip.barcodes(), n - 1, 0)
        // Output frame j is source frame n - 1 - j and lasts as long.
        for (j in 0 until n - 1) {
            val src = n - 1 - j
            val sourceDuration = ((if (src + 1 < n) ticks[src + 1] else ReverseFixtures.vfrEndTick()) - ticks[src]) * 1_000_000 / 600
            val outputDuration = clip.videoPts[j + 1] - clip.videoPts[j]
            assertTrue("frame $src: $outputDuration vs $sourceDuration", abs(outputDuration - sourceDuration) <= 1_000)
        }
    }

    @Test
    fun rotatedSourceStaysUpright() {
        val asset = reverse("rotated_90.mov", 0, 3_000_000, "rotated")
        val clip = Clip(File(asset.path))
        assertEquals(90, clip.videoPts.size)
        val displayW = if (clip.rotation % 180 != 0) clip.height else clip.width
        val displayH = if (clip.rotation % 180 != 0) clip.width else clip.height
        assertEquals(720, displayW)
        assertEquals(1280, displayH)
        val first = clip.frameAt(0)
        val last = clip.frameAt(89)
        assertEquals(89, FrameBarcode.decode(first))
        assertEquals(0, FrameBarcode.decode(last))
        first.recycle()
        last.recycle()
    }

    @Test
    fun preflightRefusesLongRangesAndLowSpace() {
        val job = engine.ctx.reverse
        try {
            job.run(request("frame_counter_1080p30.mp4", 0, ReverseMath.MAX_RANGE_US + 1, "too_long"), ReverseControl())
            fail("ranges over 10 min are refused")
        } catch (e: EngineException) {
            assertTrue(ReverseMath.isRangeLimit(e))
            assertEquals(EngineErrorCode.unsupportedMedia, e.code)
        }
        job.freeBytesOverride = { 10L * 1024 * 1024 }
        try {
            job.run(request("frame_counter_1080p30.mp4", 0, 8_000_000, "no_space"), ReverseControl())
            fail("low space is refused")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.diskFull, e.code)
            assertEquals("fp-frame_counter_1080p30.mp4", e.mediaFingerprint)
        } finally {
            job.freeBytesOverride = null
        }
        assertEquals(emptyList<String>(), engine.workLeftovers())
        assertFalse(engine.output("too_long").exists())
        assertFalse(engine.output("no_space").exists())
    }

    @Test
    fun cancelCleansTheWorkDirectory() {
        // Direct: cancel as soon as the first intermediate exists.
        val job = engine.ctx.reverse
        val control = ReverseControl()
        job.chunkDurationUs = 1_000_000
        job.onWorkSample = { _, _ -> control.cancel() }
        try {
            job.run(request("frame_counter_1080p30.mp4", 0, 8_000_000, "cancel_direct"), control)
            fail("a cancelled job does not finish")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.cancelled, e.code)
        } finally {
            job.onWorkSample = null
            job.chunkDurationUs = ReverseMath.DEFAULT_CHUNK_US
        }
        assertEquals(emptyList<String>(), engine.workLeftovers())
        assertFalse(engine.output("cancel_direct").exists())
        assertFalse(File(engine.output("cancel_direct").path + ".part").exists())

        // Through the registry, mid-job.
        job.chunkDurationUs = 1_000_000
        try {
            val latch = java.util.concurrent.CountDownLatch(1)
            var id: Result<String>? = null
            engine.ctx.jobs.start(request("frame_counter_1080p30.mp4", 0, 8_000_000, "cancel_registry")) {
                id = it
                latch.countDown()
            }
            assertTrue(latch.await(10, java.util.concurrent.TimeUnit.SECONDS))
            val jobId = id!!.getOrThrow()
            val deadline = System.currentTimeMillis() + 120_000
            while (engine.progress(jobId) < 0.2 && System.currentTimeMillis() < deadline) Thread.sleep(20)
            assertTrue("the job made progress before the cancel", engine.progress(jobId) >= 0.2)
            assertTrue("work exists mid-job", engine.workLeftovers().isNotEmpty())
            engine.ctx.jobs.cancel(jobId)
            val end = engine.awaitTerminal(jobId)
            assertEquals(EngineEventKindMsg.FAILURE, end.kind)
            assertEquals(EngineErrorCode.cancelled.name, end.failure!!.code)
        } finally {
            job.chunkDurationUs = ReverseMath.DEFAULT_CHUNK_US
        }
        assertEquals(emptyList<String>(), engine.workLeftovers())
        assertFalse(engine.output("cancel_registry").exists())
        assertFalse(File(engine.output("cancel_registry").path + ".part").exists())
    }

    @Test
    fun reverseJobThroughTheRegistry() {
        val latch = java.util.concurrent.CountDownLatch(1)
        var id: Result<String>? = null
        engine.ctx.jobs.start(request("tone_under_video.mp4", 2_000_000, 5_000_000, "registry")) {
            id = it
            latch.countDown()
        }
        assertTrue(latch.await(10, java.util.concurrent.TimeUnit.SECONDS))
        val end = engine.awaitTerminal(id!!.getOrThrow())
        assertEquals(EngineEventKindMsg.JOB_DONE, end.kind)
        val asset = end.jobDone!!.asset
        assertNotNull(asset)
        assertEquals(engine.output("registry").absolutePath, asset!!.path)
        assertEquals(3_000_000L, asset.durationUs)
        val clip = Clip(File(asset.path))
        assertStrictlyDecreasing(clip.barcodes(), 149, 60)
        // The 1 kHz tone keeps its level.
        val source = Pcm.of(engine.ctx, ReverseFixtures.file("tone_under_video.mp4"))
        val out = Pcm.of(engine.ctx, File(asset.path))
        val ratio = out.rms(200_000, 2_800_000) / source.rms(2_200_000, 4_800_000)
        Log.i(TAG, "tone level ratio reversed/source %.3f [emulator]".format(ratio))
        assertEquals(1.0, ratio, 0.1)
    }

    @Test
    fun defaultDecodersStillReverse() {
        val job = engine.ctx.reverse
        val saved = job.assetLoaderFactory
        job.assetLoaderFactory = null
        try {
            val asset = reverse("frame_counter_1080p30.mp4", 0, 2_000_000, "defaults")
            val barcodes = Clip(File(asset.path)).barcodes()
            Log.i(TAG, "production decoders [emulator]: ${barcodes.size} of 60 frames, barcodes $barcodes")
            val readable = barcodes.filterNotNull()
            for (i in 1 until readable.size) assertTrue("strictly decreasing", readable[i] < readable[i - 1])
            assertEquals(59, readable.first())
            assertEquals(0, readable.last())
            assertTrue("at most the emulator's dropped B-frame is missing", barcodes.size >= 59)
        } finally {
            job.assetLoaderFactory = saved
        }
    }
}
