// OWNER: AND-04
//
// The pure audio parts of AND-04 on the JVM: the fixed downmix (iOS coefficients), sample-accurate
// trimming, the 200 pairs/s peak binner against a naive reference on tone_1khz.wav, the `.vwpk`
// format, the WAV header, and the Media3 speech chain (ChannelMixingAudioProcessor +
// SonicAudioProcessor -> 16 kHz s16) on synthetic clicks and a centre-only 5.1 tone.

package com.vecvel.vwish.editor.engine.audio

import com.vecvel.vwish.editor.engine.harness.FixtureTree
import com.vecvel.vwish.editor.engine.harness.JvmFixtures
import com.vecvel.vwish.editor.engine.media.Downmix
import com.vecvel.vwish.editor.engine.media.PcmConvert
import com.vecvel.vwish.editor.engine.media.PcmTrim
import com.vecvel.vwish.editor.engine.media.WavWriter
import com.vecvel.vwish.editor.engine.media.WaveformService
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.floor

class AudioMathTest {
    @get:Rule
    val temp = TemporaryFolder()

    // ---- downmix ----

    @Test
    fun downmixCoefficientsMatchIos() {
        assertArrayEquals(floatArrayOf(1f), Downmix.coefficients(1), 0f)
        assertArrayEquals(floatArrayOf(0.5f, 0.5f), Downmix.coefficients(2), 0f)
        // Android canonical 5.1 order: FL FR FC LFE BL BR.
        assertArrayEquals(floatArrayOf(0.25f, 0.25f, 0.5f, 0f, 0.125f, 0.125f), Downmix.coefficients(6), 0f)
        assertArrayEquals(floatArrayOf(0.25f, 0.25f, 0.5f, 0f, 0.125f, 0.125f), Downmix.coefficients(6, 0xFC), 0f)
        // 5.1 with side surrounds (FL FR FC LFE SL SR).
        assertArrayEquals(floatArrayOf(0.25f, 0.25f, 0.5f, 0f, 0.125f, 0.125f), Downmix.coefficients(6, 0x4 or 0x8 or 0x10 or 0x20 or 0x800 or 0x1000), 0f)
        assertArrayEquals(floatArrayOf(0.25f, 0.25f, 0.5f, 0f, 0.125f, 0.125f, 0.125f, 0.125f), Downmix.coefficients(8), 0f)
        assertArrayEquals(floatArrayOf(1 / 3f, 1 / 3f, 1 / 3f), Downmix.coefficients(3), 1e-6f)
    }

    @Test
    fun centreChannelIsKeptAtHalf() {
        val frames = 4
        val samples = FloatArray(frames * 6)
        for (f in 0 until frames) samples[f * 6 + 2] = 0.8f // centre only
        val mono = Downmix.mono(samples, 6, Downmix.coefficients(6))
        assertArrayEquals(FloatArray(frames) { 0.4f }, mono, 1e-6f)
        val stereo = floatArrayOf(1f, 0f, 0.5f, 0.5f)
        assertArrayEquals(floatArrayOf(0.5f, 0.5f), Downmix.mono(stereo, 2, Downmix.coefficients(2)), 0f)
    }

    // ---- trimming ----

    @Test
    fun trimIsSampleAccurate() {
        // A 1024-frame buffer at 48 kHz starting at 0.98 s; the range starts at 1.0 s = 960 frames in.
        assertEquals(960 until 1024, PcmTrim.window(980_000, 1024, 48_000, 1_000_000, 2_000_000))
        // Range end inside the buffer: [1.0 s, 1.01 s) keeps 480 frames.
        assertEquals(960 until 1440, PcmTrim.window(980_000, 2048, 48_000, 1_000_000, 1_010_000))
        // Buffers wholly outside are empty.
        assertTrue(PcmTrim.window(0, 1024, 48_000, 1_000_000, 2_000_000).isEmpty())
        assertTrue(PcmTrim.window(2_000_000, 1024, 48_000, 1_000_000, 2_000_000).isEmpty())
        // A buffer inside is kept whole.
        assertEquals(0 until 1024, PcmTrim.window(1_100_000, 1024, 48_000, 1_000_000, 2_000_000))
        // µs-rounded timestamps of 44.1 kHz frames still land on the right frame.
        val start = PcmTrim.durationUs(44_100, 44_100) // exactly 1 s
        assertEquals(1_000_000, start)
        assertEquals(1 until 1024, PcmTrim.window(start - 23, 1024, 44_100, start, start + 1_000_000))
        // Priming: content time = pts - delay; a buffer at pts 0 with a 2112-frame delay starts at -44 ms.
        val delayUs = PcmTrim.durationUs(2112, 48_000)
        assertEquals(44_000, delayUs)
        assertTrue(PcmTrim.window(0 - delayUs, 1024, 48_000, 0, 6_000_000).isEmpty())
        // Frame 2048 of the media has the floored pts 42666 µs; with the delay it starts at frame -64.
        assertEquals(64 until 1024, PcmTrim.window(2048 * 1_000_000L / 48_000 - delayUs, 1024, 48_000, 0, 6_000_000))
        // The 0.2-frame tolerance never moves a boundary by a whole frame.
        assertEquals(10 until 1024, PcmTrim.window(0, 1024, 48_000, 10 * 1_000_000L / 48_000 + 1, 6_000_000))
        assertEquals(11 until 1024, PcmTrim.window(0, 1024, 48_000, 10 * 1_000_000L / 48_000 + 10, 6_000_000))
    }

    // ---- peaks ----

    private fun readWavMonoS16(name: String): Pair<Int, FloatArray> {
        val bytes = JvmFixtures.file(FixtureTree.ENGINE, "media/$name").readBytes()
        val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        var pos = 12
        var rate = 0
        var channels = 0
        while (pos + 8 <= bytes.size) {
            val id = String(bytes, pos, 4, Charsets.US_ASCII)
            val size = b.getInt(pos + 4)
            if (id == "fmt ") {
                channels = b.getShort(pos + 10).toInt()
                rate = b.getInt(pos + 12)
            }
            if (id == "data") {
                val frames = size / 2 / channels
                val mono = FloatArray(frames) { f ->
                    var sum = 0f
                    for (c in 0 until channels) sum += b.getShort(pos + 8 + (f * channels + c) * 2) / 32768f
                    sum / channels
                }
                return rate to mono
            }
            pos += 8 + size + (size and 1)
        }
        error("no data chunk")
    }

    /** Naive reference: per bin min/max over floor(i·rate/200)..floor((i+1)·rate/200). */
    private fun referencePeaks(rate: Int, mono: FloatArray): ByteArray {
        val out = ArrayList<Byte>()
        var i = 0L
        while (true) {
            val a = floor(i * rate / 200.0).toInt()
            if (a >= mono.size) break
            val b = minOf(mono.size, floor((i + 1) * rate / 200.0).toInt())
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
    fun peaksMatchTheReferenceOnTone1khz() {
        val (rate, mono) = readWavMonoS16("tone_1khz.wav")
        assertEquals(48_000, rate)
        val binner = WaveformService.PeakBinner(rate)
        // Feed in odd-sized chunks, as a decoder would.
        var offset = 0
        val sizes = intArrayOf(1024, 777, 4096, 13, 2048)
        var n = 0
        while (offset < mono.size) {
            val take = minOf(sizes[n++ % sizes.size], mono.size - offset)
            binner.add(mono.copyOfRange(offset, offset + take))
            offset += take
        }
        val peaks = binner.finish()
        val reference = referencePeaks(rate, mono)
        assertArrayEquals(reference, peaks)
        assertEquals(2 * 200 * 10, peaks.size) // 10 s at 200 pairs/s
        // -12 dBFS tone: peaks at round(0.251 · 127) = 32.
        assertTrue("min ${peaks[100]}", abs(peaks[100] + 32) <= 1)
        assertTrue("max ${peaks[101]}", abs(peaks[101] - 32) <= 1)
    }

    @Test
    fun peaksOf44100HzBinsAndPartialLastBin() {
        val binner = WaveformService.PeakBinner(44_100)
        assertEquals(0L, binner.binStart(0))
        assertEquals(220L, binner.binStart(1)) // floor(220.5)
        assertEquals(441L, binner.binStart(2))
        binner.add(FloatArray(441) { if (it == 300) 1f else -0.5f })
        binner.add(FloatArray(10) { 0.25f })
        val peaks = binner.finish()
        assertArrayEquals(byteArrayOf(-64, -64, -64, 127, 32, 32), peaks)
        assertEquals(451L, binner.frames)
    }

    @Test
    fun quantisation() {
        assertEquals(127.toByte(), WaveformService.quantize(1.5f))
        assertEquals((-127).toByte(), WaveformService.quantize(-2f))
        assertEquals(0.toByte(), WaveformService.quantize(Float.NaN))
        assertEquals(64.toByte(), WaveformService.quantize(0.5f))
    }

    @Test
    fun vwpkRoundTripsWithTheIosHeader() {
        val peaks = WaveformService.Peaks(byteArrayOf(-3, 4, -5, 6), durationUs = 10_000, sampleRate = 48_000, channels = 6, audioStream = 1)
        val bytes = WaveformService.encode(peaks)
        assertEquals(32 + 4, bytes.size)
        val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals("VWPK", String(bytes, 0, 4, Charsets.US_ASCII))
        assertEquals(1, b.getShort(4).toInt())
        assertEquals(200, b.getShort(6).toInt())
        assertEquals(10_000L, b.getLong(8))
        assertEquals(2, b.getInt(16))
        assertEquals(48_000, b.getInt(20))
        assertEquals(6, b.getShort(24).toInt())
        assertEquals(1, b.getShort(26).toInt())
        assertEquals(0, b.getInt(28))
        val back = WaveformService.decode(bytes)!!
        assertArrayEquals(peaks.minMax, back.minMax)
        assertEquals(10_000L, back.durationUs)
        assertEquals(48_000, back.sampleRate)
        assertNull(WaveformService.decode(bytes.copyOf(35)))
        assertEquals("fp-1-0", WaveformService.cacheKey("fp-1", 0))
    }

    // ---- WAV ----

    @Test
    fun wavHeaderIsCanonical() {
        val file = temp.newFile("out.wav")
        WavWriter(file, 16_000).use { it.append(shortArrayOf(1, -1, 32767), 3) }
        val bytes = file.readBytes()
        assertEquals(44 + 6, bytes.size)
        val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals("RIFF", String(bytes, 0, 4, Charsets.US_ASCII))
        assertEquals(36 + 6, b.getInt(4))
        assertEquals("WAVE", String(bytes, 8, 4, Charsets.US_ASCII))
        assertEquals("fmt ", String(bytes, 12, 4, Charsets.US_ASCII))
        assertEquals(16, b.getInt(16))
        assertEquals(1, b.getShort(20).toInt())
        assertEquals(1, b.getShort(22).toInt())
        assertEquals(16_000, b.getInt(24))
        assertEquals(32_000, b.getInt(28))
        assertEquals(2, b.getShort(32).toInt())
        assertEquals(16, b.getShort(34).toInt())
        assertEquals("data", String(bytes, 36, 4, Charsets.US_ASCII))
        assertEquals(6, b.getInt(40))
        assertEquals(32767, b.getShort(48).toInt())
    }

    @Test
    fun s16Conversion() {
        assertEquals(32767.toShort(), PcmConvert.toS16(1.2f))
        assertEquals((-32768).toShort(), PcmConvert.toS16(-1.5f))
        assertEquals(16384.toShort(), PcmConvert.toS16(0.5f))
        val floats = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putShort(16384).putShort(-32768).putShort(0).putShort(1)
        floats.flip()
        assertArrayEquals(floatArrayOf(0.5f, -1f, 0f, 1 / 32768f), PcmConvert.toFloat(floats, 2), 0f)
    }

    // The Media3 speech chain (ChannelMixingAudioProcessor keeps its matrices in an
    // android.util.SparseArray, a stub on the JVM) is tested on the emulator:
    // androidTest/.../audio/SpeechChainTest.kt.
}
