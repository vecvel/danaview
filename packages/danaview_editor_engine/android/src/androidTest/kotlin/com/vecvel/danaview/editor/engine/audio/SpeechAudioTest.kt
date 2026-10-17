// OWNER: AND-04
//
// Speech audio extraction on the emulator with the ENG-05 fixtures (BUILD_PLAN AND-04 = IOS-04
// ACs): canonical 16 kHz mono s16 WAV, duration = range ± 1 ms, the clap_flash_av clicks within
// ±20 ms including the AAC priming in the edit list (V-A6), the 5.1 centre channel kept, unsupported
// codecs -> unsupportedMedia, cancel deletes the partial output; plus the Media3 speech chain on
// synthetic clicks. Throughput is logged under DanaviewAudioTest as an emulator number (the >= 60x
// realtime mid-tier criterion needs a device).

package com.vecvel.danaview.editor.engine.audio

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.media.PcmDecoder
import com.vecvel.danaview.editor.engine.media.SpeechResampler
import com.vecvel.danaview.editor.engine.pigeon.JobKindMsg
import com.vecvel.danaview.editor.engine.pigeon.JobPriorityMsg
import com.vecvel.danaview.editor.engine.pigeon.JobRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.ResolvedMediaMsg
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.concurrent.thread
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.sin

@RunWith(AndroidJUnit4::class)
class SpeechAudioTest {
    companion object {
        private const val TAG = "DanaviewAudioTest"
        private lateinit var ctx: EngineContext

        @BeforeClass
        @JvmStatic
        fun setUp() {
            ctx = AudioTestEngine.create("speech-test")
        }

        @AfterClass
        @JvmStatic
        fun tearDown() {
            ctx.threads.shutdown()
        }
    }

    private fun output(name: String): File = File(ctx.requirePaths().speechRoot, "work/$name.wav")

    private fun request(name: String, startUs: Long, endUs: Long, out: File, audioStream: Long? = null): JobRequestMsg {
        val file = TestFixtures.copyToCache(FixtureTree.ENGINE, "media/$name")
        return JobRequestMsg(
            kind = JobKindMsg.SPEECH_AUDIO,
            media = ResolvedMediaMsg(uri = file.absolutePath, fingerprint = "fp-$name", isProxy = false),
            priority = JobPriorityMsg.INTERACTIVE,
            audioStream = audioStream,
            sourceStartUs = startUs,
            sourceEndUs = endUs,
            outputPath = out.absolutePath,
        )
    }

    private fun extract(name: String, startUs: Long, endUs: Long): Pair<Wav, com.vecvel.danaview.editor.engine.pigeon.ExtractedSpeechAudioMsg> {
        val out = output("${name.substringBefore('.')}-$startUs-$endUs")
        val control = TestJobControl()
        val started = System.nanoTime()
        val result = ctx.speechAudio.extract(request(name, startUs, endUs, out), control)
        val ms = (System.nanoTime() - started) / 1e6
        val rangeS = (endUs - startUs) / 1e6
        Log.i(TAG, "$name [$startUs, $endUs) -> ${result.frames} frames in ${"%.0f".format(ms)} ms (${"%.1f".format(rangeS * 1000 / ms)}x realtime, emulator)")
        assertEquals(out.absolutePath, result.path)
        assertFalse(".part removed", File(out.path + ".part").exists())
        assertEquals(1.0, control.reports.last(), 0.0)
        return Wav.parse(out) to result
    }

    private fun checkFormat(wav: Wav, startUs: Long, endUs: Long) {
        assertEquals(listOf("fmt ", "data"), wav.chunkIds)
        assertEquals(1, wav.format)
        assertEquals(16_000, wav.sampleRate)
        assertEquals(1, wav.channels)
        assertEquals(16, wav.bitsPerSample)
        assertTrue("duration ${wav.durationUs} vs ${endUs - startUs}", abs(wav.durationUs - (endUs - startUs)) <= 1_000)
    }

    @Test
    fun clapClicksLandWithin20msIncludingAacPriming() {
        // V-A6: clap_flash_av.mp4 has 2112 priming samples in its elst; clicks start at 1.0, 2.5, 4.0 s.
        val (wav, result) = extract("clap_flash_av.mp4", 0, 6_000_000)
        checkFormat(wav, 0, 6_000_000)
        assertEquals(96_000L, result.frames)
        assertEquals(6_000_000L, result.durationUs)
        assertEquals(1L, result.sourceChannels)
        assertEquals(48_000L, result.sourceSampleRate)
        assertEquals("aac", result.codec)
        var from = 0
        val errors = ArrayList<Double>()
        for (t in listOf(1.0, 2.5, 4.0)) {
            val at = AudioSignals.onset(wav.samples, from)
            val errorMs = (at / 16.0) - t * 1000
            errors.add(errorMs)
            assertTrue("click at $t s found at ${at / 16.0} ms (error $errorMs ms)", abs(errorMs) <= 20)
            from = at + 16_000 / 5
        }
        Log.i(TAG, "V-A6 clap click errors (ms): $errors")
        // Silence before the first click (the priming must not leak in as audio).
        assertTrue(AudioSignals.rms(wav.samples.copyOfRange(0, 15_000)) < 0.001)
    }

    @Test
    fun subRangeStartsAtTheRangeStart() {
        // [0.9 s, 4.1 s): the clicks move to 0.1, 1.6 and 3.1 s.
        val (wav, result) = extract("clap_flash_av.mp4", 900_000, 4_100_000)
        checkFormat(wav, 900_000, 4_100_000)
        assertEquals(51_200L, result.frames)
        var from = 0
        for (t in listOf(0.1, 1.6, 3.1)) {
            val at = AudioSignals.onset(wav.samples, from)
            assertTrue("click at $t s found at ${at / 16.0} ms", abs(at / 16.0 - t * 1000) <= 20)
            from = at + 16_000 / 5
        }
    }

    @Test
    fun surroundCentreIsKept() {
        val (wav, result) = extract("surround_5_1.m4a", 500_000, 4_500_000)
        checkFormat(wav, 500_000, 4_500_000)
        assertEquals(6L, result.sourceChannels)
        // Source: 500 Hz at -12 dBFS peak in C only; the downmix keeps 0.5 · C: -18 dBFS peak, RMS -21 dBFS.
        val rmsDb = 20 * log10(AudioSignals.rms(wav.samples.copyOfRange(8_000, 56_000)))
        Log.i(TAG, "5.1 centre: output RMS $rmsDb dBFS (expected about -21.0)")
        assertEquals(-21.0, rmsDb, 1.5)
        assertEquals(500.0, AudioSignals.zeroCrossingHz(wav.samples.copyOfRange(8_000, 56_000), 16_000), 5.0)
    }

    @Test
    fun formatsAndDurations() {
        for ((name, range) in listOf(
            "speech_10s.m4a" to (1_000_000L to 9_000_000L),
            "tone_1khz.wav" to (250_000L to 3_250_000L),
            "stereo_440l_880r.wav" to (0L to 5_000_000L),
            "tone_under_video.mp4" to (123_457L to 7_654_321L),
            "sample_h264_aac.mkv" to (0L to 2_500_000L),
            "sample_vp9_opus.webm" to (0L to 2_500_000L),
        )) {
            val (wav, result) = extract(name, range.first, range.second)
            checkFormat(wav, range.first, range.second)
            assertEquals(Math.round((range.second - range.first) * 16_000 / 1e6), result.frames)
            Log.i(TAG, "$name: codec ${result.codec}, ${result.sourceChannels} ch @ ${result.sourceSampleRate} Hz")
        }
        val (tone, _) = extract("tone_1khz.wav", 0, 2_000_000)
        assertEquals(1000.0, AudioSignals.zeroCrossingHz(tone.samples, 16_000), 5.0)
        assertEquals(-15.0, 20 * log10(AudioSignals.rms(tone.samples)), 1.0) // -12 dBFS peak sine
    }

    @Test
    fun rangePastTheEndKeepsWhatWasDecoded() {
        val (wav, _) = extract("tone_1khz.wav", 9_000_000, 12_000_000)
        assertEquals("1 s of a 10 s file", 16_000, wav.frames)
    }

    @Test
    fun unsupportedCodecsAndMissingAudioAreUnsupportedMedia() {
        val ac3 = Ac3Fixture.write(File(TestFixtures.targetContext.cacheDir, "danaview_test_fixtures/ac3"))
        val out = output("ac3")
        val request = request("tone_1khz.wav", 0, 400_000, out).copy(media = ResolvedMediaMsg(uri = ac3.absolutePath, fingerprint = "fp-ac3", isProxy = false))
        try {
            ctx.speechAudio.extract(request, TestJobControl())
            fail("AC-3 has no decoder on this device")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.unsupportedMedia, e.code)
            assertEquals("fp-ac3", e.mediaFingerprint)
        }
        assertFalse(out.exists())
        assertFalse(File(out.path + ".part").exists())
        try {
            ctx.speechAudio.extract(request("frame_counter_720p25.mp4", 0, 1_000_000, output("noaudio")), TestJobControl())
            fail("no audio track")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.unsupportedMedia, e.code)
        }
    }

    @Test
    fun outputOutsideTheRootsIsRefused() {
        val outside = File(TestFixtures.targetContext.cacheDir, "elsewhere/out.wav")
        try {
            ctx.speechAudio.extract(request("tone_1khz.wav", 0, 1_000_000, outside), TestJobControl())
            fail("outside the engine roots")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.permissionDenied, e.code)
        }
        assertFalse(outside.exists())
    }

    @Test
    fun cancelDeletesThePartialOutput() {
        val out = output("cancelled")
        val control = TestJobControl()
        var error: Throwable? = null
        val worker = thread {
            try {
                ctx.speechAudio.extract(request("tone_under_video.mp4", 0, 8_000_000, out), object : com.vecvel.danaview.editor.engine.core.JobControl by control {
                    override fun reportProgress(fraction: Double) {
                        control.reportProgress(fraction)
                        if (fraction > 0.1) control.cancelled.set(true)
                    }
                })
            } catch (t: Throwable) {
                error = t
            }
        }
        worker.join(30_000)
        assertEquals(EngineErrorCode.cancelled, (error as EngineException).code)
        assertFalse(out.exists())
        assertFalse(File(out.path + ".part").exists())
    }

    // ---- the Media3 chain on synthetic input ----

    private fun clicks(rate: Int, channels: Int, seconds: Double, clickTimes: List<Double>, channel: Int = -1, amplitude: Float = 0.5f): FloatArray {
        val frames = (rate * seconds).toInt()
        val out = FloatArray(frames * channels)
        for (t in clickTimes) {
            val start = (t * rate).toInt()
            for (k in 0 until rate / 50) {
                val v = (amplitude * sin(2 * PI * 2000 * k / rate)).toFloat()
                for (c in 0 until channels) if (channel < 0 || c == channel) out[(start + k) * channels + c] = v
            }
        }
        return out
    }

    private fun runChain(rate: Int, channels: Int, pcm: FloatArray, chunk: Int = 4096): ShortArray {
        val resampler = SpeechResampler(rate, channels)
        val parts = ArrayList<ShortArray>()
        var i = 0
        while (i < pcm.size) {
            val end = minOf(pcm.size, i + chunk * channels)
            parts.add(resampler.process(pcm.copyOfRange(i, end)))
            i = end
        }
        parts.add(resampler.finish())
        return parts.flatMap { it.asIterable() }.toShortArray()
    }

    @Test
    fun chainKeepsClicksWithin1msAtEveryRate() {
        for ((rate, channels) in listOf(48_000 to 2, 44_100 to 1, 24_000 to 1, 16_000 to 1, 8_000 to 1, 48_000 to 6)) {
            val pcm = clicks(rate, channels, 3.0, listOf(1.5))
            val out = runChain(rate, channels, pcm)
            assertTrue("$rate/$channels: length ${out.size}", abs(out.size - 48_000) <= 16)
            val at = AudioSignals.onset(out, 0)
            Log.i(TAG, "chain $rate Hz x$channels: click at ${at / 16.0} ms, ${out.size} frames")
            assertTrue("$rate/$channels: click at ${at / 16.0} ms", abs(at - 24_000) <= 16)
        }
    }

    @Test
    fun chainCentreWeightIsHalf() {
        val rate = 48_000
        val pcm = FloatArray(rate * 6)
        for (f in 0 until rate) pcm[f * 6 + 2] = (0.5 * sin(2 * PI * 500 * f / rate)).toFloat()
        val out = runChain(rate, 6, pcm)
        val rms = AudioSignals.rms(out.copyOfRange(4_000, 12_000))
        assertEquals(0.25 / Math.sqrt(2.0), rms, 0.01)
    }

    @Test
    fun pcmDecoderReportsTheSourceLayout() {
        val file = TestFixtures.copyToCache(FixtureTree.ENGINE, "media/surround_5_1.m4a")
        PcmDecoder(ctx).open(file.absolutePath).use { pcm ->
            Log.i(TAG, "surround_5_1: ${pcm.channels} ch mask 0x${Integer.toHexString(pcm.channelMask)} @ ${pcm.sampleRate} Hz")
            assertEquals(6, pcm.channels)
            assertEquals(48_000, pcm.sampleRate)
        }
    }
}
