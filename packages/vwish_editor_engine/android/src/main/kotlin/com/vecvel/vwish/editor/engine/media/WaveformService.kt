// OWNER: AND-04
//
// `.vwpk` waveform peaks (ARCH §12.3, §15; BUILD_PLAN AND-04; same binning and file as iOS IOS-04):
// one audio stream decoded by PcmDecoder, mixed to mono with the fixed Downmix, binned at 200
// pairs per second (bin i covers source frames [floor(i·rate/200), floor((i+1)·rate/200))), each
// bin's min and max quantised to int8 (round(x · 127), clamped to ±127; a bin without samples is
// 0/0). Cached in DiskCache waves/ as `<fingerprint>-<stream>.vwpk`:
//
//   offset  size  field (little endian)
//   0       4     "VWPK"
//   4       2     version (1)
//   6       2     pairs per second (200)
//   8       8     duration µs (int64) = decoded frames / rate
//   16      4     pair count (uint32)
//   20      4     source sample rate (uint32)
//   24      2     source channels (uint16)
//   26      2     audio stream (uint16)
//   28      4     reserved (0)
//   32      2·n   int8 min, int8 max per pair
//
// AND-05's JobRegistry runs `peaks(...)` as the `waveform` job (cancel, progress) and answers with
// the returned WaveformPeaksMsg; a pre-emption stops the decode like a cancel (`isStopRequested`).

package com.vecvel.vwish.editor.engine.media

import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.EngineException
import com.vecvel.vwish.editor.engine.core.JobControl
import com.vecvel.vwish.editor.engine.core.isStopRequested
import com.vecvel.vwish.editor.engine.pigeon.JobRequestMsg
import com.vecvel.vwish.editor.engine.pigeon.WaveformPeaksMsg
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.floor

/** Waveform peaks job, .vwpk int8 min/max at 200 pairs/s (ARCH §15; AND-04). */
class WaveformService(private val ctx: EngineContext) {
    private val decoder = PcmDecoder(ctx)

    /** Computes the peaks of [request].media (kind waveform). Blocking; throws an EngineException on failure. */
    fun peaks(request: JobRequestMsg, control: JobControl): WaveformPeaksMsg {
        val stream = (request.audioStream ?: 0L).toInt()
        val store = ctx.pathsOrNull?.let { DiskCache.stores(it).waves }
        val key = cacheKey(request.media.fingerprint, stream)
        store?.read(key, FILE_EXTENSION)?.let(::decode)?.let { cached ->
            control.reportProgress(1.0)
            return cached.message
        }
        val peaks = try {
            compute(request.media.uri, stream, control)
        } catch (t: Throwable) {
            throw EngineErrors.from(t).withFingerprint(request.media.fingerprint)
        }
        if (store != null) {
            try {
                store.write(encode(peaks), key, FILE_EXTENSION)
            } catch (e: EngineException) {
                android.util.Log.w(EngineContext.TAG, "waveform cache write failed: ${e.code.name}")
            }
        }
        return peaks.message
    }

    /** Decodes and bins [audioStream] of [uri] (no cache). */
    fun compute(uri: String, audioStream: Int, control: JobControl?): Peaks {
        decoder.open(uri, audioStream, isCancelled = { control?.isStopRequested == true }).use { pcm ->
            val coefficients = Downmix.coefficients(pcm.channels, pcm.channelMask)
            val binner = PeakBinner(pcm.sampleRate)
            var lastReport = 0.0
            while (true) {
                val chunk = pcm.read() ?: break
                binner.add(Downmix.mono(chunk, pcm.channels, coefficients))
                if (control != null && pcm.progress - lastReport >= 0.05) {
                    lastReport = pcm.progress
                    control.reportProgress(lastReport)
                }
            }
            control?.throwIfCancelled()
            control?.reportProgress(1.0)
            return Peaks(
                minMax = binner.finish(),
                durationUs = PcmTrim.durationUs(binner.frames, pcm.sampleRate),
                sampleRate = pcm.sampleRate,
                channels = pcm.channels,
                audioStream = audioStream,
            )
        }
    }

    /** Decoded peaks with their source facts. */
    class Peaks(
        val minMax: ByteArray,
        val durationUs: Long,
        val sampleRate: Int,
        val channels: Int,
        val audioStream: Int,
    ) {
        /** Number of (min, max) pairs. */
        val pairCount: Int get() = minMax.size / 2

        /** The Pigeon result. */
        val message: WaveformPeaksMsg get() = WaveformPeaksMsg(minMax = minMax, durationUs = durationUs, pairsPerSecond = PAIRS_PER_SECOND.toLong())
    }

    /** Streaming min/max binning at 200 pairs/s (iOS `PeakBinner`). */
    class PeakBinner(private val sampleRate: Int) {
        /** Frames added so far. */
        var frames = 0L
            private set
        private val bins = ByteArrayOutputStream()
        private var currentMin = Float.MAX_VALUE
        private var currentMax = -Float.MAX_VALUE
        private var currentBin = 0L
        private var hasData = false

        /** First frame of bin [i]. */
        fun binStart(i: Long): Long = floor(i.toDouble() * sampleRate / PAIRS_PER_SECOND).toLong()

        /** Adds mono samples. */
        fun add(mono: FloatArray) {
            var offset = 0
            while (offset < mono.size) {
                val absolute = frames + offset
                val binEnd = binStart(currentBin + 1)
                if (absolute >= binEnd) {
                    flush()
                    continue
                }
                val take = minOf((mono.size - offset).toLong(), binEnd - absolute).toInt()
                for (i in offset until offset + take) {
                    val v = mono[i]
                    if (v < currentMin) currentMin = v
                    if (v > currentMax) currentMax = v
                }
                hasData = true
                offset += take
            }
            frames += mono.size
        }

        private fun flush() {
            if (hasData) {
                bins.write(quantize(currentMin).toInt())
                bins.write(quantize(currentMax).toInt())
            } else {
                bins.write(0)
                bins.write(0)
            }
            currentBin++
            currentMin = Float.MAX_VALUE
            currentMax = -Float.MAX_VALUE
            hasData = false
        }

        /** The interleaved min/max pairs (the last partial bin included). */
        fun finish(): ByteArray {
            if (hasData) flush()
            return bins.toByteArray()
        }
    }

    companion object {
        const val PAIRS_PER_SECOND = 200
        const val FILE_EXTENSION = "vwpk"
        const val HEADER_SIZE = 32

        /** `<fingerprint>-<stream>` (iOS `WaveformService.cacheKey`). */
        fun cacheKey(fingerprint: String, audioStream: Int): String = "${CacheStore.fileName(fingerprint)}-$audioStream"

        /** round(value · 127) half away from zero (Swift `.rounded()`), clamped to ±127; non-finite -> 0. */
        fun quantize(value: Float): Byte {
            if (!value.isFinite()) return 0
            val scaled = value * 127f
            val rounded = if (scaled >= 0f) floor(scaled + 0.5f) else -floor(-scaled + 0.5f)
            return rounded.coerceIn(-127f, 127f).toInt().toByte()
        }

        /** The `.vwpk` bytes of [peaks]. */
        fun encode(peaks: Peaks): ByteArray {
            val buffer = ByteBuffer.allocate(HEADER_SIZE + peaks.minMax.size).order(ByteOrder.LITTLE_ENDIAN)
            buffer.put("VWPK".toByteArray(Charsets.US_ASCII))
            buffer.putShort(1)
            buffer.putShort(PAIRS_PER_SECOND.toShort())
            buffer.putLong(peaks.durationUs)
            buffer.putInt(peaks.pairCount)
            buffer.putInt(peaks.sampleRate)
            buffer.putShort(peaks.channels.toShort())
            buffer.putShort(peaks.audioStream.toShort())
            buffer.putInt(0)
            buffer.put(peaks.minMax)
            return buffer.array()
        }

        /** Parses `.vwpk` bytes; null when malformed. */
        fun decode(data: ByteArray): Peaks? {
            if (data.size < HEADER_SIZE || String(data, 0, 4, Charsets.US_ASCII) != "VWPK") return null
            val b = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
            if (b.getShort(4).toInt() != 1 || b.getShort(6).toInt() != PAIRS_PER_SECOND) return null
            val pairs = b.getInt(16).toLong() and 0xFFFFFFFFL
            if (data.size.toLong() != HEADER_SIZE + pairs * 2) return null
            return Peaks(
                minMax = data.copyOfRange(HEADER_SIZE, data.size),
                durationUs = b.getLong(8),
                sampleRate = b.getInt(20),
                channels = b.getShort(24).toInt() and 0xFFFF,
                audioStream = b.getShort(26).toInt() and 0xFFFF,
            )
        }
    }
}
