@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-04
//
// PCM decoder (ARCH §15, ai.md §7.3; BUILD_PLAN AND-04): one audio stream of a file -> interleaved
// float PCM at the source rate and layout, with sample-accurate ranges. Shared by waveforms, speech
// audio and AND-07's reverse audio.
//
// - Demux: Media3 `MediaExtractorCompat` (Media3's extractors: MP4 edit lists and gapless metadata
//   as ExoPlayer applies them). For an AAC track with encoder priming (an `elst` that skips the
//   priming, D-04/V-A6), Media3 keeps the media timeline and reports the priming as the format's
//   encoder delay ("encoder-delay"); the decoder is configured WITHOUT that key, so it outputs every
//   sample, and the stream subtracts the delay itself. Content time is counted in samples from the
//   first output buffer: sample n of the decoded stream is at `firstPts - delay + n / rate`
//   (container µs timestamps are only the anchor, so their rounding never adds or drops samples).
//   Files whose priming Media3 expresses as a timestamp shift instead (no encoder delay) are covered
//   with delay 0. Opus is the exception: the platform decoder discards the pre-skip itself (csd-1)
//   at the start of decoding, so its first output sample is already at the first packet's
//   content time and no delay is subtracted.
// - Decode: framework MediaCodec in async (callback) mode on a private HandlerThread, requesting
//   ENCODING_PCM_FLOAT (16-bit output is converted) and up to 8 output channels for AAC (so 5.1 is
//   not downmixed by the decoder). Output buffers are handed to the reading thread un-copied and
//   released there, which bounds memory by the codec's own buffer count. Raw PCM tracks (WAV) are
//   read from the extractor without a codec.
// - Range: decoding starts at a sync sample >= 200 ms before the range start (decoder warm-up,
//   e.g. AAC's overlap) and frames outside [startUs, endUs) are dropped by sample index
//   (`PcmTrim`). The end is clipped to the track duration.
// - Failures: missing file -> mediaOffline, revoked grant -> permissionDenied, unparseable
//   container, no audio track or no decoder for the codec -> unsupportedMedia, codec errors ->
//   decoderInitFailed / decodeFailed; cancellation is polled between buffers (-> cancelled).

package com.vecvel.danaview.editor.engine.media

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import androidx.annotation.OptIn
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.inspector.MediaExtractorCompat
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import java.io.Closeable
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/** PCM decoder (ARCH §15; AND-04). */
class PcmDecoder(private val ctx: EngineContext) {
    /**
     * Opens audio stream [audioStream] (index among the audio tracks) of [uri] for
     * [startUs, endUs) (null = from the start / to the end). Blocking until the decoded format is
     * known; the caller closes the stream.
     */
    fun open(uri: String, audioStream: Int = 0, startUs: Long? = null, endUs: Long? = null, isCancelled: () -> Boolean = { false }): PcmStream =
        PcmStream.open(ctx.appContext, uri, audioStream, startUs, endUs, isCancelled)
}

/** Sample-accurate trimming of decoded buffers. */
object PcmTrim {
    /**
     * The frames [from, to) of a buffer of [frames] frames whose first frame is at content time
     * [bufferStartUs] that fall inside [startUs, endUs) at [sampleRate] (frame f is at
     * bufferStartUs + f · 1e6 / rate). Empty when the buffer lies outside the range.
     */
    fun window(bufferStartUs: Long, frames: Int, sampleRate: Int, startUs: Long, endUs: Long): IntRange {
        val rate = sampleRate.toDouble()
        // First frame at or after startUs, and first frame at or after endUs. Container timestamps
        // are whole µs (floored by Media3) and the encoder delay is rounded to µs, so a frame may
        // appear up to ~1.5 µs early: a tolerance of 0.2 frame absorbs that without ever moving a
        // boundary by a whole frame.
        val from = ceil((startUs - bufferStartUs) * rate / 1_000_000.0 - FRAME_TOLERANCE).toLong().coerceIn(0L, frames.toLong()).toInt()
        val to = ceil((endUs - bufferStartUs) * rate / 1_000_000.0 - FRAME_TOLERANCE).toLong().coerceIn(0L, frames.toLong()).toInt()
        return from until max(from, to)
    }

    /** Timestamp noise tolerance, in frames. */
    const val FRAME_TOLERANCE = 0.2

    /** µs of [frames] frames at [sampleRate]. */
    fun durationUs(frames: Long, sampleRate: Int): Long = Math.round(frames * 1_000_000.0 / sampleRate)
}

/** The fixed downmix to mono shared by waveforms and speech audio (ARCH §15; same as iOS `Downmix`). */
object Downmix {
    // AudioFormat.CHANNEL_OUT_* bits (literals keep the mapping JVM-testable).
    private const val FRONT_LEFT = 0x4
    private const val FRONT_RIGHT = 0x8
    private const val FRONT_CENTER = 0x10
    private const val LOW_FREQUENCY = 0x20
    private const val LOW_FREQUENCY_2 = 0x2000000

    /**
     * Per-channel weights: mono copy; stereo 0.5/0.5; otherwise centre 0.5, front left/right 0.25,
     * LFE 0, every surround 0.125 (5.1 -> 0.5·C + 0.25·(L+R) + 0.125·(Ls+Rs), LFE dropped). Channels
     * follow Android's canonical order (ascending CHANNEL_OUT bits); [channelMask] gives the
     * layout when the decoder reports it, else 5.1 and 7.1 use the canonical layouts and other
     * counts an equal 1/n mix.
     */
    fun coefficients(channels: Int, channelMask: Int = 0): FloatArray {
        if (channels <= 1) return floatArrayOf(1f)
        if (channels == 2) return floatArrayOf(0.5f, 0.5f)
        val bits = maskBits(channelMask)
        if (bits.size == channels) return FloatArray(channels) { weight(bits[it]) }
        return when (channels) {
            // FL FR FC LFE BL BR
            6 -> floatArrayOf(0.25f, 0.25f, 0.5f, 0f, 0.125f, 0.125f)
            // FL FR FC LFE BL BR SL SR
            8 -> floatArrayOf(0.25f, 0.25f, 0.5f, 0f, 0.125f, 0.125f, 0.125f, 0.125f)
            else -> FloatArray(channels) { 1f / channels }
        }
    }

    private fun weight(bit: Int): Float = when (bit) {
        FRONT_CENTER -> 0.5f
        FRONT_LEFT, FRONT_RIGHT -> 0.25f
        LOW_FREQUENCY, LOW_FREQUENCY_2 -> 0f
        else -> 0.125f
    }

    private fun maskBits(mask: Int): List<Int> = (0 until 31).map { 1 shl it }.filter { mask and it != 0 }

    /** Interleaved [samples] of [channels] channels mixed to mono with [coefficients]. */
    fun mono(samples: FloatArray, channels: Int, coefficients: FloatArray): FloatArray {
        if (channels == 1) return samples
        val frames = samples.size / channels
        val out = FloatArray(frames)
        for (f in 0 until frames) {
            var sum = 0f
            val base = f * channels
            for (c in 0 until channels) sum += samples[base + c] * coefficients[c]
            out[f] = sum
        }
        return out
    }
}

/** An open decoder of one audio stream; read() returns interleaved float PCM until the range ends. */
class PcmStream private constructor(
    private val extractor: MediaExtractorCompat,
    private val codec: MediaCodec?,
    private val thread: HandlerThread?,
    private val events: LinkedBlockingQueue<Event>?,
    /** Source sample rate of the decoded PCM. */
    val sampleRate: Int,
    /** Decoded channels. */
    val channels: Int,
    /** AudioFormat channel mask of the decoded PCM (0 when unknown). */
    val channelMask: Int,
    /** Source codec name ("aac", "pcm_s16le", ...). */
    val codecName: String,
    /** Effective range start (µs). */
    val startUs: Long,
    /** Effective range end (µs), clipped to the track duration. */
    val endUs: Long,
    private val encoderDelayUs: Long,
    private val rawEncoding: Int,
    private val isCancelled: () -> Boolean,
    private var pendingFirst: Event.Output?,
) : Closeable {
    /** Events from the codec callback thread. */
    sealed class Event {
        class Output(val index: Int, val ptsUs: Long, val size: Int, val offset: Int, val flags: Int) : Event()
        class Format(val format: MediaFormat) : Event()
        class Failure(val error: Throwable) : Event()
    }

    private var ended = false
    private var outputEncoding = AudioFormat.ENCODING_PCM_16BIT

    /** Content time of the first decoded sample (set by the first output buffer). */
    private var anchorUs: Long? = null

    /** Frames decoded so far (before trimming). */
    private var decodedFrames = 0L

    /** Frames returned so far. */
    var framesDelivered: Long = 0
        private set

    /** Frames the range spans at the source rate. */
    val expectedFrames: Long get() = Math.round((endUs - startUs) * sampleRate / 1_000_000.0)

    /** 0..1 progress through the range. */
    val progress: Double get() = if (expectedFrames <= 0) 1.0 else min(1.0, framesDelivered.toDouble() / expectedFrames)

    /** The next interleaved float samples inside the range, or null at its end. */
    fun read(): FloatArray? {
        while (!ended) {
            if (isCancelled()) throw EngineException(EngineErrorCode.cancelled, "cancelled")
            val chunk = if (codec == null) readRaw() else readDecoded()
            if (chunk != null && chunk.isNotEmpty()) {
                framesDelivered += chunk.size / channels
                return chunk
            }
        }
        return null
    }

    private fun readRaw(): FloatArray? {
        val size = extractor.sampleSize
        val pts = extractor.sampleTime
        if (size <= 0 || pts < 0 || pts >= endUs) {
            ended = true
            return null
        }
        val buffer = ByteBuffer.allocate(size.toInt()).order(ByteOrder.LITTLE_ENDIAN)
        val read = extractor.readSampleData(buffer, 0)
        extractor.advance()
        if (read <= 0) return null
        buffer.limit(read)
        val samples = PcmConvert.toFloat(buffer, rawEncoding)
        return trim(samples, pts)
    }

    private fun readDecoded(): FloatArray? {
        val event = pendingFirst ?: events!!.poll(POLL_MS, TimeUnit.MILLISECONDS) ?: return null
        pendingFirst = null
        when (event) {
            is Event.Failure -> throw mapCodecError(event.error)
            is Event.Format -> {
                val rate = event.format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                val ch = event.format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                if (rate != sampleRate || ch != channels) throw EngineException(EngineErrorCode.decodeFailed, "audio format changed while decoding")
                outputEncoding = pcmEncodingOf(event.format)
                return null
            }
            is Event.Output -> {
                val codec = codec!!
                try {
                    if (event.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0 && event.size == 0) {
                        ended = true
                        return null
                    }
                    val buffer = codec.getOutputBuffer(event.index) ?: return null
                    buffer.position(event.offset)
                    buffer.limit(event.offset + event.size)
                    val samples = PcmConvert.toFloat(buffer.slice().order(ByteOrder.nativeOrder()), outputEncoding)
                    if (event.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) ended = true
                    if (samples.isEmpty()) return null
                    // Content time by sample count from the first output buffer (see the file comment).
                    val anchor = anchorUs ?: (event.ptsUs - encoderDelayUs).also { anchorUs = it }
                    val bufferStartUs = anchor + PcmTrim.durationUs(decodedFrames, sampleRate)
                    decodedFrames += samples.size / channels
                    val trimmed = trim(samples, bufferStartUs)
                    if (bufferStartUs >= endUs) ended = true
                    return trimmed
                } finally {
                    try {
                        codec.releaseOutputBuffer(event.index, false)
                    } catch (e: IllegalStateException) {
                        // Codec released while closing.
                    }
                }
            }
        }
    }

    /** The frames of [samples] (interleaved, first frame at content time [bufferStartUs]) inside the range. */
    private fun trim(samples: FloatArray, bufferStartUs: Long): FloatArray {
        val frames = samples.size / channels
        val window = PcmTrim.window(bufferStartUs, frames, sampleRate, startUs, endUs)
        if (window.isEmpty()) {
            if (bufferStartUs >= endUs) ended = true
            return FloatArray(0)
        }
        if (window.first == 0 && window.last == frames - 1) return samples
        return samples.copyOfRange(window.first * channels, (window.last + 1) * channels)
    }

    override fun close() {
        try {
            codec?.stop()
        } catch (e: IllegalStateException) {
            // Already stopped or in error.
        }
        codec?.release()
        thread?.let {
            it.quitSafely()
            // The callback thread reads the extractor: let it finish before the extractor goes.
            try {
                it.join(1_000)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        extractor.release()
    }

    private fun mapCodecError(error: Throwable): EngineException = when (error) {
        is EngineException -> error
        is MediaCodec.CodecException -> EngineException(EngineErrorCode.decodeFailed, "audio decode failed", cause = error)
        else -> EngineErrors.from(error)
    }

    companion object {
        private const val POLL_MS = 50L

        /** Decoding starts this long before the range (decoder warm-up). */
        const val PREROLL_US = 200_000L

        /** Waiting limit for the decoded format. */
        private const val FORMAT_TIMEOUT_MS = 10_000L

        /** AAC: let the decoder output up to 8 channels (MediaFormat.KEY_MAX_OUTPUT_CHANNEL_COUNT, API 30 name). */
        private const val KEY_AAC_MAX_OUTPUT_CHANNELS = "aac-max-output-channel_count"

        /** Media3's encoder delay key (MediaFormat.KEY_ENCODER_DELAY). */
        private const val KEY_ENCODER_DELAY = "encoder-delay"

        /** The audio track indices of [extractor], in container order. */
        fun audioTracks(extractor: MediaExtractorCompat): List<Int> =
            (0 until extractor.trackCount).filter { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }

        /** Opens the stream (see [PcmDecoder.open]). */
        fun open(
            context: Context,
            uri: String,
            audioStream: Int,
            startUs: Long?,
            endUs: Long?,
            isCancelled: () -> Boolean,
        ): PcmStream {
            val extractor = MediaSources.extractor(context, uri)
            try {
                val tracks = audioTracks(extractor)
                if (tracks.isEmpty()) throw EngineException(EngineErrorCode.unsupportedMedia, "no audio track")
                val track = tracks.getOrNull(audioStream) ?: throw EngineException(EngineErrorCode.unsupportedMedia, "audio stream out of range")
                val format = extractor.getTrackFormat(track)
                val mime = format.getString(MediaFormat.KEY_MIME)!!
                val rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                val channelCount = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else Long.MAX_VALUE
                val start = max(0L, startUs ?: 0L)
                val end = min(endUs ?: Long.MAX_VALUE, durationUs)
                if (end <= start) throw EngineErrors.invalidArgument("range", "empty or past the media end")
                // Opus decoders discard the pre-skip themselves (from csd-1), so no delay is subtracted.
                val delayFrames = if (format.containsKey(KEY_ENCODER_DELAY) && mime != "audio/opus") format.getInteger(KEY_ENCODER_DELAY) else 0
                val delayUs = PcmTrim.durationUs(delayFrames.toLong(), rate)
                extractor.selectTrack(track)
                extractor.seekTo(max(0L, start - PREROLL_US), MediaExtractorCompat.SEEK_TO_PREVIOUS_SYNC)

                if (mime == "audio/raw") {
                    val encoding = if (format.containsKey(MediaFormat.KEY_PCM_ENCODING)) format.getInteger(MediaFormat.KEY_PCM_ENCODING) else AudioFormat.ENCODING_PCM_16BIT
                    val name = CodecNames.of(androidx.media3.common.MimeTypes.AUDIO_RAW, PcmConvert.media3Encoding(encoding)) ?: "pcm"
                    return PcmStream(
                        extractor, null, null, null, rate, channelCount, 0, name, start, end, 0L, encoding, isCancelled, null,
                    )
                }
                return openDecoder(extractor, format, mime, rate, channelCount, start, end, delayUs, isCancelled)
            } catch (t: Throwable) {
                extractor.release()
                throw if (t is EngineException) t else MediaSources.mapOpenError(t)
            }
        }

        private fun openDecoder(
            extractor: MediaExtractorCompat,
            trackFormat: MediaFormat,
            mime: String,
            rate: Int,
            channelCount: Int,
            start: Long,
            end: Long,
            delayUs: Long,
            isCancelled: () -> Boolean,
        ): PcmStream {
            // A fresh format without the encoder delay/padding keys (see the file comment).
            val config = MediaFormat.createAudioFormat(mime, rate, channelCount)
            for (key in listOf("csd-0", "csd-1", "csd-2")) trackFormat.getByteBuffer(key)?.let { config.setByteBuffer(key, it.duplicate()) }
            for (key in listOf(MediaFormat.KEY_AAC_PROFILE, MediaFormat.KEY_IS_ADTS, MediaFormat.KEY_MAX_INPUT_SIZE)) {
                if (trackFormat.containsKey(key)) config.setInteger(key, trackFormat.getInteger(key))
            }
            config.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_FLOAT)
            config.setInteger(KEY_AAC_MAX_OUTPUT_CHANNELS, 8)
            val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(MediaFormat.createAudioFormat(mime, rate, channelCount))
                ?: throw EngineException(EngineErrorCode.unsupportedMedia, "no decoder for this audio codec")
            val codecName = CodecNames.of(mime) ?: mime
            val codec = try {
                MediaCodec.createByCodecName(name)
            } catch (e: Exception) {
                throw EngineException(EngineErrorCode.decoderInitFailed, "audio decoder unavailable", cause = e)
            }
            val thread = HandlerThread("danaview-pcm").apply { start() }
            val events = LinkedBlockingQueue<Event>()
            val feedEndUs = end + delayUs + PREROLL_US
            codec.setCallback(object : MediaCodec.Callback() {
                private var inputDone = false

                override fun onInputBufferAvailable(mc: MediaCodec, index: Int) {
                    if (inputDone) return
                    try {
                        val buffer = mc.getInputBuffer(index) ?: return
                        val time = extractor.sampleTime
                        val size = if (time >= 0 && time <= feedEndUs) extractor.readSampleData(buffer, 0) else -1
                        if (size < 0) {
                            mc.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            mc.queueInputBuffer(index, 0, size, time, 0)
                            extractor.advance()
                        }
                    } catch (t: Throwable) {
                        inputDone = true
                        events.add(Event.Failure(t))
                    }
                }

                override fun onOutputBufferAvailable(mc: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                    events.add(Event.Output(index, info.presentationTimeUs, info.size, info.offset, info.flags))
                }

                override fun onError(mc: MediaCodec, e: MediaCodec.CodecException) {
                    events.add(Event.Failure(e))
                }

                override fun onOutputFormatChanged(mc: MediaCodec, format: MediaFormat) {
                    events.add(Event.Format(format))
                }
            }, Handler(thread.looper))
            try {
                codec.configure(config, null, null, 0)
                codec.start()
            } catch (e: Exception) {
                codec.release()
                thread.quitSafely()
                throw EngineException(EngineErrorCode.decoderInitFailed, "audio decoder failed to start", cause = e)
            }
            // Wait for the decoded format (it precedes the first output buffer).
            val deadline = System.nanoTime() + FORMAT_TIMEOUT_MS * 1_000_000
            var firstOutput: Event.Output? = null
            var outFormat: MediaFormat? = null
            try {
                while (outFormat == null) {
                    if (isCancelled()) throw EngineException(EngineErrorCode.cancelled, "cancelled")
                    if (System.nanoTime() > deadline) throw EngineException(EngineErrorCode.decodeFailed, "audio decoder produced no output", retryable = true)
                    when (val event = events.poll(POLL_MS, TimeUnit.MILLISECONDS)) {
                        null -> Unit
                        is Event.Format -> outFormat = event.format
                        is Event.Failure -> throw if (event.error is EngineException) event.error else EngineException(EngineErrorCode.decodeFailed, "audio decode failed", cause = event.error)
                        is Event.Output -> {
                            // Some decoders deliver output before announcing a format: use the configured one.
                            firstOutput = event
                            outFormat = codec.outputFormat
                        }
                    }
                }
            } catch (t: Throwable) {
                try {
                    codec.stop()
                } catch (e: IllegalStateException) {
                    // ignore
                }
                codec.release()
                thread.quitSafely()
                throw t
            }
            val format = outFormat!!
            val outRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val outChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            val mask = if (format.containsKey(MediaFormat.KEY_CHANNEL_MASK)) format.getInteger(MediaFormat.KEY_CHANNEL_MASK) else 0
            val stream = PcmStream(
                extractor, codec, thread, events, outRate, outChannels, mask, codecName, start, end, delayUs,
                AudioFormat.ENCODING_PCM_16BIT, isCancelled, firstOutput,
            )
            stream.outputEncoding = pcmEncodingOf(format)
            return stream
        }

        private fun pcmEncodingOf(format: MediaFormat): Int =
            if (format.containsKey(MediaFormat.KEY_PCM_ENCODING)) format.getInteger(MediaFormat.KEY_PCM_ENCODING) else AudioFormat.ENCODING_PCM_16BIT
    }
}

/** PCM byte <-> float conversion. */
object PcmConvert {
    /** Platform AudioFormat encodings -> Media3 C.ENCODING_* (for codec names). */
    fun media3Encoding(encoding: Int): Int = when (encoding) {
        AudioFormat.ENCODING_PCM_8BIT -> androidx.media3.common.C.ENCODING_PCM_8BIT
        AudioFormat.ENCODING_PCM_FLOAT -> androidx.media3.common.C.ENCODING_PCM_FLOAT
        ENCODING_PCM_24BIT_PACKED -> androidx.media3.common.C.ENCODING_PCM_24BIT
        ENCODING_PCM_32BIT -> androidx.media3.common.C.ENCODING_PCM_32BIT
        else -> androidx.media3.common.C.ENCODING_PCM_16BIT
    }

    /** AudioFormat.ENCODING_PCM_24BIT_PACKED (API 31 constant, value 21). */
    const val ENCODING_PCM_24BIT_PACKED = 21

    /** AudioFormat.ENCODING_PCM_32BIT (API 31 constant, value 22). */
    const val ENCODING_PCM_32BIT = 22

    /** The samples of [buffer] (little endian, platform [encoding]) as floats in -1..1. */
    fun toFloat(buffer: ByteBuffer, encoding: Int): FloatArray {
        val b = buffer.order(ByteOrder.LITTLE_ENDIAN)
        return when (encoding) {
            AudioFormat.ENCODING_PCM_FLOAT -> FloatArray(b.remaining() / 4) { b.getFloat(b.position() + it * 4) }
            AudioFormat.ENCODING_PCM_8BIT -> FloatArray(b.remaining()) { ((b.get(b.position() + it).toInt() and 0xFF) - 128) / 128f }
            ENCODING_PCM_24BIT_PACKED -> FloatArray(b.remaining() / 3) {
                val p = b.position() + it * 3
                val v = (b.get(p).toInt() and 0xFF) or ((b.get(p + 1).toInt() and 0xFF) shl 8) or (b.get(p + 2).toInt() shl 16)
                v / 8_388_608f
            }
            ENCODING_PCM_32BIT -> FloatArray(b.remaining() / 4) { b.getInt(b.position() + it * 4) / 2_147_483_648f }
            else -> FloatArray(b.remaining() / 2) { b.getShort(b.position() + it * 2) / 32_768f }
        }
    }

    /** [value] in -1..1 as a rounded, clamped s16. */
    fun toS16(value: Float): Short {
        val scaled = Math.round(value * 32_767f)
        return scaled.coerceIn(-32_768, 32_767).toShort()
    }
}
