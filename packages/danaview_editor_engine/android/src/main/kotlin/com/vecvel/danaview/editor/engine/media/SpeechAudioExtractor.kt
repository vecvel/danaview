@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-04
//
// Speech audio for transcription (ai.md §7.1/§7.3, D-28 port implemented natively; ARCH §15;
// BUILD_PLAN AND-04, same contract as iOS IOS-04): a source range of one audio stream ->
// canonical RIFF/WAVE, PCM s16le, mono, 16,000 Hz, "fmt " then "data" only.
//
// - Sample 0 is source time range.start (PcmDecoder: Media3 extractors with edit lists, AAC
//   priming removed via the encoder delay, sample-accurate trim).
// - Downmix with Media3's ChannelMixingAudioProcessor and a ChannelMixingMatrix(n -> 1) holding the
//   fixed coefficients (mono copy; stereo 0.5/0.5; 5.1 -> 0.5·C + 0.25·(L+R) + 0.125·(Ls+Rs), LFE
//   dropped; `Downmix.coefficients`), then Media3's SonicAudioProcessor with output rate 16 kHz,
//   then float -> s16 (rounded, clamped).
// - The output always holds round(duration · 16000) frames (Sonic's tail is padded or cut), so its
//   duration equals the range within 1 ms; when the media ends before the range, the frames that
//   were decoded are kept.
// - The WAV is streamed to `<output>.part` (header patched at the end) and renamed onto the
//   Dart-supplied path (inside the engine roots); cancellation and failures delete the partial
//   file. Unsupported containers or codecs fail with unsupportedMedia (PcmDecoder).
// AND-05's JobRegistry runs `extract(...)` as the `speechAudio` job; a pre-emption stops the decode
// like a cancel (`isStopRequested`) and the registry re-queues the job.

package com.vecvel.danaview.editor.engine.media

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.ChannelMixingAudioProcessor
import androidx.media3.common.audio.ChannelMixingMatrix
import androidx.media3.common.audio.SonicAudioProcessor
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.JobControl
import com.vecvel.danaview.editor.engine.core.isStopRequested
import com.vecvel.danaview.editor.engine.pigeon.ExtractedSpeechAudioMsg
import com.vecvel.danaview.editor.engine.pigeon.JobRequestMsg
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** 16 kHz s16 mono WAV for a source range (ARCH §15; AND-04). */
class SpeechAudioExtractor(private val ctx: EngineContext) {
    private val decoder = PcmDecoder(ctx)

    /** Writes the WAV of [request] (kind speechAudio) to its outputPath. Blocking; throws an EngineException on failure. */
    fun extract(request: JobRequestMsg, control: JobControl): ExtractedSpeechAudioMsg {
        val output = ctx.requirePaths().requireWritable(request.outputPath ?: throw EngineErrors.invalidArgument("outputPath", "missing"), "outputPath")
        val start = request.sourceStartUs ?: throw EngineErrors.invalidArgument("sourceStartUs", "missing")
        val end = request.sourceEndUs ?: throw EngineErrors.invalidArgument("sourceEndUs", "missing")
        return try {
            extract(request.media.uri, start, end, (request.audioStream ?: 0L).toInt(), output, control).message
        } catch (t: Throwable) {
            throw EngineErrors.from(t).withFingerprint(request.media.fingerprint)
        }
    }

    /** Extracts [startUs, endUs) of [audioStream] of [uri] into [output]. Blocking. */
    fun extract(uri: String, startUs: Long, endUs: Long, audioStream: Int, output: File, control: JobControl?): Result {
        val part = File(output.path + ".part")
        try {
            decoder.open(uri, audioStream, startUs, endUs, isCancelled = { control?.isStopRequested == true }).use { pcm ->
                output.parentFile?.mkdirs()
                val expected = Math.round((pcm.endUs - pcm.startUs) * OUTPUT_RATE / 1_000_000.0)
                var written = 0L
                WavWriter(part, OUTPUT_RATE).use { wav ->
                    val resampler = SpeechResampler(pcm.sampleRate, pcm.channels, pcm.channelMask)
                    var lastReport = 0.0
                    while (written < expected) {
                        val chunk = pcm.read()
                        val out = if (chunk != null) resampler.process(chunk) else resampler.finish()
                        val take = minOf(out.size.toLong(), expected - written).toInt()
                        if (take > 0) wav.append(out, take)
                        written += take
                        if (control != null && pcm.progress - lastReport >= 0.05) {
                            lastReport = pcm.progress
                            control.reportProgress(lastReport * 0.99)
                        }
                        if (chunk == null) break
                    }
                    control?.throwIfCancelled()
                    // Pad Sonic's tail (or a source that ended early) up to the expected length.
                    val target = if (pcm.framesDelivered >= pcm.expectedFrames - 1) expected
                    else Math.round(pcm.framesDelivered * OUTPUT_RATE.toDouble() / pcm.sampleRate)
                    if (written < target) {
                        wav.append(ShortArray((target - written).toInt()), (target - written).toInt())
                        written = target
                    }
                }
                if (output.exists() && !output.delete()) throw EngineException(EngineErrorCode.io, "cannot replace the output")
                if (!part.renameTo(output)) throw EngineException(EngineErrorCode.io, "cannot move the output into place")
                control?.reportProgress(1.0)
                return Result(
                    path = output.path,
                    frames = written,
                    durationUs = PcmTrim.durationUs(written, OUTPUT_RATE),
                    sourceChannels = pcm.channels,
                    sourceSampleRate = pcm.sampleRate,
                    codec = pcm.codecName,
                )
            }
        } catch (t: Throwable) {
            part.delete()
            if (control?.isCancelled == true) throw EngineException(EngineErrorCode.cancelled, "cancelled", cause = t)
            throw EngineErrors.from(t)
        }
    }

    /** The extraction result. */
    data class Result(
        val path: String,
        val frames: Long,
        val durationUs: Long,
        val sourceChannels: Int,
        val sourceSampleRate: Int,
        val codec: String,
    ) {
        /** The Pigeon result. */
        val message: ExtractedSpeechAudioMsg
            get() = ExtractedSpeechAudioMsg(
                path = path, frames = frames, durationUs = durationUs, sourceChannels = sourceChannels.toLong(),
                sourceSampleRate = sourceSampleRate.toLong(), codec = codec,
            )
    }

    companion object {
        /** Output sample rate (ai.md §7.1). */
        const val OUTPUT_RATE = 16_000
    }
}

/**
 * Interleaved float PCM at [sourceRate] with [channels] channels -> mono s16 at 16 kHz through
 * Media3's ChannelMixingAudioProcessor (fixed downmix) and SonicAudioProcessor (rate conversion).
 */
class SpeechResampler(sourceRate: Int, private val channels: Int, channelMask: Int = 0, outputRate: Int = SpeechAudioExtractor.OUTPUT_RATE) {
    private val mixer = ChannelMixingAudioProcessor()
    private val sonic = SonicAudioProcessor()
    private val mixerOut: AudioProcessor.AudioFormat
    private val sonicOut: AudioProcessor.AudioFormat
    private var ended = false

    init {
        val input = AudioProcessor.AudioFormat(sourceRate, channels, C.ENCODING_PCM_FLOAT)
        mixer.putChannelMixingMatrix(ChannelMixingMatrix(channels, 1, Downmix.coefficients(channels, channelMask)))
        val mixed = mixer.configure(input)
        mixerOut = if (mixer.isActive) mixed else input
        sonic.setOutputSampleRateHz(outputRate)
        val resampled = sonic.configure(mixerOut)
        sonicOut = if (sonic.isActive) resampled else mixerOut
        mixer.flush(AudioProcessor.StreamMetadata.DEFAULT)
        sonic.flush(AudioProcessor.StreamMetadata.DEFAULT)
        check(sonicOut.channelCount == 1 && sonicOut.sampleRate == outputRate) { "speech resampler misconfigured" }
    }

    /** Converts [interleaved] and returns the s16 samples available so far. */
    fun process(interleaved: FloatArray): ShortArray {
        if (interleaved.isEmpty()) return ShortArray(0)
        val input = ByteBuffer.allocateDirect(interleaved.size * 4).order(ByteOrder.nativeOrder())
        input.asFloatBuffer().put(interleaved)
        return run(input, endOfStream = false)
    }

    /** Flushes the processors at the end of the input and returns the remaining s16 samples. */
    fun finish(): ShortArray {
        if (ended) return ShortArray(0)
        ended = true
        return run(ByteBuffer.allocateDirect(0).order(ByteOrder.nativeOrder()), endOfStream = true)
    }

    private fun run(input: ByteBuffer, endOfStream: Boolean): ShortArray {
        val out = ArrayList<ShortArray>()
        var data = input
        if (mixer.isActive) {
            if (data.hasRemaining()) mixer.queueInput(data)
            if (endOfStream) mixer.queueEndOfStream()
            data = copy(mixer.output)
        }
        if (sonic.isActive) {
            var guard = 0
            while (data.hasRemaining() && guard++ < 10_000) {
                sonic.queueInput(data)
                out.add(toShorts(sonic.output))
            }
            if (endOfStream) {
                sonic.queueEndOfStream()
                guard = 0
                while (!sonic.isEnded && guard++ < 10_000) out.add(toShorts(sonic.output))
            }
            out.add(toShorts(sonic.output))
        } else {
            out.add(toShorts(data))
        }
        val total = out.sumOf { it.size }
        val result = ShortArray(total)
        var offset = 0
        for (part in out) {
            part.copyInto(result, offset)
            offset += part.size
        }
        return result
    }

    private fun copy(buffer: ByteBuffer): ByteBuffer {
        val copy = ByteBuffer.allocateDirect(buffer.remaining()).order(ByteOrder.nativeOrder())
        copy.put(buffer)
        copy.flip()
        return copy
    }

    private fun toShorts(buffer: ByteBuffer): ShortArray {
        val b = buffer.order(ByteOrder.nativeOrder())
        val result = if (sonicOut.encoding == C.ENCODING_PCM_FLOAT || (!sonic.isActive && mixerOut.encoding == C.ENCODING_PCM_FLOAT)) {
            ShortArray(b.remaining() / 4) { PcmConvert.toS16(b.getFloat(b.position() + it * 4)) }
        } else {
            ShortArray(b.remaining() / 2) { b.getShort(b.position() + it * 2) }
        }
        b.position(b.limit())
        return result
    }

    init {
        require(channels >= 1) { "channels" }
    }
}

/** Streams a canonical 44-byte-header PCM s16le mono WAV to [file]; [close] patches the sizes. */
class WavWriter(private val file: File, private val sampleRate: Int) : AutoCloseable {
    private val out: RandomAccessFile
    private var frames = 0L
    private var closed = false

    init {
        file.parentFile?.mkdirs()
        out = try {
            RandomAccessFile(file, "rw").apply {
                setLength(0)
                write(header(sampleRate, 0))
            }
        } catch (e: IOException) {
            throw EngineErrors.from(e)
        }
    }

    /** Appends the first [count] samples of [samples]. */
    fun append(samples: ShortArray, count: Int) {
        val bytes = ByteBuffer.allocate(count * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (i in 0 until count) bytes.putShort(samples[i])
        try {
            out.write(bytes.array())
        } catch (e: IOException) {
            throw EngineErrors.from(e)
        }
        frames += count
    }

    override fun close() {
        if (closed) return
        closed = true
        try {
            out.seek(0)
            out.write(header(sampleRate, frames * 2))
            out.fd.sync()
        } catch (e: IOException) {
            throw EngineErrors.from(e)
        } finally {
            out.close()
        }
    }

    companion object {
        /** RIFF/WAVE header: "fmt " (PCM, mono, 16-bit) then "data" of [dataBytes]. */
        fun header(sampleRate: Int, dataBytes: Long): ByteArray {
            val b = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            b.put("RIFF".toByteArray(Charsets.US_ASCII))
            b.putInt((36 + dataBytes).toInt())
            b.put("WAVE".toByteArray(Charsets.US_ASCII))
            b.put("fmt ".toByteArray(Charsets.US_ASCII))
            b.putInt(16)
            b.putShort(1) // PCM
            b.putShort(1) // mono
            b.putInt(sampleRate)
            b.putInt(sampleRate * 2) // byte rate
            b.putShort(2) // block align
            b.putShort(16) // bits per sample
            b.put("data".toByteArray(Charsets.US_ASCII))
            b.putInt(dataBytes.toInt())
            return b.array()
        }
    }
}
