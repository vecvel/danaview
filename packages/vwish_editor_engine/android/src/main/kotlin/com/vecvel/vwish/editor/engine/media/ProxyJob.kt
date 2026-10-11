@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-05
//
// 540p proxy job (ARCH §9.5, §15 'Proxies'; BUILD_PLAN AND-05, same contract as iOS IOS-05).
// A Media3 `Transformer` on its own looper thread transcodes the original into an editing proxy:
//
// - video: `Presentation.createForShortSide(540)` (GPU downscale, aspect kept; sources whose short
//   side is already <= 540 keep their size), H.264, 3 Mbps, I-frame interval 0.33 s (GOP about 10
//   frames at 30 fps), SDR: HDR sources are tone-mapped (OpenGL when GL_EXT_YUV_target and a 10-bit
//   decoder exist, else MediaCodec on API 31+, AND-01 V-N5; otherwise `unsupportedMedia`);
// - audio: AAC 128 kb/s (no audio track when the source has none);
// - timing: the same presentation timestamps as the source. Transformer keeps every input frame
//   and its timestamp (no frame-rate change, no trim), so VFR sources stay VFR.
// - output: written to `work/proxy-<jobId>.mp4.part` (protected from the launch wipe while it
//   runs), then renamed into `proxies/<quickHash>-540.mp4`; ProxyRegistry then enforces the
//   proxies/ cap with the new file kept.
// - stop: a cancel or a pre-emption (an export started, an interactive job needed the slot)
//   cancels the Transformer and deletes the `.part`; the JobRegistry ends the job (`cancelled`) or
//   re-queues it (it restarts from the beginning: Android jobs have no checkpoints).
//
// Run by JobRegistry (AND-05) on a registry worker thread; blocking. Never logs paths.

package com.vecvel.vwish.editor.engine.media

import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.util.Log
import androidx.annotation.OptIn
import androidx.annotation.VisibleForTesting
import androidx.media3.common.C
import androidx.media3.common.ColorInfo
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.AssetLoader
import androidx.media3.transformer.AudioEncoderSettings
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import com.vecvel.vwish.editor.engine.core.CodecInventory
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrorCode
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.EngineException
import com.vecvel.vwish.editor.engine.core.JobControl
import com.vecvel.vwish.editor.engine.core.Paths
import com.vecvel.vwish.editor.engine.core.RegistryJobControl
import com.vecvel.vwish.editor.engine.core.ToneMappingSupport
import com.vecvel.vwish.editor.engine.core.isStopRequested
import com.vecvel.vwish.editor.engine.pigeon.GeneratedAssetMsg
import com.vecvel.vwish.editor.engine.pigeon.JobRequestMsg
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** 540p proxy job with the source PTS (ARCH §9.5, §15; AND-05). */
class ProxyJob(private val ctx: EngineContext) {
    /**
     * Test hook: the Transformer's asset loader (decoder choice). Null (production) uses Media3's
     * default. The instrumented tests prefer software decoders because the x86_64 emulator's
     * goldfish H.264 decoder drops a B-frame (AND-08 measured the same defect).
     */
    @VisibleForTesting
    @Volatile
    var assetLoaderFactory: ((Context) -> AssetLoader.Factory)? = null

    /** Builds the proxy of [request].media (kind proxy). Blocking; throws an EngineException on failure. */
    fun run(request: JobRequestMsg, control: JobControl): GeneratedAssetMsg {
        val paths = ctx.requirePaths()
        val fingerprint = request.media.fingerprint
        try {
            return build(request.media.uri, fingerprint, paths, control)
        } catch (t: Throwable) {
            val error = EngineErrors.from(t)
            throw if (error.mediaFingerprint == null && error.code != EngineErrorCode.cancelled && error.code != EngineErrorCode.interrupted) {
                EngineException(error.code, error.message.orEmpty(), error.itemId, fingerprint, error.retryable, error.cause ?: t)
            } else {
                error
            }
        }
    }

    /** Builds (or reuses) the proxy of [uri] for [fingerprint]. */
    fun build(uri: String, fingerprint: String, paths: Paths, control: JobControl): GeneratedAssetMsg {
        ProxyRegistry.readyProxy(fingerprint, paths)?.let { existing ->
            control.reportProgress(1.0)
            return GeneratedAssetMsg(path = existing.absolutePath, sizeBytes = existing.length(), durationUs = null)
        }
        control.throwIfCancelled()
        val formats = Compatibility.trackFormats(ctx.appContext, uri)
        if (formats.protected) throw EngineException(EngineErrorCode.unsupportedMedia, "protected content")
        val video = formats.video.firstOrNull() ?: throw EngineException(EngineErrorCode.unsupportedMedia, "no video track")
        val settings = Settings.of(video, ctx.deviceProfile.codecs(), ctx.deviceProfile.toneMapping(), hasAudio = formats.audio.isNotEmpty())
        val target = ProxyRegistry.proxyFile(fingerprint, paths)
        val part = partFile(paths, control.jobId)
        paths.work.mkdirs()
        part.delete()
        DiskCache.markActive(part)
        try {
            val result = transcode(uri, part, settings, control)
            control.throwIfCancelled()
            if (!part.isFile || part.length() == 0L) throw EngineException(EngineErrorCode.encodingFailed, "the proxy is empty")
            ProxyRegistry.store(paths).ensureDirectory()
            if (target.exists() && !target.delete()) throw EngineException(EngineErrorCode.io, "cannot replace the proxy")
            if (!part.renameTo(target)) throw EngineException(EngineErrorCode.io, "cannot move the proxy into place")
            target.setLastModified(System.currentTimeMillis())
            ProxyRegistry.enforceCap(paths, keep = target)
            control.reportProgress(1.0)
            val durationMs = result.approximateDurationMs
            val durationUs = if (durationMs > 0 && durationMs != C.TIME_UNSET) durationMs * 1000 else null
            Log.i(
                EngineContext.TAG,
                "proxy done: ${result.width}x${result.height}, ${result.videoFrameCount} frames, " +
                    "${result.averageVideoBitrate / 1000} kb/s, tone map ${settings.hdrMode}",
            )
            return GeneratedAssetMsg(path = target.absolutePath, sizeBytes = target.length(), durationUs = durationUs)
        } finally {
            part.delete()
            DiskCache.unmarkActive(part)
        }
    }

    /** What the Transformer is asked for. */
    data class Settings(
        /** Short side of the output, or null to keep the source size (short side <= 540). */
        val shortSide: Int?,
        /** Composition HDR mode (KEEP_HDR for SDR sources: nothing to map). */
        val hdrMode: Int,
        /** The source has an audio track (the proxy then carries AAC). */
        val hasAudio: Boolean = true,
    ) {
        companion object {
            /** The settings for [video] on a device with [codecs] and [toneMapping]. */
            fun of(video: Format, codecs: CodecInventory, toneMapping: ToneMappingSupport, hasAudio: Boolean = true): Settings {
                val w = video.width
                val h = video.height
                val shortSide = if (w > 0 && h > 0 && minOf(w, h) <= SHORT_SIDE) null else SHORT_SIDE
                return Settings(shortSide, hdrMode(video, codecs, toneMapping), hasAudio)
            }

            /** OpenGL tone map when it can run, else MediaCodec (API 31+); SDR keeps the default. */
            fun hdrMode(video: Format, codecs: CodecInventory, toneMapping: ToneMappingSupport): Int {
                if (!ColorInfo.isTransferHdr(video.colorInfo)) return Composition.HDR_MODE_KEEP_HDR
                val mime = video.sampleMimeType.orEmpty()
                return when {
                    toneMapping.openGlToneMap(codecs, mime) -> Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL
                    toneMapping.mediaCodecToneMap -> Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_MEDIACODEC
                    else -> throw EngineException(EngineErrorCode.unsupportedMedia, "HDR cannot be tone-mapped on this device")
                }
            }
        }
    }

    /** Runs the Transformer into [output] on its own looper; blocks until it ends or is stopped. */
    private fun transcode(uri: String, output: File, settings: Settings, control: JobControl): ExportResult {
        val thread = HandlerThread("vwish-proxy", Process.THREAD_PRIORITY_BACKGROUND).apply { start() }
        val handler = Handler(thread.looper)
        val latch = CountDownLatch(1)
        var completed: ExportResult? = null
        var failure: Throwable? = null
        var transformer: Transformer? = null
        val progress = ProgressHolder()
        val poll = object : Runnable {
            override fun run() {
                val t = transformer ?: return
                if (t.getProgress(progress) == Transformer.PROGRESS_STATE_AVAILABLE) {
                    control.reportProgress(progress.progress / 100.0 * 0.99)
                }
                handler.postDelayed(this, PROGRESS_INTERVAL_MS)
            }
        }
        val stop = Runnable {
            handler.removeCallbacks(poll)
            transformer?.cancel()
            latch.countDown()
        }
        (control as? RegistryJobControl)?.onStop { handler.post(stop) }
        try {
            handler.post {
                try {
                    if (control.isStopRequested) {
                        latch.countDown()
                        return@post
                    }
                    val t = transformer(settings, latch, onDone = { completed = it }, onError = { failure = it })
                    transformer = t
                    t.start(composition(uri, settings), output.absolutePath)
                    handler.postDelayed(poll, PROGRESS_INTERVAL_MS)
                } catch (t: Throwable) {
                    failure = t
                    latch.countDown()
                }
            }
            // Plain JobControls (not the registry's) are polled for a cancel.
            while (!latch.await(STOP_POLL_MS, TimeUnit.MILLISECONDS)) {
                if (control !is RegistryJobControl && control.isCancelled) handler.post(stop)
            }
        } finally {
            val drained = CountDownLatch(1)
            handler.post {
                handler.removeCallbacks(poll)
                drained.countDown()
            }
            drained.await(STOP_POLL_MS * 10, TimeUnit.MILLISECONDS)
            thread.quitSafely()
        }
        control.throwIfCancelled()
        failure?.let { throw mapError(it) }
        return completed ?: throw EngineException(EngineErrorCode.internal, "proxy ended without a result")
    }

    private fun transformer(
        settings: Settings,
        latch: CountDownLatch,
        onDone: (ExportResult) -> Unit,
        onError: (Throwable) -> Unit,
    ): Transformer {
        val encoders = DefaultEncoderFactory.Builder(ctx.appContext)
            .setRequestedVideoEncoderSettings(
                VideoEncoderSettings.Builder()
                    .setBitrate(VIDEO_BITRATE)
                    .setiFrameIntervalSeconds(I_FRAME_INTERVAL_S)
                    .build(),
            )
            .setRequestedAudioEncoderSettings(AudioEncoderSettings.Builder().setBitrate(AUDIO_BITRATE).build())
            .setEnableFallback(true)
            .build()
        val builder = Transformer.Builder(ctx.appContext)
            .setLooper(android.os.Looper.myLooper()!!)
            .setVideoMimeType(MimeTypes.VIDEO_H264)
            .setAudioMimeType(MimeTypes.AUDIO_AAC)
            .setEncoderFactory(encoders)
        assetLoaderFactory?.let { builder.setAssetLoaderFactory(it(ctx.appContext)) }
        return builder
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    onDone(exportResult)
                    latch.countDown()
                }

                override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                    onError(exportException)
                    latch.countDown()
                }
            })
            .build()
    }

    private fun composition(uri: String, settings: Settings): Composition {
        val effects = settings.shortSide?.let { Effects(emptyList(), listOf(Presentation.createForShortSide(it))) } ?: Effects.EMPTY
        val item = EditedMediaItem.Builder(MediaSources.mediaItem(uri)).setEffects(effects).build()
        val tracks = if (settings.hasAudio) setOf(C.TRACK_TYPE_VIDEO, C.TRACK_TYPE_AUDIO) else setOf(C.TRACK_TYPE_VIDEO)
        return Composition.Builder(EditedMediaItemSequence.Builder(tracks).addItem(item).build())
            .setHdrMode(settings.hdrMode)
            .build()
    }

    companion object {
        /** Output short side (ARCH §9.5). */
        const val SHORT_SIDE = 540

        /** Video bitrate, 3 Mb/s. */
        const val VIDEO_BITRATE = 3_000_000

        /** I-frame interval, 0.33 s (GOP 10 frames at 30 fps). */
        const val I_FRAME_INTERVAL_S = 0.33f

        /** AAC bitrate, 128 kb/s. */
        const val AUDIO_BITRATE = 128_000

        private const val PROGRESS_INTERVAL_MS = 250L
        private const val STOP_POLL_MS = 100L

        /** The partial output of job [jobId]: `work/proxy-<jobId>.mp4.part`. */
        fun partFile(paths: Paths, jobId: String): File = File(paths.work, "proxy-${CacheStore.fileName(jobId)}.mp4.part")

        /** Maps a Transformer failure to an [EngineException] (same mapping as AND-11, ARCH §14.3). */
        fun mapError(error: Throwable): EngineException {
            if (error !is ExportException) return EngineErrors.from(error)
            val code = when (error.errorCode) {
                ExportException.ERROR_CODE_IO_FILE_NOT_FOUND -> EngineErrorCode.mediaOffline
                ExportException.ERROR_CODE_IO_NO_PERMISSION -> EngineErrorCode.permissionDenied
                ExportException.ERROR_CODE_DECODER_INIT_FAILED -> EngineErrorCode.decoderInitFailed
                ExportException.ERROR_CODE_DECODING_FAILED -> EngineErrorCode.decodeFailed
                ExportException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED -> EngineErrorCode.unsupportedMedia
                ExportException.ERROR_CODE_ENCODER_INIT_FAILED,
                ExportException.ERROR_CODE_ENCODING_FORMAT_UNSUPPORTED -> EngineErrorCode.encoderUnavailable
                ExportException.ERROR_CODE_ENCODING_FAILED -> EngineErrorCode.encodingFailed
                ExportException.ERROR_CODE_VIDEO_FRAME_PROCESSING_FAILED -> EngineErrorCode.gpuUnavailable
                else -> {
                    val nested = generateSequence(error.cause) { it.cause }.firstOrNull { it is java.io.IOException }
                    if (nested != null) EngineErrors.from(nested).code else EngineErrorCode.internal
                }
            }
            return EngineException(code, "proxy failed (${error.errorCodeName})", cause = error)
        }
    }
}
