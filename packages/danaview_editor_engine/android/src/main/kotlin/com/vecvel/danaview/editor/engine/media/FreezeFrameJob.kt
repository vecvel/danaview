@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-06
//
// Freeze-frame still (ARCH §15 'Freeze frame'; BUILD_PLAN AND-06, same contract as iOS IOS-06): a
// PNG of the exact source frame at `sourceTimeUs`, written to the Dart-supplied path
// (projects/<id>/assets/stills/...) through `<path>.part` + rename.
//
// Which frame (ARCH §11.5, D-04): the rule frame, the video sample with the greatest PTS <=
// sourceTime + 500 µs on the presentation timeline with edit lists applied (the first sample when
// the time precedes every sample), read with MediaExtractorCompat (AND-08's ExtractorSourceTimeline,
// the same lookup the composition mapper uses for clip starts). It is decoded by Media3's
// FrameExtractor (media3-inspector-frame) with SeekParameters.EXACT at floor(rulePts / 1000) ms:
// Media3 shows the first frame with pts >= the position (AND-01 V-N18, ARCH §5), and the previous
// frame is always more than 1 ms earlier, so that position lands on the rule frame. The frame comes
// back upright (rotation applied) and SDR (HDR tone-mapped by Media3; `setExtractHdrFrames(false)`).
//
// Verification: the extracted frame's presentation time must be the rule frame's (±1 ms). A
// decoder that loses frames (the x86_64 emulator's goldfish H.264 decoder drops a B-frame of the
// ENG-05 fixtures, AND-05/AND-08) would hand back a neighbour instead; the extraction is then
// retried once with software decoders first, and a still that is still not the rule frame fails
// with `decodeFailed` rather than freezing the wrong frame.
//
// Run by JobRegistry (AND-05) on a registry worker thread; blocking. A cancel or a pre-emption
// closes the extractor and stops at once (the registry deletes `<path>.part`; a pre-empted job
// restarts from scratch). Never logs paths.

package com.vecvel.danaview.editor.engine.media

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaFormat
import android.util.Log
import androidx.annotation.OptIn
import androidx.annotation.VisibleForTesting
import androidx.media3.common.Effect
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil
import androidx.media3.inspector.frame.FrameExtractor
import com.vecvel.danaview.editor.engine.composition.ExtractorSourceTimeline
import com.vecvel.danaview.editor.engine.composition.SourceTimeline
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.JobControl
import com.vecvel.danaview.editor.engine.core.JobRegistry
import com.vecvel.danaview.editor.engine.core.RegistryJobControl
import com.vecvel.danaview.editor.engine.core.isStopRequested
import com.vecvel.danaview.editor.engine.pigeon.GeneratedAssetMsg
import com.vecvel.danaview.editor.engine.pigeon.JobRequestMsg
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.ExecutionException
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import kotlin.math.abs

/** Freeze-frame still via FrameExtractor EXACT (ARCH §15; AND-06). */
class FreezeFrameJob(private val ctx: EngineContext) {
    /**
     * Test hook: the decoder choice of the first extraction attempt. Null (production) uses Media3's
     * default; the retry after a wrong frame always puts software decoders first.
     */
    @VisibleForTesting
    @Volatile
    var codecSelector: MediaCodecSelector? = null

    /** Writes the PNG still of [request] (kind freeze) to its outputPath. Blocking; throws an EngineException on failure. */
    fun run(request: JobRequestMsg, control: JobControl): GeneratedAssetMsg {
        val paths = ctx.requirePaths()
        val outputPath = request.outputPath ?: throw EngineErrors.invalidArgument("outputPath", "missing")
        val sourceTimeUs = request.sourceTimeUs ?: throw EngineErrors.invalidArgument("sourceTimeUs", "missing")
        val output = paths.requireWritable(outputPath, "outputPath")
        val fingerprint = request.media.fingerprint
        try {
            return write(request.media.uri, sourceTimeUs, output, control)
        } catch (t: Throwable) {
            val error = EngineErrors.from(t)
            throw if (error.code == EngineErrorCode.cancelled || error.code == EngineErrorCode.interrupted) error else error.withFingerprint(fingerprint)
        }
    }

    /** Extracts the frame of [uri] at [sourceTimeUs] and writes it as a PNG to [output] (`.part` + rename). */
    fun write(uri: String, sourceTimeUs: Long, output: File, control: JobControl): GeneratedAssetMsg {
        control.throwIfCancelled()
        val frame = ExactFrames.extract(ctx.appContext, uri, sourceTimeUs, emptyList(), control, codecSelector)
        val bitmap = frame.bitmap
        try {
            control.throwIfCancelled()
            control.reportProgress(0.6)
            val part = File(output.path + JobRegistry.PART_SUFFIX)
            output.parentFile?.let { if (!it.isDirectory && !it.mkdirs()) throw EngineException(EngineErrorCode.io, "cannot create the still directory") }
            part.delete()
            try {
                FileOutputStream(part).use { out ->
                    if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) throw EngineException(EngineErrorCode.io, "png encode failed", retryable = true)
                    out.fd.sync()
                }
                control.throwIfCancelled()
                if (output.exists() && !output.delete()) throw EngineException(EngineErrorCode.io, "cannot replace the still")
                if (!part.renameTo(output)) throw EngineException(EngineErrorCode.io, "cannot move the still into place")
            } catch (e: IOException) {
                throw EngineErrors.from(e)
            } finally {
                part.delete()
            }
            control.reportProgress(1.0)
            Log.i(EngineContext.TAG, "freeze still done: ${bitmap.width}x${bitmap.height}")
            return GeneratedAssetMsg(path = output.absolutePath, sizeBytes = output.length(), durationUs = null)
        } finally {
            bitmap.recycle()
        }
    }
}

/**
 * Exact source frames (D-04 rule frame, FrameExtractor EXACT) shared by [FreezeFrameJob] and the
 * preview's SourceFrameCache (AND-06). Blocking; never call on the main thread.
 */
object ExactFrames {
    /** Wait limit for one frame. */
    const val FRAME_TIMEOUT_MS = 30_000L

    /** Poll interval while waiting for a frame (stop requests are checked between polls). */
    private const val POLL_MS = 50L

    /** Tolerance between the extracted frame's time and the rule frame's (FrameExtractor reports ms). */
    const val PTS_TOLERANCE_MS = 1L

    /** The seek position (ms) that lands on the frame presented at [ptsUs] (ARCH §5 'floor'). */
    fun seekPositionMs(ptsUs: Long): Long = Math.floorDiv(ptsUs.coerceAtLeast(0L), 1000L)

    /** Whether a frame reported at [frameMs] is the frame presented at [ptsUs]. */
    fun isFrame(frameMs: Long, ptsUs: Long): Boolean = abs(frameMs - seekPositionMs(ptsUs)) <= PTS_TOLERANCE_MS

    /** PTS (µs) of the rule frame of [sourceUs] in the first video track of [uri] (ARCH §11.5). */
    fun ruleFramePtsUs(context: Context, uri: String, sourceUs: Long): Long {
        ExtractorSourceTimeline(context).use { timeline ->
            try {
                return timeline.ruleFramePtsUs(MediaSources.toUri(uri).toString(), sourceUs.coerceAtLeast(0L))
            } catch (e: IOException) {
                if (MediaSources.localFile(uri)?.isFile == false) throw EngineException(EngineErrorCode.mediaOffline, "file not found", cause = e)
                throw EngineException(EngineErrorCode.unsupportedMedia, "no readable video track", cause = e)
            }
        }
    }

    /** Video facts of [uri] needed to size frames: display width and height (rotation applied). */
    fun displaySize(context: Context, uri: String): Pair<Int, Int> {
        val extractor = MediaSources.extractor(context, uri)
        try {
            val format = (0 until extractor.trackCount).map { extractor.getTrackFormat(it) }
                .firstOrNull { it.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true }
                ?: throw EngineException(EngineErrorCode.unsupportedMedia, "no video track")
            val w = format.getInteger(MediaFormat.KEY_WIDTH)
            val h = format.getInteger(MediaFormat.KEY_HEIGHT)
            val rotation = if (format.containsKey(MediaFormat.KEY_ROTATION)) format.getInteger(MediaFormat.KEY_ROTATION) else 0
            return if (rotation % 180 != 0) Pair(h, w) else Pair(w, h)
        } finally {
            extractor.release()
        }
    }

    /** A decoder list with software decoders first (the verification retry). */
    val softwareFirst: MediaCodecSelector = MediaCodecSelector { mime, secure, tunneling ->
        MediaCodecUtil.getDecoderInfos(mime, secure, tunneling).sortedBy { if (it.softwareOnly) 0 else 1 }
    }

    /** A FrameExtractor of [uri] with EXACT seeks, SDR output and [effects]. */
    fun extractor(context: Context, uri: String, effects: List<Effect>, codecSelector: MediaCodecSelector? = null): FrameExtractor {
        val builder = FrameExtractor.Builder(context, MediaSources.mediaItem(uri))
            .setSeekParameters(SeekParameters.EXACT)
            .setExtractHdrFrames(false)
            .setEffects(effects)
        codecSelector?.let { builder.setMediaCodecSelector(it) }
        return builder.build()
    }

    /**
     * The rule frame of [sourceTimeUs] of [uri] through [effects]: one extraction with
     * [codecSelector] (null = Media3's default) and, when that frame is not the rule frame, one more
     * with software decoders first. The caller owns (and recycles) the returned bitmap.
     */
    fun extract(
        context: Context,
        uri: String,
        sourceTimeUs: Long,
        effects: List<Effect>,
        control: JobControl? = null,
        codecSelector: MediaCodecSelector? = null,
    ): FrameExtractor.Frame {
        val rulePts = ruleFramePtsUs(context, uri, sourceTimeUs)
        control?.throwIfCancelled()
        val first = extractOnce(context, uri, rulePts, effects, control, codecSelector)
        if (isFrame(first.presentationTimeMs, rulePts)) return first
        Log.w(EngineContext.TAG, "exact frame off by ${first.presentationTimeMs - seekPositionMs(rulePts)} ms; retrying with software decoders")
        first.bitmap.recycle()
        control?.throwIfCancelled()
        val second = extractOnce(context, uri, rulePts, effects, control, softwareFirst)
        if (isFrame(second.presentationTimeMs, rulePts)) return second
        second.bitmap.recycle()
        throw EngineException(EngineErrorCode.decodeFailed, "the decoder did not deliver the requested frame", retryable = true)
    }

    private fun extractOnce(
        context: Context,
        uri: String,
        rulePtsUs: Long,
        effects: List<Effect>,
        control: JobControl?,
        codecSelector: MediaCodecSelector?,
    ): FrameExtractor.Frame {
        val extractor = try {
            extractor(context, uri, effects, codecSelector)
        } catch (t: Throwable) {
            throw MediaSources.mapOpenError(t)
        }
        try {
            return await(extractor.getFrame(seekPositionMs(rulePtsUs)), control)
        } finally {
            closeQuietly(extractor)
        }
    }

    /** Waits for [future] (polling [control] so a stop request ends the wait at once). */
    fun await(future: Future<FrameExtractor.Frame>, control: JobControl?, timeoutMs: Long = FRAME_TIMEOUT_MS): FrameExtractor.Frame {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000
        while (true) {
            if (control != null && (control.isStopRequested || (control !is RegistryJobControl && control.isCancelled))) {
                future.cancel(true)
                control.throwIfCancelled()
            }
            try {
                return future.get(POLL_MS, TimeUnit.MILLISECONDS)
            } catch (e: TimeoutException) {
                if (System.nanoTime() > deadline) {
                    future.cancel(true)
                    throw EngineException(EngineErrorCode.decodeFailed, "frame extraction timed out", retryable = true, cause = e)
                }
            } catch (e: ExecutionException) {
                throw mapFrameError(e)
            } catch (e: java.util.concurrent.CancellationException) {
                control?.throwIfCancelled()
                throw EngineException(EngineErrorCode.cancelled, "cancelled", cause = e)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                throw EngineException(EngineErrorCode.interrupted, "interrupted", retryable = true, cause = e)
            }
        }
    }

    /** Maps a FrameExtractor failure (playback errors carry the decoder and file failures). */
    fun mapFrameError(error: Throwable): EngineException {
        val cause = if (error is ExecutionException) error.cause ?: error else error
        if (cause is androidx.media3.common.PlaybackException) {
            val code = when (cause.errorCode) {
                androidx.media3.common.PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND -> EngineErrorCode.mediaOffline
                androidx.media3.common.PlaybackException.ERROR_CODE_IO_NO_PERMISSION -> EngineErrorCode.permissionDenied
                androidx.media3.common.PlaybackException.ERROR_CODE_DECODER_INIT_FAILED -> EngineErrorCode.decoderInitFailed
                androidx.media3.common.PlaybackException.ERROR_CODE_DECODING_FAILED -> EngineErrorCode.decodeFailed
                androidx.media3.common.PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
                androidx.media3.common.PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES,
                androidx.media3.common.PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
                androidx.media3.common.PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED -> EngineErrorCode.unsupportedMedia
                else -> EngineErrorCode.decodeFailed
            }
            return EngineException(code, "frame extraction failed (${cause.errorCodeName})", retryable = code == EngineErrorCode.decodeFailed, cause = cause)
        }
        return MediaSources.mapOpenError(cause)
    }

    /** Closes [extractor], logging (never throwing) a failure. */
    fun closeQuietly(extractor: FrameExtractor) {
        try {
            extractor.close()
        } catch (e: RuntimeException) {
            Log.w(EngineContext.TAG, "frame extractor close failed: ${e.javaClass.simpleName}")
        }
    }

    /** The rule-frame tolerance (ARCH §11.5), re-exported for the tests. */
    const val EPSILON_US: Long = SourceTimeline.EPSILON_US
}
