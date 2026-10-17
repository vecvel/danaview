// OWNER: AND-04
//
// Waveform peaks on the emulator: lossless WAV peaks equal the reference computed from the file's
// own samples, AAC peaks match the tone level, peaks sit at the clap clicks (priming removed), the
// `.dvpk` is cached in waves/ and reused, and the realtime factor is logged (emulator number; the
// >= 20x low-tier criterion needs a device).

package com.vecvel.danaview.editor.engine.audio

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.media.DiskCache
import com.vecvel.danaview.editor.engine.media.Downmix
import com.vecvel.danaview.editor.engine.media.WaveformService
import com.vecvel.danaview.editor.engine.pigeon.JobKindMsg
import com.vecvel.danaview.editor.engine.pigeon.JobPriorityMsg
import com.vecvel.danaview.editor.engine.pigeon.JobRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.ResolvedMediaMsg
import com.vecvel.danaview.editor.engine.pigeon.WaveformPeaksMsg
import org.junit.AfterClass
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import kotlin.math.abs
import kotlin.math.floor

@RunWith(AndroidJUnit4::class)
class WaveformTest {
    companion object {
        private const val TAG = "DanaviewAudioTest"
        private lateinit var ctx: EngineContext

        @BeforeClass
        @JvmStatic
        fun setUp() {
            ctx = AudioTestEngine.create("waveform-test")
        }

        @AfterClass
        @JvmStatic
        fun tearDown() {
            ctx.threads.shutdown()
        }
    }

    private fun request(name: String, fingerprint: String = "fp-$name", stream: Long? = null): JobRequestMsg {
        val file = TestFixtures.copyToCache(FixtureTree.ENGINE, "media/$name")
        return JobRequestMsg(
            kind = JobKindMsg.WAVEFORM,
            media = ResolvedMediaMsg(uri = file.absolutePath, fingerprint = fingerprint, isProxy = false),
            priority = JobPriorityMsg.BACKGROUND,
            audioStream = stream,
        )
    }

    private fun peaks(name: String, fingerprint: String = "fp-$name"): WaveformPeaksMsg {
        val control = TestJobControl()
        val started = System.nanoTime()
        val peaks = ctx.waveforms.peaks(request(name, fingerprint), control)
        val ms = (System.nanoTime() - started) / 1e6
        Log.i(TAG, "waveform $name: ${peaks.minMax.size / 2} pairs, ${peaks.durationUs} µs in ${"%.0f".format(ms)} ms (${"%.1f".format(peaks.durationUs / 1000.0 / ms)}x realtime, emulator)")
        assertEquals(200L, peaks.pairsPerSecond)
        assertEquals(1.0, control.reports.last(), 0.0)
        return peaks
    }

    /** Reference peaks from the WAV's own samples (downmixed with the same coefficients). */
    private fun referencePeaks(name: String): ByteArray {
        val wav = Wav.parse(TestFixtures.copyToCache(FixtureTree.ENGINE, "media/$name"))
        val coefficients = Downmix.coefficients(wav.channels)
        val mono = FloatArray(wav.frames) { f ->
            var sum = 0f
            for (c in 0 until wav.channels) sum += wav.samples[f * wav.channels + c] / 32768f * coefficients[c]
            sum
        }
        val out = ArrayList<Byte>()
        var i = 0L
        while (true) {
            val a = floor(i * wav.sampleRate / 200.0).toInt()
            if (a >= mono.size) break
            val b = minOf(mono.size, floor((i + 1) * wav.sampleRate / 200.0).toInt())
            var lo = Float.MAX_VALUE
            var hi = -Float.MAX_VALUE
            for (k in a until b) {
                lo = minOf(lo, mono[k])
                hi = maxOf(hi, mono[k])
            }
            out.add(WaveformService.quantize(lo))
            out.add(WaveformService.quantize(hi))
            i++
        }
        return out.toByteArray()
    }

    @Test
    fun wavPeaksMatchTheReference() {
        for (name in listOf("tone_1khz.wav", "stereo_440l_880r.wav")) {
            val peaks = peaks(name)
            assertArrayEquals(name, referencePeaks(name), peaks.minMax)
        }
    }

    @Test
    fun aacToneUnderVideo() {
        val peaks = peaks("tone_under_video.mp4")
        assertTrue("duration ${peaks.durationUs}", abs(peaks.durationUs - 8_000_000) <= 1_000)
        assertEquals(1600, peaks.minMax.size / 2)
        // 1 kHz at -12 dBFS: every interior bin spans ±32 (round(0.251 · 127)).
        for (pair in 10 until 1590) {
            assertTrue("min of bin $pair: ${peaks.minMax[2 * pair]}", abs(peaks.minMax[2 * pair] + 32) <= 2)
            assertTrue("max of bin $pair: ${peaks.minMax[2 * pair + 1]}", abs(peaks.minMax[2 * pair + 1] - 32) <= 2)
        }
    }

    @Test
    fun clapPeaksSitAtTheClicks() {
        val peaks = peaks("clap_flash_av.mp4")
        assertTrue(abs(peaks.durationUs - 6_000_000) <= 1_000)
        val loud = (0 until peaks.minMax.size / 2).filter { peaks.minMax[2 * it + 1] > 20 }
        // Clicks of 20 ms at 1.0, 2.5, 4.0 s -> bins 200..203, 500..503, 800..803 (±4 bins = ±20 ms).
        val groups = loud.fold(mutableListOf<MutableList<Int>>()) { acc, bin ->
            if (acc.isEmpty() || bin - acc.last().last() > 10) acc.add(mutableListOf(bin)) else acc.last().add(bin)
            acc
        }
        Log.i(TAG, "clap waveform loud bins: ${groups.map { it.first() to it.last() }}")
        assertEquals(3, groups.size)
        for ((group, expected) in groups.zip(listOf(200, 500, 800))) {
            assertTrue("click starts at bin ${group.first()} (expected $expected)", abs(group.first() - expected) <= 4)
        }
    }

    @Test
    fun peaksAreCachedAndReused() {
        val first = peaks("speech_10s.m4a", "fp-cache")
        val file = DiskCache.stores(ctx.requirePaths()).waves.file(WaveformService.cacheKey("fp-cache", 0), "dvpk")
        assertTrue(file.isFile)
        val decoded = WaveformService.decode(file.readBytes())!!
        assertEquals(44_100, decoded.sampleRate)
        assertEquals(1, decoded.channels)
        val started = System.nanoTime()
        val second = ctx.waveforms.peaks(request("speech_10s.m4a", "fp-cache"), TestJobControl())
        Log.i(TAG, "cached waveform in ${(System.nanoTime() - started) / 1_000_000} ms")
        assertArrayEquals(first.minMax, second.minMax)
        assertEquals(first.durationUs, second.durationUs)
        assertTrue(abs(first.durationUs - 10_000_000) <= 60_000)
    }

    @Test
    fun surroundAndOpus() {
        val surround = peaks("surround_5_1.m4a")
        // 500 Hz at -12 dBFS in C, downmixed at 0.5: ±16.
        val mid = surround.minMax.size / 4
        assertTrue("5.1 centre kept: ${surround.minMax[2 * mid + 1]}", abs(surround.minMax[2 * mid + 1] - 16) <= 2)
        val webm = peaks("sample_vp9_opus.webm")
        assertTrue(abs(webm.durationUs - 3_000_000) <= 60_000)
    }

    @Test
    fun noAudioIsUnsupportedMedia() {
        try {
            ctx.waveforms.peaks(request("frame_counter_720p25.mp4"), TestJobControl())
            fail("no audio track")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.unsupportedMedia, e.code)
        }
        val ac3 = Ac3Fixture.write(File(TestFixtures.targetContext.cacheDir, "danaview_test_fixtures/ac3"))
        try {
            ctx.waveforms.peaks(request("tone_1khz.wav").copy(media = ResolvedMediaMsg(uri = ac3.absolutePath, fingerprint = "fp-ac3", isProxy = false)), TestJobControl())
            fail("AC-3 has no decoder")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.unsupportedMedia, e.code)
        }
    }

    @Test
    fun cancelStopsTheJob() {
        val control = TestJobControl()
        control.cancelled.set(true)
        try {
            ctx.waveforms.peaks(request("tone_under_video.mp4", "fp-cancel"), control)
            fail("cancelled")
        } catch (e: EngineException) {
            assertEquals(EngineErrorCode.cancelled, e.code)
        }
        assertTrue(!DiskCache.stores(ctx.requirePaths()).waves.file(WaveformService.cacheKey("fp-cancel", 0), "dvpk").exists())
    }
}
