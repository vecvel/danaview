@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-11

// One Transformer run of an export (ARCH §14.3). ExportCoordinator creates one per attempt (the
// portrait retry is a second run) on the danaview-export looper; AND-19's multi-pass precompose
// creates one per pass with the same [TransformerExport.Config] (see MultiPassJob).
// Configuration:
//   setVideoMimeType(H.264 | HEVC) and setAudioMimeType(AAC);
//   DefaultEncoderFactory with HardwareEncoderSelector.media3Selector() (hardware first), the
//     requested VideoEncoderSettings (bitrate, I-frame interval) and AudioEncoderSettings (bitrate),
//     setEnableFallback(true) (Transformer reports a changed request through onFallbackApplied →
//     the `fallbackApplied` progress warning);
//   InAppMp4Muxer.Factory().setAttemptStreamableOutputEnabled(true) (writes `hvc1` for HEVC,
//     V-N13; no location metadata), wrapped by [AudioEndTrimmingMuxer] when `config.audioEndUs` is
//     set: AAC access units presented at or after the video's end are not written, so with the
//     composition's audio tail (Media3Composition "Audio tail") the AAC track ends at the video's
//     last frame, within one AAC frame (owner decision 2026-10-15, ARCH §14.3; timestamps and the
//     A/V offset are unchanged, video samples always pass);
//   DefaultVideoFrameProcessor with WORKING_COLOR_SPACE_ORIGINAL (ARCH §11.6, the same frame
//     processor as AND-08/AND-09 were verified with);
//   setPortraitEncodingEnabled(config.portraitEncoding): true first; the coordinator's §14.1 retry
//     runs again with false (Transformer encodes landscape and writes rotation metadata).
//   Asset loading stays Transformer's DefaultAssetLoaderFactory (AND-08 measured fact 2: its media
//     source factory clips inside the media period and keeps the B-frames before a clip end) unless
//     the composition selects audio streams > 0 (AudioStreamAssetLoaderFactory over the same
//     default) or a test injects a factory.
// Progress: Transformer.getProgress every 250 ms on the looper. Every callback runs on the looper;
// nothing is called after cancel(). cancel() and both end callbacks join the Transformer's internal
// thread before they return or report (QA-05 D9, TransformerThreads: Media3 quits it lazily, after
// cancel() returned), so no Media3 codec owner outlives the run's end.
// [ExportErrors] maps ExportException codes to EngineErrorCode (ARCH §14.3) and decides the portrait
// retry.

package com.vecvel.danaview.editor.engine.export

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.Format
import androidx.media3.common.Metadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.DefaultVideoFrameProcessor
import androidx.media3.muxer.BufferInfo
import androidx.media3.muxer.Muxer
import androidx.media3.transformer.AssetLoader
import androidx.media3.transformer.Codec
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.InAppMp4Muxer
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.TransformationRequest
import androidx.media3.transformer.Transformer
import com.google.common.collect.ImmutableList
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.media.TransformerThreads
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer

/** One Transformer run (file header). Create, [start] and [cancel] on [looper]. */
class TransformerExport(
    private val context: Context,
    private val looper: Looper,
    val config: Config,
    private val listener: Listener,
) {
    /** How the run is configured (file header). */
    data class Config(
        /** Settings with the codec that will be written (EncoderChoice.codec). */
        val settings: EncoderSettings,
        val selector: HardwareEncoderSelector,
        /** `setPortraitEncodingEnabled`; false only on the §14.1 retry. */
        val portraitEncoding: Boolean = true,
        /** Asset loader (null: Transformer's default). */
        val assetLoaderFactory: AssetLoader.Factory? = null,
        /** Wraps the encoder factory (tests inject refusals). */
        val encoderFactoryDecorator: ((Codec.EncoderFactory) -> Codec.EncoderFactory)? = null,
        /** Progress poll interval (ARCH §14.3: 250 ms). */
        val progressIntervalMs: Long = PROGRESS_INTERVAL_MS,
        /**
         * The video's end (µs): audio samples presented at or after it are dropped
         * ([AudioEndTrimmingMuxer]); null keeps every sample.
         */
        val audioEndUs: Long? = null,
    )

    /** Run callbacks, all on the looper. */
    interface Listener {
        /** Transformer progress 0..1 (only while available). */
        fun onProgress(fraction: Double) {}

        /** Transformer applied an encoder fallback (`fallbackApplied` warning). */
        fun onFallbackApplied() {}

        fun onCompleted(result: ExportResult)

        fun onError(error: ExportException)
    }

    private val handler = Handler(looper)
    private val holder = ProgressHolder()
    private var transformer: Transformer? = null
    private var ended = false

    /** The internal thread(s) [start] created (TransformerThreads). */
    private var internalThreads: List<Thread> = emptyList()

    private val poll = object : Runnable {
        override fun run() {
            val t = transformer ?: return
            if (ended) return
            if (t.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) listener.onProgress(holder.progress / 100.0)
            handler.postDelayed(this, config.progressIntervalMs)
        }
    }

    /** Starts exporting [composition] to [output]. Call on the looper. */
    fun start(composition: Composition, output: File) {
        check(Looper.myLooper() == looper) { "TransformerExport.start off its looper" }
        val t = build(context, looper, config, object : Transformer.Listener {
            override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                if (ended) return
                ended = true
                handler.removeCallbacks(poll)
                TransformerThreads.awaitEnd(internalThreads)
                listener.onCompleted(exportResult)
            }

            override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                if (ended) return
                ended = true
                handler.removeCallbacks(poll)
                TransformerThreads.awaitEnd(internalThreads)
                listener.onError(exportException)
            }

            override fun onFallbackApplied(composition: Composition, originalTransformationRequest: TransformationRequest, fallbackTransformationRequest: TransformationRequest) {
                if (!ended && originalTransformationRequest != fallbackTransformationRequest) listener.onFallbackApplied()
            }
        })
        transformer = t
        output.absoluteFile.parentFile?.mkdirs()
        internalThreads = TransformerThreads.startedBy { t.start(composition, output.absolutePath) }
        handler.postDelayed(poll, config.progressIntervalMs)
    }

    /** Stops the run; no callback follows. Call on the looper. */
    fun cancel() {
        if (ended) return
        ended = true
        handler.removeCallbacks(poll)
        try {
            transformer?.cancel()
        } finally {
            // cancel() returns before the internal thread has quit (QA-05 D9).
            TransformerThreads.awaitEnd(internalThreads)
        }
    }

    companion object {
        /** ARCH §14.3. */
        const val PROGRESS_INTERVAL_MS = 250L

        /** A Transformer configured as the file header says. */
        fun build(context: Context, looper: Looper, config: Config, listener: Transformer.Listener): Transformer {
            val base = encoderFactory(context, config)
            val encoders = config.encoderFactoryDecorator?.invoke(base) ?: base
            val builder = Transformer.Builder(context)
                .setLooper(looper)
                .setVideoMimeType(config.settings.videoMimeType)
                .setAudioMimeType(EncoderSettings.AUDIO_MIME_TYPE)
                .setEncoderFactory(encoders)
                .setMuxerFactory(muxerFactory(config))
                .setVideoFrameProcessorFactory(
                    DefaultVideoFrameProcessor.Factory.Builder()
                        .setSdrWorkingColorSpace(DefaultVideoFrameProcessor.WORKING_COLOR_SPACE_ORIGINAL)
                        .build(),
                )
                .setPortraitEncodingEnabled(config.portraitEncoding)
                .addListener(listener)
            config.assetLoaderFactory?.let { builder.setAssetLoaderFactory(it) }
            return builder.build()
        }

        /** InAppMp4Muxer (streamable), trimming audio at [Config.audioEndUs] when set. */
        fun muxerFactory(config: Config): Muxer.Factory {
            val base = InAppMp4Muxer.Factory().setAttemptStreamableOutputEnabled(true)
            return config.audioEndUs?.let { AudioEndTrimmingMuxer.Factory(base, it) } ?: base
        }

        /** DefaultEncoderFactory: hardware-first selector, requested settings, fallback on. */
        fun encoderFactory(context: Context, config: Config): DefaultEncoderFactory =
            DefaultEncoderFactory.Builder(context)
                .setVideoEncoderSelector(config.selector.media3Selector())
                .setRequestedVideoEncoderSettings(config.settings.videoEncoderSettings())
                .setRequestedAudioEncoderSettings(config.settings.audioEncoderSettings())
                .setEnableFallback(true)
                .build()
    }
}

/**
 * A muxer that does not write audio samples presented at or after [endUs] (the video's end), so
 * the audio track ends within one access unit after it: the last kept unit starts before [endUs]
 * and the first dropped one at or after it (owner decision 2026-10-15, ARCH §14.3). Video and
 * every other track pass unchanged; timestamps are never altered. Logs (no paths) when the audio
 * written ends more than one access unit before [endUs] (the audio tail was too short).
 */
class AudioEndTrimmingMuxer(private val base: Muxer, private val endUs: Long) : Muxer {
    private val audioTracks = HashSet<Int>()
    private val sampleRates = HashMap<Int, Int>()
    private var lastAudioUs = Long.MIN_VALUE
    private var dropped = 0

    /** Wraps [base]'s muxers. */
    class Factory(private val base: Muxer.Factory, private val endUs: Long) : Muxer.Factory {
        override fun create(path: String): Muxer = AudioEndTrimmingMuxer(base.create(path), endUs)

        override fun getSupportedSampleMimeTypes(trackType: Int): ImmutableList<String> = base.getSupportedSampleMimeTypes(trackType)

        override fun supportsWritingNegativeTimestampsInEditList(): Boolean = base.supportsWritingNegativeTimestampsInEditList()
    }

    override fun addTrack(format: Format): Int {
        val id = base.addTrack(format)
        if (MimeTypes.isAudio(format.sampleMimeType)) {
            audioTracks += id
            if (format.sampleRate != Format.NO_VALUE) sampleRates[id] = format.sampleRate
        }
        return id
    }

    override fun writeSampleData(trackId: Int, data: ByteBuffer, bufferInfo: BufferInfo) {
        if (trackId in audioTracks) {
            if (bufferInfo.presentationTimeUs >= endUs) {
                dropped++
                return
            }
            lastAudioUs = maxOf(lastAudioUs, bufferInfo.presentationTimeUs)
        }
        base.writeSampleData(trackId, data, bufferInfo)
    }

    override fun addMetadataEntry(metadataEntry: Metadata.Entry) = base.addMetadataEntry(metadataEntry)

    override fun close() {
        if (audioTracks.isNotEmpty()) {
            val rate = sampleRates.values.firstOrNull() ?: 48_000
            val unitUs = AAC_FRAME_SAMPLES * 1_000_000L / rate
            if (lastAudioUs == Long.MIN_VALUE || lastAudioUs + unitUs < endUs - unitUs) {
                Log.w(EngineContext.TAG, "export audio ends early: last access unit at $lastAudioUs us for a video ending at $endUs us ($dropped dropped)")
            }
        }
        base.close()
    }

    companion object {
        /** Samples per AAC-LC access unit. */
        const val AAC_FRAME_SAMPLES = 1024L
    }
}

/** ExportException → EngineException mapping and the portrait retry rule (ARCH §14.1, §14.3). */
object ExportErrors {
    /** The video encoder refused its configuration (init failed or format unsupported). */
    fun isEncoderRefusal(e: ExportException): Boolean =
        (e.errorCode == ExportException.ERROR_CODE_ENCODER_INIT_FAILED || e.errorCode == ExportException.ERROR_CODE_ENCODING_FORMAT_UNSUPPORTED) &&
            e.codecInfo?.isVideo != false

    /** §14.1: a refused portrait configuration is retried once landscape with rotation metadata. */
    fun shouldRetryLandscape(e: ExportException, settings: EncoderSettings, attempt: Int): Boolean =
        attempt == 0 && settings.isPortrait && isEncoderRefusal(e)

    /**
     * Maps [error] (ARCH §14.3): encoder init/format → `encoderSizeLimit` when [sizeLimit] (the size
     * was refused: a failed landscape retry, or no encoder takes the size) else `encoderUnavailable`;
     * file not found → `mediaOffline`; no permission → `permissionDenied`; decoder init →
     * `decoderInitFailed`; decoding → `decodeFailed`; decoding format → `unsupportedMedia`;
     * encoding → `encodingFailed`; video frame processing → `gpuUnavailable`; ENOSPC anywhere in the
     * cause chain → `diskFull`; muxing and other I/O → the nested I/O error or `io`; anything else →
     * `internal`. Messages carry the error code name only (no paths).
     */
    fun map(error: Throwable, sizeLimit: Boolean = false): EngineException {
        if (error !is ExportException) return EngineErrors.from(error)
        if (hasNoSpace(error)) return EngineException(EngineErrorCode.diskFull, "no space left on device", cause = error)
        val code = when (error.errorCode) {
            ExportException.ERROR_CODE_IO_FILE_NOT_FOUND -> EngineErrorCode.mediaOffline
            ExportException.ERROR_CODE_IO_NO_PERMISSION -> EngineErrorCode.permissionDenied
            ExportException.ERROR_CODE_DECODER_INIT_FAILED -> EngineErrorCode.decoderInitFailed
            ExportException.ERROR_CODE_DECODING_FAILED -> EngineErrorCode.decodeFailed
            ExportException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED -> EngineErrorCode.unsupportedMedia
            ExportException.ERROR_CODE_ENCODER_INIT_FAILED,
            ExportException.ERROR_CODE_ENCODING_FORMAT_UNSUPPORTED,
            -> if (sizeLimit) EngineErrorCode.encoderSizeLimit else EngineErrorCode.encoderUnavailable
            ExportException.ERROR_CODE_ENCODING_FAILED -> EngineErrorCode.encodingFailed
            ExportException.ERROR_CODE_VIDEO_FRAME_PROCESSING_FAILED -> EngineErrorCode.gpuUnavailable
            ExportException.ERROR_CODE_MUXING_FAILED,
            ExportException.ERROR_CODE_MUXING_TIMEOUT,
            ExportException.ERROR_CODE_MUXING_APPEND,
            ExportException.ERROR_CODE_IO_UNSPECIFIED,
            ExportException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE,
            -> nestedIo(error)?.let { EngineErrors.from(it).code } ?: EngineErrorCode.io
            else -> nestedIo(error)?.let { EngineErrors.from(it).code } ?: EngineErrorCode.internal
        }
        return EngineException(code, "export failed (${error.errorCodeName})", cause = error)
    }

    private fun causes(e: Throwable): Sequence<Throwable> = generateSequence(e) { it.cause }.take(16)

    private fun nestedIo(e: Throwable): IOException? = causes(e).drop(1).firstOrNull { it is IOException } as IOException?

    private fun hasNoSpace(e: Throwable): Boolean = causes(e).any {
        val m = it.message.orEmpty()
        m.contains("ENOSPC") || m.contains("No space left", ignoreCase = true)
    }
}
