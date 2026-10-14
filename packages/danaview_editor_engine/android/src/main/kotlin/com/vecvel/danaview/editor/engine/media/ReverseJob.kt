@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-07
//
// Reversed rendition of a source range (ARCH §15 'Reverse' and 'Reverse preflight', review issue
// 14; BUILD_PLAN AND-07, the same chunked algorithm and preflight as iOS IOS-07), written to the
// Dart-supplied derived path (`<support>/danaview/editor/derived/<specHash>.mp4`) through
// `<path>.part` + rename. Bounded memory and disk:
//
// 1. Timeline: one pass over the compressed video samples (MediaExtractorCompat, edit lists applied,
//    no decoding) gives every frame's PTS and the sync samples. Source frame i covering
//    [p_i, e_i) (e_i = next PTS, capped at the range end E) is shown in the output at the MIRRORED
//    time E - e_i, so the last source frame comes first and every frame keeps its own duration (VFR
//    preserved). The output's video track ends at exactly E - S (an end-of-stream sample at that
//    time sets the last frame's duration).
// 2. Chunks from the end: the frames are cut into GOP-aligned chunks of about 2 s taken from the
//    END of the range (a chunk starts at the latest sync frame that keeps it under 4 s; without one,
//    at the frame 2 s before its end, decoding from the previous sync). For each chunk:
//    a. a Media3 Transformer transcodes the chunk's source range into an ALL-INTRA H.264
//       intermediate (`work/reverse-<job>/chunk.mp4`, I-frame interval 0, no audio). Its clip end
//       is moved past any sample that precedes a needed frame in decode order (B-frame reordering
//       would otherwise end the clipped stream early); those extra frames are skipped below;
//    b. the intermediate is read back with MediaExtractorCompat and fed to ONE MediaCodec decoder in
//       reverse frame order (one sample per frame: every sample is a sync sample; an intermediate
//       whose encoder ignored the all-intra request is decoded from the previous sync per frame),
//       with the mirrored output time as its timestamp; each decoded frame is copied as a flexible
//       YUV 4:2:0 image into ONE H.264 encoder (I-frame interval 1 s, ~0.1 bit/pixel/frame) whose
//       samples go to a Media3 Mp4Muxer. No Surface between the codecs: a decoder's Surface
//       buffers are not always a format the encoder's input Surface takes (API 29 emulator), and a
//       copy holds one frame. The intermediate is deleted before the next one is written, so the work directory
//       never holds more than one chunk (plus that chunk's audio WAV, written after the
//       intermediate is gone);
//    c. audio of the same output span: PcmDecoder (AND-04, sample-accurate) decodes the mirrored
//       source span into a 16-bit WAV in the work directory (mono, or stereo for stereo sources;
//       other layouts are mixed down to mono, unusual rates resampled to 48 kHz per chunk), which
//       is read back from its end in blocks of 64k frames, each block reversed in memory and fed to
//       an AAC-LC encoder (128 kb/s), muxed into the same Mp4Muxer. The AAC encoder's priming is
//       taken out the way Media3's Transformer does it (subtracted from the sample times, which
//       makes Mp4Muxer write the `elst`), with the priming measured for the platform encoder
//       (2048 frames, not Media3's 1600), so clicks keep their mirrored position.
// 3. The muxer closes `<output>.part`, which is renamed to the output path; the source's rotation
//    is carried as the track orientation when the intermediate kept it as metadata.
//
// Preflight (ARCH §15): ranges over 10 min are refused (`unsupportedMedia` with the message token
// "limitExceeded reverseRange 600000000", like iOS; the Dart side maps it to
// `LimitExceeded('reverseRange')`), and free space must be at least 2 x estimated output + one chunk
// intermediate + 64 MB (`diskFull`).
//
// Memory: decoded frames live in the codecs' buffers (a few frames); the job copies one decoded
// frame at a time into the encoder and holds one compressed sample, one 64k-frame audio block and
// the per-chunk PCM write buffer. Cancel or
// pre-emption cancels the running Transformer, stops between samples, and deletes the work
// directory and `<output>.part` (a pre-empted job restarts from scratch: Android jobs have no
// checkpoints, ARCH §15). Run by JobRegistry (AND-05) on a registry worker thread; blocking.
// Never logs paths.

package com.vecvel.danaview.editor.engine.media

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.os.StatFs
import android.util.Log
import androidx.annotation.OptIn
import androidx.annotation.VisibleForTesting
import androidx.media3.common.C
import androidx.media3.common.ColorInfo
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.MediaFormatUtil
import androidx.media3.common.util.UnstableApi
import androidx.media3.container.Mp4OrientationData
import androidx.media3.inspector.MediaExtractorCompat
import androidx.media3.muxer.BufferInfo
import androidx.media3.muxer.Mp4Muxer
import androidx.media3.transformer.AssetLoader
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.JobControl
import com.vecvel.danaview.editor.engine.core.JobRegistry
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.core.RegistryJobControl
import com.vecvel.danaview.editor.engine.core.isStopRequested
import com.vecvel.danaview.editor.engine.pigeon.GeneratedAssetMsg
import com.vecvel.danaview.editor.engine.pigeon.JobRequestMsg
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

/** Chunked reverse rendition (ARCH §15; AND-07). */
class ReverseJob(private val ctx: EngineContext) {
    /**
     * Test hook: the intermediate Transformer's asset loader (decoder choice). Null (production)
     * uses Media3's default. The instrumented tests put software decoders first because the x86_64
     * emulator's goldfish H.264 decoder drops a B-frame (AND-05, AND-08).
     */
    @VisibleForTesting
    @Volatile
    var assetLoaderFactory: ((Context) -> AssetLoader.Factory)? = null

    /** Test hook: overrides the free-space query of the preflight. */
    @VisibleForTesting
    @Volatile
    var freeBytesOverride: (() -> Long)? = null

    /** Test hook: the target chunk duration (source time). */
    @VisibleForTesting
    @Volatile
    var chunkDurationUs: Long = ReverseMath.DEFAULT_CHUNK_US

    /** Test hook: called after each stage with the bytes in the job's work directory. */
    @VisibleForTesting
    @Volatile
    var onWorkSample: ((stage: String, workBytes: Long) -> Unit)? = null

    /** Writes the reversed rendition of [request] (kind reverse) to its outputPath. Blocking; throws an EngineException on failure. */
    fun run(request: JobRequestMsg, control: JobControl): GeneratedAssetMsg {
        val paths = ctx.requirePaths()
        val outputPath = request.outputPath ?: throw EngineErrors.invalidArgument("outputPath", "missing")
        val start = request.sourceStartUs ?: throw EngineErrors.invalidArgument("sourceStartUs", "missing")
        val end = request.sourceEndUs ?: throw EngineErrors.invalidArgument("sourceEndUs", "missing")
        val output = paths.requireWritable(outputPath, "outputPath")
        val fingerprint = request.media.fingerprint
        try {
            return reverse(request.media.uri, start, end, request.audioStream?.toInt() ?: 0, output, paths, control)
        } catch (t: Throwable) {
            val error = if (t is ExportException) ProxyJob.mapError(t) else EngineErrors.from(t)
            throw if (error.code == EngineErrorCode.cancelled || error.code == EngineErrorCode.interrupted) error else error.withFingerprint(fingerprint)
        }
    }

    /** Reverses [startUs, endUs) of [uri] into [output] (see the file header). */
    fun reverse(uri: String, startUs: Long, endUs: Long, audioStream: Int, output: File, paths: Paths, control: JobControl): GeneratedAssetMsg {
        ReverseMath.checkRange(endUs - startUs)
        control.throwIfCancelled()
        val context = ctx.appContext
        val source = SourceFacts.read(context, uri, audioStream)
        val rangeStart = max(0L, startUs)
        val rangeEnd = min(endUs, source.videoEndUs)
        if (rangeEnd <= rangeStart) throw EngineErrors.invalidArgument("range", "empty or past the media end")
        val durationUs = rangeEnd - rangeStart

        // Preflight (ARCH §15).
        val w = ReverseMath.even(source.width)
        val h = ReverseMath.even(source.height)
        val outputRate = ReverseMath.outputBitRate(w, h, source.fps)
        val intermediateRate = ReverseMath.intermediateBitRate(w, h, source.fps)
        val estimate = ReverseMath.bytes(outputRate + (if (source.hasAudio) ReverseMath.AUDIO_BIT_RATE else 0), durationUs)
        val chunkUs = max(ReverseMath.MIN_CHUNK_US, chunkDurationUs)
        val chunkBytes = ReverseMath.bytes(intermediateRate, 2 * chunkUs + 1_000_000)
        val free = freeBytesOverride?.invoke() ?: ReverseMath.freeBytes(listOf(paths.work, output.parentFile ?: paths.derived))
        ReverseMath.preflight(durationUs, estimate, chunkBytes, free)

        val timeline = ReverseTimeline.scan(context, uri, rangeStart, rangeEnd, source.videoEndUs, control)
        if (timeline.frames.isEmpty()) throw EngineException(EngineErrorCode.decodeFailed, "no video frames in the range")
        val chunks = timeline.chunks(chunkUs)
        control.throwIfCancelled()
        control.reportProgress(0.02)

        paths.work.mkdirs()
        val work = File(paths.work, "reverse-${CacheStore.fileName(control.jobId)}")
        work.deleteRecursively()
        if (!work.mkdirs()) throw EngineException(EngineErrorCode.io, "cannot create the work directory")
        DiskCache.markActive(work)
        val part = File(output.path + JobRegistry.PART_SUFFIX)
        output.parentFile?.let { if (!it.isDirectory && !it.mkdirs()) throw EngineException(EngineErrorCode.io, "cannot create the output directory") }
        part.delete()
        val looper = HandlerThread("danaview-reverse", Process.THREAD_PRIORITY_BACKGROUND).apply { start() }
        try {
            val audio = if (source.hasAudio) AudioPlan.of(source.sampleRate, source.channels, durationUs) else null
            ReverseWriter(part, outputRate, source.fps, audio, control).use { writer ->
                val intermediate = File(work, "chunk.mp4")
                val wav = File(work, "chunk.wav")
                for ((index, chunk) in chunks.withIndex()) {
                    control.throwIfCancelled()
                    // a. all-intra intermediate of the chunk.
                    writeIntermediate(uri, chunk, intermediate, intermediateRate, source, looper.looper, control)
                    sample("intermediate", work)
                    // b. frames in reverse order -> encoder.
                    val lost = writer.writeVideoChunk(context, intermediate, timeline, chunk)
                    if (lost > 0) Log.w(EngineContext.TAG, "reverse: $lost frames of a chunk were not decoded")
                    intermediate.delete()
                    // c. audio of the chunk's output span.
                    if (audio != null) {
                        val span = audio.span(chunk.outStartUs, chunk.outEndUs, durationUs)
                        writeChunkWav(uri, audioStream, rangeStart, audio, span, wav, control)
                        sample("wav", work)
                        writer.writeAudioChunk(wav, audio)
                        wav.delete()
                    }
                    sample("chunk", work)
                    control.reportProgress(0.02 + 0.95 * (index + 1) / chunks.size)
                }
                writer.finish(durationUs)
            }
            control.throwIfCancelled()
            if (!part.isFile || part.length() == 0L) throw EngineException(EngineErrorCode.encodingFailed, "the reversed clip is empty")
            if (output.exists() && !output.delete()) throw EngineException(EngineErrorCode.io, "cannot replace the reversed clip")
            if (!part.renameTo(output)) throw EngineException(EngineErrorCode.io, "cannot move the reversed clip into place")
            control.reportProgress(1.0)
            Log.i(EngineContext.TAG, "reverse done: ${timeline.frames.size} frames in ${chunks.size} chunks")
            return GeneratedAssetMsg(path = output.absolutePath, sizeBytes = output.length(), durationUs = durationUs)
        } finally {
            looper.quitSafely()
            part.delete()
            work.deleteRecursively()
            DiskCache.unmarkActive(work)
        }
    }

    private fun sample(stage: String, work: File) {
        onWorkSample?.let { hook -> hook(stage, ReverseMath.directoryBytes(work)) }
    }

    // ---- stage a: the all-intra intermediate (Transformer) ----

    private fun writeIntermediate(
        uri: String,
        chunk: ReverseTimeline.Chunk,
        out: File,
        bitRate: Int,
        source: SourceFacts,
        looper: Looper,
        control: JobControl,
    ) {
        out.delete()
        val handler = Handler(looper)
        val latch = CountDownLatch(1)
        var failure: Throwable? = null
        var transformer: Transformer? = null
        val stop = Runnable {
            transformer?.cancel()
            latch.countDown()
        }
        (control as? RegistryJobControl)?.onStop { handler.post(stop) }
        handler.post {
            try {
                if (control.isStopRequested) {
                    latch.countDown()
                    return@post
                }
                val encoders = DefaultEncoderFactory.Builder(ctx.appContext)
                    .setRequestedVideoEncoderSettings(
                        VideoEncoderSettings.Builder().setBitrate(bitRate).setiFrameIntervalSeconds(0f).build(),
                    )
                    .setEnableFallback(true)
                    .build()
                val builder = Transformer.Builder(ctx.appContext)
                    .setLooper(looper)
                    .setVideoMimeType(MimeTypes.VIDEO_H264)
                    .setEncoderFactory(encoders)
                assetLoaderFactory?.let { builder.setAssetLoaderFactory(it(ctx.appContext)) }
                val t = builder.addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                        latch.countDown()
                    }

                    override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                        failure = exportException
                        latch.countDown()
                    }
                }).build()
                transformer = t
                val item = MediaItem.Builder()
                    .setUri(MediaSources.toUri(uri))
                    .setClippingConfiguration(
                        MediaItem.ClippingConfiguration.Builder()
                            .setStartPositionUs(chunk.clipStartUs)
                            .setEndPositionUs(chunk.clipEndUs)
                            .build(),
                    )
                    .build()
                val edited = EditedMediaItem.Builder(item).setRemoveAudio(true).build()
                val composition = Composition.Builder(EditedMediaItemSequence.Builder(setOf(C.TRACK_TYPE_VIDEO)).addItem(edited).build())
                    .setHdrMode(source.hdrMode)
                    .build()
                t.start(composition, out.absolutePath)
            } catch (e: Throwable) {
                failure = e
                latch.countDown()
            }
        }
        try {
            while (!latch.await(STOP_POLL_MS, TimeUnit.MILLISECONDS)) {
                if (control !is RegistryJobControl && control.isCancelled) handler.post(stop)
            }
        } finally {
            // Let the looper finish the Transformer's callbacks before the file is used.
            val drained = CountDownLatch(1)
            handler.post { drained.countDown() }
            drained.await(STOP_POLL_MS * 20, TimeUnit.MILLISECONDS)
        }
        control.throwIfCancelled()
        failure?.let { throw if (it is ExportException) ProxyJob.mapError(it) else EngineErrors.from(it) }
        if (!out.isFile || out.length() == 0L) throw EngineException(EngineErrorCode.encodingFailed, "the reverse intermediate is empty")
    }

    // ---- stage c: the chunk's PCM -> WAV ----

    private fun writeChunkWav(
        uri: String,
        audioStream: Int,
        rangeStartUs: Long,
        audio: AudioPlan,
        span: AudioPlan.Span,
        wav: File,
        control: JobControl,
    ) {
        val frames = span.frames
        val buffer = PcmBlock(frames, audio.outChannels)
        if (frames > 0) {
            val (fromUs, toUs) = audio.sourceSpanUs(span, rangeStartUs)
            val stream = try {
                PcmDecoder(ctx).open(uri, audioStream, fromUs, toUs) { control.isStopRequested || control.isCancelled }
            } catch (e: EngineException) {
                // A span past the audio track's end is silence (the track is shorter than the video).
                if (e.code == EngineErrorCode.internal) null else throw e
            }
            stream?.use { pcm ->
                val mixer = ChannelFold(pcm.channels, pcm.channelMask, audio.outChannels)
                val resample = pcm.sampleRate != audio.outRate
                // Same rate: copy in place (at most `frames`, silence after the source's end).
                // Other rate: collect the span (2 s) and resample it onto exactly `frames`.
                val collected = if (resample) ArrayList<FloatArray>() else null
                while (true) {
                    control.throwIfCancelled()
                    val chunk = pcm.read() ?: break
                    val folded = mixer.fold(chunk)
                    if (collected != null) collected += folded else buffer.append(folded)
                }
                if (collected != null) buffer.fill(ReverseMath.resampleLinear(ReverseMath.concat(collected), audio.outChannels, frames))
            }
        }
        ReverseWav.write(wav, audio.outRate, audio.outChannels, buffer.samples)
    }

    /** What the job needs to know about the source. */
    class SourceFacts(
        val width: Int,
        val height: Int,
        val rotation: Int,
        val fps: Double,
        val videoEndUs: Long,
        val hdrMode: Int,
        val hasAudio: Boolean,
        val sampleRate: Int,
        val channels: Int,
    ) {
        companion object {
            /** Reads the facts of [uri]; `unsupportedMedia` without a video track. */
            fun read(context: Context, uri: String, audioStream: Int): SourceFacts {
                val extractor = MediaSources.extractor(context, uri)
                try {
                    val formats = (0 until extractor.trackCount).map { extractor.getTrackFormat(it) }
                    val video = formats.firstOrNull { it.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true }
                        ?: throw EngineException(EngineErrorCode.unsupportedMedia, "no video track")
                    val audios = formats.filter { it.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
                    val audio = audios.getOrNull(audioStream.coerceIn(0, max(0, audios.size - 1)))
                    val duration = formats.filter { it.containsKey(MediaFormat.KEY_DURATION) }.maxOfOrNull { it.getLong(MediaFormat.KEY_DURATION) }
                    val videoEnd = if (video.containsKey(MediaFormat.KEY_DURATION)) video.getLong(MediaFormat.KEY_DURATION) else duration
                        ?: throw EngineException(EngineErrorCode.unsupportedMedia, "media has no duration")
                    val fps = if (video.containsKey(MediaFormat.KEY_FRAME_RATE)) MediaFormatUtil.getFloatFromIntOrFloat(video, MediaFormat.KEY_FRAME_RATE, 30f).toDouble() else 30.0
                    val media3 = MediaFormatUtil.createFormatFromMediaFormat(video)
                    val hdrMode = if (ColorInfo.isTransferHdr(media3.colorInfo)) {
                        val engine = EngineContext.peek()
                        if (engine != null) {
                            ProxyJob.Settings.hdrMode(media3, engine.deviceProfile.codecs(), engine.deviceProfile.toneMapping())
                        } else {
                            Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL
                        }
                    } else {
                        Composition.HDR_MODE_KEEP_HDR
                    }
                    return SourceFacts(
                        width = video.getInteger(MediaFormat.KEY_WIDTH),
                        height = video.getInteger(MediaFormat.KEY_HEIGHT),
                        rotation = if (video.containsKey(MediaFormat.KEY_ROTATION)) video.getInteger(MediaFormat.KEY_ROTATION) else 0,
                        fps = if (fps.isFinite() && fps > 0) fps else 30.0,
                        videoEndUs = videoEnd,
                        hdrMode = hdrMode,
                        hasAudio = audio != null,
                        sampleRate = audio?.getInteger(MediaFormat.KEY_SAMPLE_RATE) ?: 0,
                        channels = audio?.getInteger(MediaFormat.KEY_CHANNEL_COUNT) ?: 0,
                    )
                } finally {
                    extractor.release()
                }
            }
        }
    }

    companion object {
        private const val STOP_POLL_MS = 100L
    }
}

// ---------------------------------------------------------------------------------------------
// Pure parts (JVM-tested in src/test/.../reverse/).
// ---------------------------------------------------------------------------------------------

/** Sizing, preflight and sample arithmetic of the reverse job (pure). */
object ReverseMath {
    /** Longest reversible range (ARCH §15 preflight). */
    const val MAX_RANGE_US = 600_000_000L

    /** Target source duration of one chunk. */
    const val DEFAULT_CHUNK_US = 2_000_000L

    /** Shortest chunk the job accepts (test hook floor). */
    const val MIN_CHUNK_US = 100_000L

    /** Audio is reversed in blocks of this many frames. */
    const val AUDIO_BLOCK_FRAMES = 65_536

    /** AAC bit rate of the rendition. */
    const val AUDIO_BIT_RATE = 128_000

    /** Free-space slack of the preflight. */
    const val SLACK_BYTES = 64L * 1024 * 1024

    /** Message token of the range refusal (Dart: `LimitExceeded('reverseRange')`, same as iOS). */
    const val RANGE_LIMIT_TOKEN = "reverseRange"

    /** The range refusal of [rangeUs] (> 10 min), else nothing. */
    fun checkRange(rangeUs: Long) {
        if (rangeUs <= 0) throw EngineErrors.invalidArgument("range", "empty reverse range")
        if (rangeUs > MAX_RANGE_US) throw EngineException(EngineErrorCode.unsupportedMedia, "limitExceeded $RANGE_LIMIT_TOKEN $MAX_RANGE_US")
    }

    /** Whether [error] is the range refusal. */
    fun isRangeLimit(error: Throwable): Boolean {
        val e = EngineErrors.from(error)
        return e.code == EngineErrorCode.unsupportedMedia && e.message.orEmpty().contains(RANGE_LIMIT_TOKEN)
    }

    /** The ARCH §15 preflight: range cap, then free space >= 2 x estimate + one chunk + 64 MB. */
    fun preflight(rangeUs: Long, estimatedOutputBytes: Long, chunkBytes: Long, freeBytes: Long) {
        checkRange(rangeUs)
        val needed = 2 * estimatedOutputBytes + chunkBytes + SLACK_BYTES
        if (freeBytes < needed) throw EngineException(EngineErrorCode.diskFull, "not enough space for the reversed clip")
    }

    /** Output video bit rate: about 0.1 bit per pixel per frame, 2..40 Mbit/s (same as iOS). */
    fun outputBitRate(width: Int, height: Int, fps: Double): Int =
        (width.toDouble() * height * max(1.0, fps) * 0.1).coerceIn(2_000_000.0, 40_000_000.0).toInt()

    /** All-intra intermediate bit rate: about 0.3 bit per pixel per frame, 8..150 Mbit/s (same as iOS). */
    fun intermediateBitRate(width: Int, height: Int, fps: Double): Int =
        (width.toDouble() * height * max(1.0, fps) * 0.3).coerceIn(8_000_000.0, 150_000_000.0).toInt()

    /** Bytes of [bitRate] over [durationUs]. */
    fun bytes(bitRate: Int, durationUs: Long): Long = (bitRate.toDouble() / 8 * durationUs / 1_000_000).toLong()

    /** [v] rounded down to even, at least 2. */
    fun even(v: Int): Int = max(2, v - v % 2)

    /** The smallest free space of the file systems holding [dirs] (each resolved to its nearest existing ancestor). */
    fun freeBytes(dirs: List<File>): Long {
        var best = Long.MAX_VALUE
        for (dir in dirs) {
            var d: File? = dir
            while (d != null && !d.isDirectory) d = d.parentFile
            if (d == null) continue
            best = min(best, StatFs(d.path).availableBytes)
        }
        return if (best == Long.MAX_VALUE) 0L else best
    }

    /** Total bytes of the files below [dir]. */
    fun directoryBytes(dir: File): Long = dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }

    /** Reverses the frame order of interleaved [samples] of [channels] channels in place. */
    fun reverseFrames(samples: ShortArray, channels: Int, frames: Int = samples.size / channels) {
        var i = 0
        var j = frames - 1
        while (i < j) {
            for (c in 0 until channels) {
                val a = i * channels + c
                val b = j * channels + c
                val t = samples[a]
                samples[a] = samples[b]
                samples[b] = t
            }
            i++
            j--
        }
    }

    /** [samples] (interleaved, [channels]) linearly resampled onto exactly [frames] frames. */
    fun resampleLinear(samples: FloatArray, channels: Int, frames: Int): FloatArray {
        val inFrames = samples.size / channels
        val out = FloatArray(frames * channels)
        if (inFrames == 0 || frames == 0) return out
        if (inFrames == frames) return samples.copyOf(frames * channels)
        val step = inFrames.toDouble() / frames
        for (f in 0 until frames) {
            val pos = f * step
            val i0 = min(inFrames - 1, pos.toInt())
            val i1 = min(inFrames - 1, i0 + 1)
            val t = (pos - i0).toFloat()
            for (c in 0 until channels) out[f * channels + c] = samples[i0 * channels + c] * (1 - t) + samples[i1 * channels + c] * t
        }
        return out
    }

    /** The arrays of [parts] joined. */
    fun concat(parts: List<FloatArray>): FloatArray {
        val out = FloatArray(parts.sumOf { it.size })
        var at = 0
        for (p in parts) {
            p.copyInto(out, at)
            at += p.size
        }
        return out
    }

    /** AAC sampling-frequency index of [rate], or -1 when AAC has none. */
    fun aacFrequencyIndex(rate: Int): Int = AAC_RATES.indexOf(rate)

    /** The 2-byte AAC-LC AudioSpecificConfig of [rate] and [channels] (ISO 14496-3 §1.6.2.1). */
    fun aacLcConfig(rate: Int, channels: Int): ByteArray {
        val index = aacFrequencyIndex(rate)
        require(index >= 0) { "no AAC sampling-frequency index" }
        require(channels in 1..7) { "channels" }
        val objectType = 2 // AAC LC
        return byteArrayOf(
            ((objectType shl 3) or (index shr 1)).toByte(),
            (((index and 1) shl 7) or (channels shl 3)).toByte(),
        )
    }

    /** The AAC rates an encoder is asked for (others are resampled to 48 kHz). */
    val ENCODER_RATES = setOf(8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000)

    private val AAC_RATES = listOf(96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350)

    /**
     * The priming (frames) the platform's software AAC encoder adds. Media3's Transformer assumes 1600
     * for c2.android.aac.encoder (DefaultCodec); measured on the API 35 emulator (AND-07 clap test,
     * 2026-10-14) the decoded audio lags by 2048 frames (with 1600 every click was 447 frames, 9.3 ms,
     * late), so the platform FDK encoders use 2048. Other (vendor) encoders: 0, as Media3.
     */
    fun aacEncoderDelayFrames(codecName: String): Int =
        if (codecName == "c2.android.aac.encoder" || codecName == "OMX.google.aac.encoder") 2048 else 0

    /** Muxer time of AAC access unit [index] (1024 frames each) at [rate], minus the encoder [delayFrames]. */
    fun aacUnitPtsUs(index: Long, rate: Int, delayFrames: Int): Long =
        Math.floorDiv(index * 1024L * 1_000_000L, rate.toLong()) - Math.floorDiv(delayFrames * 1_000_000L, rate.toLong())
}

/**
 * The frames of a source range and their mirrored output times, plus the chunk plan (pure).
 * Built from the video samples in decode order ([decodePts], [decodeSync]) of a scan that starts
 * at a sync sample at or before the range start.
 */
class ReverseTimeline(
    val decodePts: LongArray,
    val decodeSync: BooleanArray,
    /** End of the last frame of the track (its duration). */
    val trackEndUs: Long,
    val rangeStartUs: Long,
    val rangeEndUs: Long,
) {
    /** A source frame: PTS, end (next PTS capped at the range end), mirrored output PTS. */
    class Frame(val ptsUs: Long, val endUs: Long, val outPtsUs: Long, val sync: Boolean, val decodeIndex: Int)

    /**
     * Frames [first, last] (source order) of one chunk. The intermediate clips the source to
     * [clipStartUs, clipEndUs); the chunk fills output [outStartUs, outEndUs).
     */
    class Chunk(val first: Int, val last: Int, val clipStartUs: Long, val clipEndUs: Long, val outStartUs: Long, val outEndUs: Long) {
        val frameCount: Int get() = last - first + 1
    }

    /** Output duration. */
    val durationUs: Long = rangeEndUs - rangeStartUs

    /** Frames overlapping the range, in source order. */
    val frames: List<Frame> = buildFrames()

    private fun buildFrames(): List<Frame> {
        // Unique PTS in presentation order with their first decode index.
        val order = decodePts.indices.sortedWith(compareBy({ decodePts[it] }, { it }))
        val pts = ArrayList<Long>()
        val index = ArrayList<Int>()
        for (d in order) {
            if (pts.isNotEmpty() && pts.last() == decodePts[d]) continue
            pts += decodePts[d]
            index += d
        }
        val out = ArrayList<Frame>()
        for (i in pts.indices) {
            val p = pts[i]
            val next = if (i + 1 < pts.size) pts[i + 1] else max(trackEndUs, p + 1)
            val end = min(next, rangeEndUs)
            if (p >= rangeEndUs || end <= rangeStartUs) continue
            out += Frame(p, end, rangeEndUs - end, decodeSync[index[i]], index[i])
        }
        return out
    }

    /** The chunk plan in output order (the end of the range first); see the file header. */
    fun chunks(targetUs: Long): List<Chunk> {
        val n = frames.size
        val out = ArrayList<Chunk>()
        var end = n
        while (end > 0) {
            val chunkEnd = frames[end - 1].endUs
            val target = chunkEnd - targetUs
            var s = end - 1
            while (s > 0 && frames[s - 1].ptsUs >= target) s--
            // GOP alignment: the latest sync frame at or before s that keeps the chunk <= 2 x target.
            var k = s
            while (k >= 0 && chunkEnd - frames[k].ptsUs <= 2 * targetUs) {
                if (frames[k].sync) {
                    s = k
                    break
                }
                k--
            }
            out += chunk(s, end - 1)
            end = s
        }
        return out
    }

    private fun chunk(first: Int, last: Int): Chunk {
        val clipStart = frames[first].ptsUs
        val endExclusive = if (last + 1 < frames.size) frames[last + 1].ptsUs else frames[last].ptsUs + 1
        // The decode start: the latest sync sample (decode order) at or before the first frame.
        var decodeStart = frames[first].decodeIndex
        while (decodeStart > 0 && !(decodeSync[decodeStart] && decodePts[decodeStart] <= clipStart)) decodeStart--
        var lastNeeded = decodeStart
        for (i in first..last) lastNeeded = max(lastNeeded, frames[i].decodeIndex)
        // A sample at or past the clip end read before a needed frame would end the clipped stream.
        var clipEnd = endExclusive
        for (d in decodeStart..lastNeeded) if (decodePts[d] >= endExclusive) clipEnd = max(clipEnd, decodePts[d] + 1)
        val outStart = if (last == frames.size - 1) 0L else frames[last].outPtsUs
        val outEnd = if (first == 0) durationUs else frames[first - 1].outPtsUs
        return Chunk(first, last, clipStart, clipEnd, outStart, outEnd)
    }

    companion object {
        /** Margin scanned after the range end (the next frame's PTS, B-frame reordering). */
        private const val SCAN_SYNCS_AFTER = 2

        /** Scans the video samples of [uri] around [rangeStartUs, rangeEndUs) (no decoding). */
        fun scan(context: Context, uri: String, rangeStartUs: Long, rangeEndUs: Long, trackEndUs: Long, control: JobControl?): ReverseTimeline {
            val extractor = MediaSources.extractor(context, uri)
            try {
                val track = (0 until extractor.trackCount).firstOrNull {
                    extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
                } ?: throw EngineException(EngineErrorCode.unsupportedMedia, "no video track")
                extractor.selectTrack(track)
                extractor.seekTo(rangeStartUs, MediaExtractorCompat.SEEK_TO_PREVIOUS_SYNC)
                val pts = LongList()
                val sync = ArrayList<Boolean>()
                var syncsAfter = 0
                var count = 0
                while (true) {
                    val t = extractor.sampleTime
                    if (t < 0) break
                    val isSync = (extractor.sampleFlags and android.media.MediaExtractor.SAMPLE_FLAG_SYNC) != 0
                    if (isSync && t > rangeEndUs && ++syncsAfter >= SCAN_SYNCS_AFTER) break
                    pts.add(t)
                    sync += isSync
                    if (++count % 256 == 0) control?.throwIfCancelled()
                    if (!extractor.advance()) break
                }
                return ReverseTimeline(pts.toArray(), sync.toBooleanArray(), trackEndUs, rangeStartUs, rangeEndUs)
            } finally {
                extractor.release()
            }
        }
    }
}

/** A growable LongArray. */
private class LongList {
    private var data = LongArray(256)
    var size = 0
        private set

    fun add(v: Long) {
        if (size == data.size) data = data.copyOf(size * 2)
        data[size++] = v
    }

    fun toArray(): LongArray = data.copyOf(size)
}

/** The audio side of the rendition: output layout and per-chunk frame spans (pure). */
class AudioPlan(
    /** Source sample rate. */
    val sourceRate: Int,
    /** Rate of the WAV and the AAC (the source rate when AAC encoders take it, else 48 kHz). */
    val outRate: Int,
    /** Channels of the WAV and the AAC: 2 for stereo sources, else 1. */
    val outChannels: Int,
    /** Frames of the whole output at [outRate]. */
    val totalFrames: Long,
) {
    /** Output frames [from, to) of one chunk. */
    data class Span(val from: Long, val to: Long) {
        val frames: Int get() = (to - from).toInt()
    }

    /** The span of output [outStartUs, outEndUs) (the last chunk ends at [totalFrames]). */
    fun span(outStartUs: Long, outEndUs: Long, durationUs: Long): Span {
        val from = if (outStartUs <= 0) 0L else frameAt(outStartUs)
        val to = if (outEndUs >= durationUs) totalFrames else frameAt(outEndUs)
        return Span(from, max(from, to))
    }

    /**
     * The source times [from, to) holding [span]'s frames: output frames [a, b) are the
     * source-relative frames [N - b, N - a) after [rangeStartUs] (floored to µs: PcmTrim's 0.2-frame
     * tolerance then starts and ends on those exact frames).
     */
    fun sourceSpanUs(span: Span, rangeStartUs: Long): Pair<Long, Long> {
        val first = totalFrames - span.to
        val end = totalFrames - span.from
        return Pair(rangeStartUs + Math.floorDiv(first * 1_000_000L, outRate.toLong()), rangeStartUs + Math.floorDiv(end * 1_000_000L, outRate.toLong()))
    }

    private fun frameAt(us: Long): Long = (us.toDouble() * outRate / 1_000_000.0).roundToLong()

    companion object {
        /** The plan for a source of [rate] Hz and [channels] channels over [durationUs]. */
        fun of(rate: Int, channels: Int, durationUs: Long): AudioPlan {
            val outRate = if (rate in ReverseMath.ENCODER_RATES) rate else 48_000
            val outChannels = if (channels == 2) 2 else 1
            return AudioPlan(rate, outRate, outChannels, (durationUs.toDouble() * outRate / 1_000_000.0).roundToLong())
        }
    }
}

/** Folds decoded PCM to the plan's channels: mono and stereo kept, other layouts mixed to mono (AND-04 Downmix). */
private class ChannelFold(private val channels: Int, channelMask: Int, private val outChannels: Int) {
    private val coefficients = Downmix.coefficients(channels, channelMask)

    fun fold(samples: FloatArray): FloatArray = when {
        channels == outChannels -> samples
        outChannels == 1 -> Downmix.mono(samples, channels, coefficients)
        else -> {
            // Mono source into stereo: duplicate (not used by AudioPlan, kept total).
            val frames = samples.size / channels
            FloatArray(frames * 2) { samples[(it / 2) * channels] }
        }
    }
}

/** A fixed-size s16 block filled from float PCM; frames past what was appended stay silent. */
private class PcmBlock(frames: Int, private val channels: Int) {
    val samples = ShortArray(frames * channels)
    private var at = 0

    fun append(chunk: FloatArray) {
        val n = min(chunk.size, samples.size - at)
        for (i in 0 until n) samples[at + i] = PcmConvert.toS16(chunk[i])
        at += n
    }

    fun fill(all: FloatArray) {
        at = 0
        append(all)
    }
}

/** A 16-bit PCM WAV of any channel count: written whole, read back in frame blocks. */
object ReverseWav {
    /** Header bytes. */
    const val HEADER_BYTES = 44

    /** RIFF/WAVE header of PCM s16 [channels] at [rate] with [dataBytes]. */
    fun header(rate: Int, channels: Int, dataBytes: Long): ByteArray {
        val b = ByteBuffer.allocate(HEADER_BYTES).order(ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray(Charsets.US_ASCII))
        b.putInt((36 + dataBytes).toInt())
        b.put("WAVE".toByteArray(Charsets.US_ASCII))
        b.put("fmt ".toByteArray(Charsets.US_ASCII))
        b.putInt(16)
        b.putShort(1)
        b.putShort(channels.toShort())
        b.putInt(rate)
        b.putInt(rate * channels * 2)
        b.putShort((channels * 2).toShort())
        b.putShort(16)
        b.put("data".toByteArray(Charsets.US_ASCII))
        b.putInt(dataBytes.toInt())
        return b.array()
    }

    /** Writes [samples] (interleaved s16) as a WAV. */
    fun write(file: File, rate: Int, channels: Int, samples: ShortArray) {
        try {
            FileOutputStream(file).use { out ->
                out.write(header(rate, channels, samples.size * 2L))
                val bytes = ByteBuffer.allocate(64 * 1024).order(ByteOrder.LITTLE_ENDIAN)
                var i = 0
                while (i < samples.size) {
                    bytes.clear()
                    while (i < samples.size && bytes.remaining() >= 2) bytes.putShort(samples[i++])
                    out.write(bytes.array(), 0, bytes.position())
                }
            }
        } catch (e: IOException) {
            throw EngineErrors.from(e)
        }
    }

    /** Frames of [file] ([channels] channels). */
    fun frames(file: File, channels: Int): Long = max(0L, (file.length() - HEADER_BYTES) / (2L * channels))

    /** Reads frames [from, from + count) of [file] into a new array. */
    fun read(file: RandomAccessFile, channels: Int, from: Long, count: Int): ShortArray {
        val bytes = ByteArray(count * channels * 2)
        file.seek(HEADER_BYTES + from * channels * 2)
        file.readFully(bytes)
        val out = ShortArray(count * channels)
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(out)
        return out
    }
}

// ---------------------------------------------------------------------------------------------
// Stage b and the output: decoder -> YUV image copy -> encoder -> Mp4Muxer, AAC encoder.
// ---------------------------------------------------------------------------------------------

/**
 * The rendition writer: one H.264 encoder, one AAC encoder, one Mp4Muxer, and a decoder reused
 * across chunks. Decoded frames are copied as flexible YUV 4:2:0 images (MediaCodec
 * `getOutputImage` -> `getInputImage`), never through a Surface: a decoder's Surface buffers are
 * not always a format the encoder's input Surface accepts (API 29 emulator: the goldfish decoder's
 * YUV420Planar buffers make OMX.google.h264.encoder fail), while flexible YUV images work for any
 * codec pair and hold one decoded frame at a time.
 */
private class ReverseWriter(
    part: File,
    private val bitRate: Int,
    private val fps: Double,
    private val audio: AudioPlan?,
    private val control: JobControl,
) : Closeable {
    private val stream = FileOutputStream(part)
    private val muxer: Mp4Muxer = Mp4Muxer.Builder(stream)
        .setSampleCopyingEnabled(true)
        .setLastSampleDurationBehavior(Mp4Muxer.LAST_SAMPLE_DURATION_BEHAVIOR_SET_FROM_END_OF_STREAM_BUFFER_OR_DUPLICATE_PREVIOUS)
        .build()
    private var encoder: MediaCodec? = null
    private var encoderWidth = 0
    private var encoderHeight = 0
    private var decoder: MediaCodec? = null
    private var decoderMime: String? = null
    private var decoderSize: Pair<Int, Int>? = null
    private var softwareDecoder = false
    private var decoderHasInput = false
    private var copiedByDecoder = 0L
    private var videoTrack = -1
    private var audioTrack = -1
    private var videoFormat: Format? = null
    private var rotation = 0
    private var copied = 0L
    private var encodedVideo = 0L
    private var lastVideoPts = Long.MIN_VALUE
    private val info = MediaCodec.BufferInfo()
    private val encoderInfo = MediaCodec.BufferInfo()
    private var closedMuxer = false
    private var loggedLayout = false

    // Audio.
    private var aac: MediaCodec? = null
    private var aacDelay = 0
    private var aacUnits = 0L
    private var aacInputFrames = 0L
    private var aacEos = false

    /** The decoder delivered no flexible YUV image (some vendor decoders): retry with a software decoder. */
    private class NoYuvImage : RuntimeException()

    init {
        if (audio != null) startAac(audio)
    }

    private fun check() = control.throwIfCancelled()

    // ---- video ----

    /**
     * Feeds the frames of [chunk] from [intermediate] in reverse order and encodes them. Returns the
     * number of chunk frames the intermediate did not deliver.
     */
    fun writeVideoChunk(context: Context, intermediate: File, timeline: ReverseTimeline, chunk: ReverseTimeline.Chunk): Int {
        val extractor = MediaSources.extractor(context, intermediate.absolutePath)
        try {
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
            } ?: throw EngineException(EngineErrorCode.decodeFailed, "the reverse intermediate has no video")
            val format = extractor.getTrackFormat(track)
            extractor.selectTrack(track)
            val samples = ArrayList<Pair<Long, Boolean>>()
            while (true) {
                val t = extractor.sampleTime
                if (t < 0) break
                samples += Pair(t, (extractor.sampleFlags and android.media.MediaExtractor.SAMPLE_FLAG_SYNC) != 0)
                if (!extractor.advance()) break
            }
            if (samples.isEmpty()) throw EngineException(EngineErrorCode.decodeFailed, "the reverse intermediate is empty")
            val sorted = samples.map { it.first }.sorted()
            val allIntra = samples.all { it.second }
            if (!loggedLayout) {
                loggedLayout = true
                Log.i(EngineContext.TAG, "reverse intermediate: ${samples.size} samples, ${samples.count { it.second }} sync" + if (allIntra) " (all-intra)" else " (decoding from sync per frame)")
            }
            val mapping = IntermediateMapping.of(sorted.toLongArray(), timeline.frames.subList(chunk.first, chunk.last + 1).map { it.ptsUs }.toLongArray(), chunk.clipStartUs)
            ensureEncoder(format)
            while (true) {
                ensureDecoder(format)
                try {
                    return feedChunk(extractor, timeline, chunk, mapping, allIntra)
                } catch (e: NoYuvImage) {
                    if (softwareDecoder) throw EngineException(EngineErrorCode.decodeFailed, "no decoder delivers YUV images")
                    Log.w(EngineContext.TAG, "reverse: the decoder has no YUV image output; using a software decoder")
                    releaseDecoder()
                    softwareDecoder = true
                }
            }
        } finally {
            extractor.release()
        }
    }

    private fun feedChunk(
        extractor: MediaExtractorCompat,
        timeline: ReverseTimeline,
        chunk: ReverseTimeline.Chunk,
        mapping: IntermediateMapping,
        allIntra: Boolean,
    ): Int {
        var lost = 0
        // (intermediate PTS, output PTS) in output order.
        val targets = ArrayList<Pair<Long, Long>>()
        for (i in chunk.last downTo chunk.first) {
            val q = mapping.intermediatePts[i - chunk.first]
            if (q == null) lost++ else targets += Pair(q, timeline.frames[i].outPtsUs)
        }
        if (allIntra) {
            for ((q, outPts) in targets) {
                check()
                lost += feedIntra(extractor, q, outPts)
            }
        } else {
            for (block in targets.chunked(blockFrames())) {
                check()
                lost += feedBlock(extractor, block)
            }
        }
        endDecoderRun()
        return lost
    }

    private fun ensureEncoder(intermediate: MediaFormat) {
        if (encoder != null) return
        val w = intermediate.getInteger(MediaFormat.KEY_WIDTH)
        val h = intermediate.getInteger(MediaFormat.KEY_HEIGHT)
        rotation = if (intermediate.containsKey(MediaFormat.KEY_ROTATION)) intermediate.getInteger(MediaFormat.KEY_ROTATION) else 0
        val format = MediaFormat.createVideoFormat(MimeTypes.VIDEO_H264, w, h).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_FRAME_RATE, max(1, Math.round(fps).toInt()))
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(format)
            ?: throw if (anyEncoder(MimeTypes.VIDEO_H264)) EngineException(EngineErrorCode.encoderSizeLimit, "no H.264 encoder takes ${w}x$h") else EngineException(EngineErrorCode.encoderUnavailable, "no H.264 encoder")
        val codec = try {
            MediaCodec.createByCodecName(name)
        } catch (e: IOException) {
            throw EngineException(EngineErrorCode.encoderUnavailable, "H.264 encoder unavailable", cause = e)
        }
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
        } catch (e: RuntimeException) {
            codec.release()
            throw EngineException(EngineErrorCode.encoderUnavailable, "H.264 encoder did not start", cause = e)
        }
        encoder = codec
        encoderWidth = w
        encoderHeight = h
    }

    private fun anyEncoder(mime: String): Boolean =
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.any { info -> info.isEncoder && info.supportedTypes.any { it.equals(mime, true) } }

    private fun ensureDecoder(format: MediaFormat) {
        val mime = format.getString(MediaFormat.KEY_MIME)!!
        val size = Pair(format.getInteger(MediaFormat.KEY_WIDTH), format.getInteger(MediaFormat.KEY_HEIGHT))
        val existing = decoder
        if (existing != null && mime == decoderMime && size == decoderSize) {
            // Same stream layout: continue with this chunk's parameter sets (flushed after the last run).
            queueCodecConfig(existing, format)
            return
        }
        existing?.let { releaseDecoder() }
        format.setInteger(MediaFormat.KEY_ROTATION, 0)
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
        val name = if (softwareDecoder) {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull { info ->
                !info.isEncoder && Codecs.isSoftware(info) && info.supportedTypes.any { it.equals(mime, true) }
            }?.name
        } else {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(format)
        }
        val codec = try {
            if (name != null) MediaCodec.createByCodecName(name) else MediaCodec.createDecoderByType(mime)
        } catch (e: IOException) {
            throw EngineException(EngineErrorCode.decoderInitFailed, "decoder unavailable", cause = e)
        }
        try {
            codec.configure(format, null, null, 0)
            codec.start()
        } catch (e: RuntimeException) {
            codec.release()
            throw EngineException(EngineErrorCode.decoderInitFailed, "decoder did not start", cause = e)
        }
        decoder = codec
        decoderMime = mime
        decoderSize = size
        decoderHasInput = false
        copiedByDecoder = 0
    }

    private fun queueCodecConfig(codec: MediaCodec, format: MediaFormat) {
        val csd = listOf("csd-0", "csd-1").mapNotNull { key -> if (format.containsKey(key)) format.getByteBuffer(key) else null }
        if (csd.isEmpty()) return
        val index = dequeueInput(codec)
        val buffer = codec.getInputBuffer(index)!!
        buffer.clear()
        for (b in csd) buffer.put(b.duplicate().apply { rewind() })
        codec.queueInputBuffer(index, 0, buffer.position(), 0, MediaCodec.BUFFER_FLAG_CODEC_CONFIG)
    }

    /** All-intra: the sample at [q] alone decodes to its frame. Returns the frames lost (0 or 1). */
    private fun feedIntra(extractor: MediaExtractorCompat, q: Long, outPts: Long): Int {
        extractor.seekTo(q, MediaExtractorCompat.SEEK_TO_PREVIOUS_SYNC)
        if (extractor.sampleTime != q) return feedBlock(extractor, listOf(Pair(q, outPts)))
        queueSample(extractor, outPts)
        drainDecoder(false)
        drainEncoder(false)
        return 0
    }

    /** Frames decoded per pass when the intermediate is not all-intra (YUV copies within [BLOCK_BYTES]). */
    private fun blockFrames(): Int {
        val frameBytes = max(1L, encoderWidth.toLong() * encoderHeight * 3 / 2)
        return (BLOCK_BYTES / frameBytes).toInt().coerceIn(1, MAX_BLOCK_FRAMES)
    }

    /**
     * General case (the intermediate's encoder ignored the all-intra request): decode forward once
     * from the sync sample before the block's earliest frame to its latest, keep YUV copies of the
     * block's frames, then encode them in output order. [block] is (intermediate PTS, output PTS)
     * in output order (intermediate PTS descending). Returns the frames the decoder did not deliver.
     */
    private fun feedBlock(extractor: MediaExtractorCompat, block: List<Pair<Long, Long>>): Int {
        endDecoderRun()
        val last = block.first().first
        val first = block.last().first
        extractor.seekTo(first, MediaExtractorCompat.SEEK_TO_PREVIOUS_SYNC)
        val collected = HashMap<Long, YuvFrame>()
        val wanted = block.mapTo(HashSet()) { it.first }
        collect = { image, pts ->
            if (pts in wanted) {
                val frame = pool.removeLastOrNull() ?: YuvFrame(encoderWidth, encoderHeight)
                YuvCopy.toFrame(image, frame)
                collected.put(pts, frame)?.let { pool += it }
            }
        }
        try {
            // Decode order up to and including the block's latest sample.
            while (true) {
                check()
                val t = extractor.sampleTime
                if (t < 0) break
                queueSample(extractor, t)
                extractor.advance()
                drainDecoder(false)
                drainEncoder(false)
                if (t == last) break
            }
            endDecoderRun()
        } finally {
            collect = null
        }
        var lost = 0
        for ((q, outPts) in block) {
            val frame = collected.remove(q)
            if (frame == null) {
                lost++
                continue
            }
            encodeYuv(frame, outPts)
            pool += frame
        }
        pool += collected.values
        return lost
    }

    /** In block mode: where decoded frames go (by their intermediate PTS) instead of the encoder. */
    private var collect: ((android.media.Image, Long) -> Unit)? = null

    /** Reused YUV copies of block mode (at most one block's worth). */
    private val pool = ArrayList<YuvFrame>()

    private fun queueSample(extractor: MediaExtractorCompat, ptsUs: Long) {
        val codec = decoder!!
        val index = dequeueInput(codec)
        val buffer = codec.getInputBuffer(index)!!
        buffer.clear()
        val size = extractor.readSampleData(buffer, 0)
        if (size < 0) throw EngineException(EngineErrorCode.decodeFailed, "intermediate sample unreadable")
        codec.queueInputBuffer(index, 0, size, ptsUs, 0)
        decoderHasInput = true
    }

    private fun dequeueInput(codec: MediaCodec): Int {
        val deadline = System.nanoTime() + CODEC_TIMEOUT_NS
        while (true) {
            check()
            val index = codec.dequeueInputBuffer(DEQUEUE_US)
            if (index >= 0) return index
            if (codec === decoder) drainDecoder(false)
            drainEncoder(false)
            if (aac != null && codec === aac) drainAac(false)
            if (System.nanoTime() > deadline) throw EngineException(EngineErrorCode.decodeFailed, "codec input timed out", retryable = true)
        }
    }

    /** Copies decoded frames to the encoder; with [untilEos] waits for the decoder's end of stream. */
    private fun drainDecoder(untilEos: Boolean) {
        val codec = decoder ?: return
        val deadline = System.nanoTime() + CODEC_TIMEOUT_NS
        while (true) {
            val index = codec.dequeueOutputBuffer(info, if (untilEos) DEQUEUE_US else 0)
            when {
                index >= 0 -> {
                    val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    if (info.size > 0) {
                        val pts = info.presentationTimeUs
                        val image = codec.getOutputImage(index)
                        if (image == null) {
                            codec.releaseOutputBuffer(index, false)
                            if (copiedByDecoder == 0L) throw NoYuvImage()
                            throw EngineException(EngineErrorCode.decodeFailed, "decoded frame unavailable")
                        }
                        try {
                            val sink = collect
                            if (sink != null) sink(image, pts) else encodeFrame(image, pts)
                        } finally {
                            image.close()
                        }
                        copiedByDecoder++
                    }
                    codec.releaseOutputBuffer(index, false)
                    if (eos) return
                }
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!untilEos) return
                    check()
                    drainEncoder(false)
                    if (System.nanoTime() > deadline) throw EngineException(EngineErrorCode.decodeFailed, "decoder output timed out", retryable = true)
                }
                else -> Unit // format or buffer changes
            }
        }
    }

    /** Copies [image] into the encoder's next input at [ptsUs]. */
    private fun encodeFrame(image: android.media.Image, ptsUs: Long) {
        val codec = encoder!!
        val index = dequeueInput(codec)
        val target = codec.getInputImage(index) ?: throw EngineException(EngineErrorCode.encoderUnavailable, "the H.264 encoder takes no YUV images")
        YuvCopy.copy(image, target, encoderWidth, encoderHeight)
        codec.queueInputBuffer(index, 0, encoderWidth * encoderHeight * 3 / 2, ptsUs, 0)
        copied++
    }

    /** Copies a block-mode [frame] into the encoder's next input at [ptsUs]. */
    private fun encodeYuv(frame: YuvFrame, ptsUs: Long) {
        val codec = encoder!!
        val index = dequeueInput(codec)
        val target = codec.getInputImage(index) ?: throw EngineException(EngineErrorCode.encoderUnavailable, "the H.264 encoder takes no YUV images")
        YuvCopy.fromFrame(frame, target)
        codec.queueInputBuffer(index, 0, encoderWidth * encoderHeight * 3 / 2, ptsUs, 0)
        copied++
    }

    /** Ends the decoder's current run: end of stream, drain, flush (ready for the next chunk or frame). */
    private fun endDecoderRun() {
        val codec = decoder ?: return
        if (!decoderHasInput) return
        val index = dequeueInput(codec)
        codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        drainDecoder(true)
        codec.flush()
        decoderHasInput = false
    }

    /** Writes encoded video; returns whether anything was written. With [untilEos] waits for the end of stream. */
    private fun drainEncoder(untilEos: Boolean): Boolean {
        val codec = encoder ?: return false
        var wrote = false
        val deadline = System.nanoTime() + CODEC_TIMEOUT_NS
        while (true) {
            val index = codec.dequeueOutputBuffer(encoderInfo, if (untilEos) DEQUEUE_US else 0)
            when {
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    videoFormat = MediaFormatUtil.createFormatFromMediaFormat(codec.outputFormat)
                    addTracks()
                }
                index >= 0 -> {
                    val eos = encoderInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    if (encoderInfo.size > 0 && encoderInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                        if (videoTrack < 0) throw EngineException(EngineErrorCode.encodingFailed, "encoder output before its format")
                        val buffer = codec.getOutputBuffer(index)!!
                        buffer.position(encoderInfo.offset)
                        buffer.limit(encoderInfo.offset + encoderInfo.size)
                        if (encoderInfo.presentationTimeUs > lastVideoPts) {
                            val flags = if (encoderInfo.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0) C.BUFFER_FLAG_KEY_FRAME else 0
                            write(videoTrack, buffer, BufferInfo(encoderInfo.presentationTimeUs, encoderInfo.size, flags))
                            lastVideoPts = encoderInfo.presentationTimeUs
                        }
                        encodedVideo++
                        wrote = true
                    }
                    codec.releaseOutputBuffer(index, false)
                    if (eos) return wrote
                }
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!untilEos) return wrote
                    check()
                    if (System.nanoTime() > deadline) throw EngineException(EngineErrorCode.encodingFailed, "encoder output timed out", retryable = true)
                }
                else -> Unit
            }
        }
    }

    /** Writes a sample; muxer failures map to `io`/`diskFull` (file errors) or `encodingFailed`. */
    private fun write(track: Int, buffer: ByteBuffer, sample: BufferInfo) {
        try {
            muxer.writeSampleData(track, buffer, sample)
        } catch (e: androidx.media3.muxer.MuxerException) {
            val io = generateSequence(e.cause) { it.cause }.firstOrNull { it is IOException }
            throw if (io != null) EngineErrors.from(io) else EngineException(EngineErrorCode.encodingFailed, "the reversed clip could not be written", cause = e)
        }
    }

    private fun addTracks() {
        if (videoTrack >= 0) return
        val video = videoFormat ?: return
        videoTrack = muxer.addTrack(video)
        if (audio != null) audioTrack = muxer.addTrack(aacFormat(audio))
    }

    /** Waits until the video track exists (audio may only be written after it). */
    private fun awaitVideoTrack() {
        val deadline = System.nanoTime() + CODEC_TIMEOUT_NS
        while (videoTrack < 0) {
            check()
            if (!drainEncoder(false)) Thread.sleep(2)
            if (System.nanoTime() > deadline) throw EngineException(EngineErrorCode.encodingFailed, "encoder format timed out", retryable = true)
        }
    }

    // ---- audio ----

    private fun startAac(plan: AudioPlan) {
        val format = MediaFormat.createAudioFormat(MimeTypes.AUDIO_AAC, plan.outRate, plan.outChannels).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, ReverseMath.AUDIO_BIT_RATE)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16 * 1024)
        }
        val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(format)
            ?: throw EngineException(EngineErrorCode.encoderUnavailable, "no AAC encoder")
        val codec = try {
            MediaCodec.createByCodecName(name)
        } catch (e: IOException) {
            throw EngineException(EngineErrorCode.encoderUnavailable, "AAC encoder unavailable", cause = e)
        }
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
        } catch (e: RuntimeException) {
            codec.release()
            throw EngineException(EngineErrorCode.encoderUnavailable, "AAC encoder did not start", cause = e)
        }
        aac = codec
        aacDelay = ReverseMath.aacEncoderDelayFrames(codec.name)
    }

    private fun aacFormat(plan: AudioPlan): Format = Format.Builder()
        .setSampleMimeType(MimeTypes.AUDIO_AAC)
        .setSampleRate(plan.outRate)
        .setChannelCount(plan.outChannels)
        .setAverageBitrate(ReverseMath.AUDIO_BIT_RATE)
        .setInitializationData(listOf(ReverseMath.aacLcConfig(plan.outRate, plan.outChannels)))
        .build()

    /** Feeds [wav] backwards (64k-frame blocks, each reversed) to the AAC encoder. */
    fun writeAudioChunk(wav: File, plan: AudioPlan) {
        val codec = aac ?: return
        awaitVideoTrack()
        val channels = plan.outChannels
        val total = ReverseWav.frames(wav, channels)
        RandomAccessFile(wav, "r").use { file ->
            var end = total
            while (end > 0) {
                check()
                val count = min(ReverseMath.AUDIO_BLOCK_FRAMES.toLong(), end).toInt()
                val block = ReverseWav.read(file, channels, end - count, count)
                ReverseMath.reverseFrames(block, channels)
                feedAac(codec, block, plan)
                end -= count
            }
        }
    }

    private fun feedAac(codec: MediaCodec, block: ShortArray, plan: AudioPlan) {
        var at = 0
        while (at < block.size) {
            val index = dequeueInput(codec)
            val buffer = codec.getInputBuffer(index)!!.order(ByteOrder.LITTLE_ENDIAN)
            buffer.clear()
            val frameShorts = plan.outChannels
            val n = min(block.size - at, (buffer.capacity() / 2 / frameShorts) * frameShorts)
            for (i in 0 until n) buffer.putShort(block[at + i])
            val pts = Math.floorDiv(aacInputFrames * 1_000_000L, plan.outRate.toLong())
            codec.queueInputBuffer(index, 0, n * 2, pts, 0)
            aacInputFrames += n / frameShorts
            at += n
            drainAac(false)
        }
    }

    private fun drainAac(untilEos: Boolean) {
        val codec = aac ?: return
        val plan = audio ?: return
        if (aacEos) return
        val deadline = System.nanoTime() + CODEC_TIMEOUT_NS
        while (true) {
            val index = codec.dequeueOutputBuffer(info, if (untilEos) DEQUEUE_US else 0)
            when {
                index >= 0 -> {
                    val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                        if (audioTrack < 0) throw EngineException(EngineErrorCode.encodingFailed, "audio before the tracks")
                        val buffer = codec.getOutputBuffer(index)!!
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        val pts = ReverseMath.aacUnitPtsUs(aacUnits++, plan.outRate, aacDelay)
                        write(audioTrack, buffer, BufferInfo(pts, info.size, C.BUFFER_FLAG_KEY_FRAME))
                    }
                    codec.releaseOutputBuffer(index, false)
                    if (eos) {
                        aacEos = true
                        return
                    }
                }
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!untilEos) return
                    check()
                    if (System.nanoTime() > deadline) throw EngineException(EngineErrorCode.encodingFailed, "AAC output timed out", retryable = true)
                }
                else -> Unit
            }
        }
    }

    // ---- finish ----

    /** Ends both streams and closes the muxer; the video track ends at [durationUs]. */
    fun finish(durationUs: Long) {
        val video = encoder ?: throw EngineException(EngineErrorCode.encodingFailed, "no video was encoded")
        // Every chunk ended its decoder run (all frames copied) before this.
        val last = dequeueInput(video)
        video.queueInputBuffer(last, 0, 0, max(0L, lastVideoPts + 1), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        drainEncoder(true)
        if (encodedVideo < copied) Log.w(EngineContext.TAG, "reverse: the encoder delivered $encodedVideo of $copied frames")
        aac?.let { codec ->
            val index = dequeueInput(codec)
            codec.queueInputBuffer(index, 0, 0, Math.floorDiv(aacInputFrames * 1_000_000L, audio!!.outRate.toLong()), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            drainAac(true)
        }
        if (videoTrack < 0) throw EngineException(EngineErrorCode.encodingFailed, "no video was encoded")
        // The last frame lasts until the range's end.
        if (durationUs > lastVideoPts) write(videoTrack, ByteBuffer.allocateDirect(0), BufferInfo(durationUs, 0, C.BUFFER_FLAG_END_OF_STREAM))
        // The intermediate carries the rotation as metadata when Transformer did not apply it.
        if (rotation in setOf(90, 180, 270)) muxer.addMetadataEntry(Mp4OrientationData(rotation))
        closedMuxer = true
        try {
            muxer.close()
        } catch (e: androidx.media3.muxer.MuxerException) {
            throw EngineException(EngineErrorCode.encodingFailed, "the reversed clip could not be finished", cause = e)
        } finally {
            stream.close()
        }
    }

    /** Frames copied into the encoder / encoded (logs). */
    val counts: Pair<Long, Long> get() = Pair(copied, encodedVideo)

    private fun releaseDecoder() {
        decoder?.let {
            try {
                it.stop()
            } catch (e: IllegalStateException) {
                // Already stopped.
            }
            it.release()
        }
        decoder = null
    }

    override fun close() {
        releaseDecoder()
        for (codec in listOfNotNull(encoder, aac)) {
            try {
                codec.stop()
            } catch (e: IllegalStateException) {
                // Already stopped or in error.
            }
            codec.release()
        }
        encoder = null
        aac = null
        if (!closedMuxer) {
            closedMuxer = true
            try {
                muxer.close()
            } catch (e: Exception) {
                // A failed job's partial file is deleted anyway.
            }
            try {
                stream.close()
            } catch (e: IOException) {
                // Same.
            }
        }
    }

    companion object {
        private const val DEQUEUE_US = 10_000L
        private const val CODEC_TIMEOUT_NS = 10_000_000_000L

        /** YUV memory of one block-mode pass (16 MB: 5 frames at 1080p, 11 at 720p, 1 at 4K). */
        private const val BLOCK_BYTES = 16L * 1024 * 1024
        private const val MAX_BLOCK_FRAMES = 16
    }
}

/**
 * Which intermediate sample stands for each chunk frame (pure): the intermediate starts at the
 * clip start (Media3 writes clipped times from zero; absolute times are accepted too), and a
 * sample matches the chunk frame with the nearest source PTS within half the smallest frame
 * interval (at most 1 ms). Samples past the chunk (the clip-end extension) match nothing.
 */
class IntermediateMapping(
    /** Intermediate PTS per chunk frame (source order), null when the intermediate lacks it. */
    val intermediatePts: List<Long?>,
) {
    companion object {
        fun of(intermediate: LongArray, chunkPts: LongArray, clipStartUs: Long): IntermediateMapping {
            if (intermediate.isEmpty()) return IntermediateMapping(chunkPts.map { null })
            val first = intermediate.minOrNull()!!
            // Relative (from zero) or absolute times: whichever puts the first sample nearer the clip start.
            val offset = if (kotlin.math.abs(first) <= kotlin.math.abs(first - clipStartUs)) clipStartUs else 0L
            var minGap = 1_000L
            for (i in 1 until chunkPts.size) minGap = min(minGap, (chunkPts[i] - chunkPts[i - 1]) / 2)
            val tolerance = max(1L, minGap)
            val sorted = intermediate.sortedArray()
            val result = ArrayList<Long?>(chunkPts.size)
            for (p in chunkPts) {
                val target = p - offset
                var lo = 0
                var hi = sorted.size - 1
                while (lo < hi) {
                    val mid = (lo + hi) / 2
                    if (sorted[mid] < target) lo = mid + 1 else hi = mid
                }
                var best: Long? = null
                for (c in intArrayOf(lo - 1, lo)) {
                    if (c < 0 || c >= sorted.size) continue
                    val d = kotlin.math.abs(sorted[c] - target)
                    if (d <= tolerance && (best == null || d < kotlin.math.abs(best - target))) best = sorted[c]
                }
                result += best
            }
            return IntermediateMapping(result)
        }
    }
}

/** One YUV 4:2:0 frame held in memory (block mode): planes packed without padding. */
class YuvFrame(val width: Int, val height: Int) {
    val chromaWidth = (width + 1) / 2
    val chromaHeight = (height + 1) / 2
    val y = ByteArray(width * height)
    val u = ByteArray(chromaWidth * chromaHeight)
    val v = ByteArray(chromaWidth * chromaHeight)
}

/** Copies flexible YUV 4:2:0 images (any pixel and row strides) to images or [YuvFrame]s. */
object YuvCopy {
    /** Copies [src] (its crop rectangle) into [dst] ([width] x [height]); the smaller size wins. */
    fun copy(src: android.media.Image, dst: android.media.Image, width: Int, height: Int) {
        val crop = src.cropRect
        val w = min(width, crop.width())
        val h = min(height, crop.height())
        val cw = (w + 1) / 2
        val ch = (h + 1) / 2
        plane(src.planes[0], crop.left, crop.top, dst.planes[0].buffer, dst.planes[0].pixelStride, dst.planes[0].rowStride, w, h)
        plane(src.planes[1], crop.left / 2, crop.top / 2, dst.planes[1].buffer, dst.planes[1].pixelStride, dst.planes[1].rowStride, cw, ch)
        plane(src.planes[2], crop.left / 2, crop.top / 2, dst.planes[2].buffer, dst.planes[2].pixelStride, dst.planes[2].rowStride, cw, ch)
    }

    /** Copies [src] (its crop rectangle) into [frame]. */
    fun toFrame(src: android.media.Image, frame: YuvFrame) {
        val crop = src.cropRect
        val w = min(frame.width, crop.width())
        val h = min(frame.height, crop.height())
        val cw = min(frame.chromaWidth, (w + 1) / 2)
        val ch = min(frame.chromaHeight, (h + 1) / 2)
        plane(src.planes[0], crop.left, crop.top, ByteBuffer.wrap(frame.y), 1, frame.width, w, h)
        plane(src.planes[1], crop.left / 2, crop.top / 2, ByteBuffer.wrap(frame.u), 1, frame.chromaWidth, cw, ch)
        plane(src.planes[2], crop.left / 2, crop.top / 2, ByteBuffer.wrap(frame.v), 1, frame.chromaWidth, cw, ch)
    }

    /** Copies [frame] into [dst]. */
    fun fromFrame(frame: YuvFrame, dst: android.media.Image) {
        val p = dst.planes
        copyPlane(ByteBuffer.wrap(frame.y), 1, frame.width, 0, 0, p[0].buffer, p[0].pixelStride, p[0].rowStride, frame.width, frame.height)
        copyPlane(ByteBuffer.wrap(frame.u), 1, frame.chromaWidth, 0, 0, p[1].buffer, p[1].pixelStride, p[1].rowStride, frame.chromaWidth, frame.chromaHeight)
        copyPlane(ByteBuffer.wrap(frame.v), 1, frame.chromaWidth, 0, 0, p[2].buffer, p[2].pixelStride, p[2].rowStride, frame.chromaWidth, frame.chromaHeight)
    }

    private fun plane(src: android.media.Image.Plane, x0: Int, y0: Int, d: ByteBuffer, dp: Int, dr: Int, w: Int, h: Int) =
        copyPlane(src.buffer, src.pixelStride, src.rowStride, x0, y0, d, dp, dr, w, h)

    /** Copies a [w] x [h] plane region starting at ([x0], [y0]) of [s] to the origin of [d] (pure; JVM-tested). */
    fun copyPlane(s: ByteBuffer, sp: Int, sr: Int, x0: Int, y0: Int, d: ByteBuffer, dp: Int, dr: Int, w: Int, h: Int) {
        if (sp == 1 && dp == 1) {
            val row = ByteArray(w)
            for (y in 0 until h) {
                s.position((y0 + y) * sr + x0)
                s.get(row, 0, w)
                d.position(y * dr)
                d.put(row, 0, w)
            }
        } else {
            for (y in 0 until h) {
                val si = (y0 + y) * sr + x0 * sp
                val di = y * dr
                for (x in 0 until w) d.put(di + x * dp, s.get(si + x * sp))
            }
        }
    }
}

/** Codec list helpers. */
object Codecs {
    /** Whether [info] is a software codec (API 29 flag, else the platform name prefixes). */
    fun isSoftware(info: android.media.MediaCodecInfo): Boolean =
        if (android.os.Build.VERSION.SDK_INT >= 29) info.isSoftwareOnly else info.name.startsWith("OMX.google.") || info.name.startsWith("c2.android.")
}
