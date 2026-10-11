@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-02
//
// Edit compatibility of a file (ARCH §15, <= 300 ms; BUILD_PLAN AND-02). Order:
//   missing file -> NotEditable('not_found'); revoked grant -> permissionDenied failure;
//   images -> BitmapFactory bounds (codec_unsupported when undecodable);
//   audio/video -> MediaExtractorCompat track formats (headers only) and, per track, a decoder for
//   the MIME/profile/size via CodecInventory (MediaCodecList.findDecoderForFormat):
//     DRM -> 'protected_content'; no decoder for the first video track (or the audio of an audio
//     file) -> 'codec_unsupported'; HDR (HLG/PQ) video without a tone map on this device ->
//     'hdr_unsupported' (AND-01 V-N5: OpenGL needs GL_EXT_YUV_target + a 10-bit decoder, MediaCodec
//     tone mapping needs API 31); unparseable -> 'codec_unsupported'.
// MKV and WebM are editable when their decoders exist. A video whose audio has no decoder stays
// editable (the probe lists `audio_codec_unsupported`; AND-08 leaves that audio out).
//
// The checks run on a small worker pool; a timer on the main scheduler answers `editable` after
// [Compatibility.TIMEOUT_MS] when the extractor is slower (iOS does the same: the budget wins, and
// the full probe decides later). The answer is delivered exactly once.

package com.vecvel.vwish.editor.engine.media

import android.content.Context
import android.graphics.BitmapFactory
import android.media.MediaFormat
import androidx.annotation.OptIn
import androidx.media3.common.ColorInfo
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import com.vecvel.vwish.editor.engine.core.CodecInventory
import com.vecvel.vwish.editor.engine.core.Completion
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrorCode
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.EngineException
import com.vecvel.vwish.editor.engine.core.ToneMappingSupport
import com.vecvel.vwish.editor.engine.pigeon.CompatibilityMsg
import java.util.concurrent.ExecutorService
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Edit compatibility, <= 300 ms (ARCH §15; AND-02). Called on vwish-io. */
class Compatibility(private val ctx: EngineContext) {
    private val workers: ExecutorService by lazy {
        ThreadPoolExecutor(0, 4, 30, TimeUnit.SECONDS, SynchronousQueue()) { r ->
            Thread(r, "vwish-compat").apply { isDaemon = true }
        }.apply { rejectedExecutionHandler = ThreadPoolExecutor.CallerRunsPolicy() }
    }

    /** Whether [uri] is editable on this device. */
    fun check(uri: String, done: Completion<CompatibilityMsg>) {
        val once = AtomicBoolean(false)
        val reply: (Result<CompatibilityMsg>) -> Unit = { result -> if (once.compareAndSet(false, true)) done(result) }
        val timer = ctx.threads.main.postDelayed({ reply(Result.success(EDITABLE)) }, TIMEOUT_MS)
        workers.execute {
            val result = runCatching {
                check(ctx.appContext, uri, ctx.deviceProfile.codecs(), ctx.deviceProfile.toneMapping())
            }
            timer.cancel()
            reply(result.recoverCatching { throw EngineErrors.from(it) })
        }
    }

    companion object {
        /** Budget of the native checks; the whole answer stays under 300 ms. */
        const val TIMEOUT_MS = 250L

        /** The editable answer. */
        val EDITABLE = CompatibilityMsg(editable = true)

        /** A NotEditable answer. */
        fun notEditable(code: String, message: String) = CompatibilityMsg(editable = false, code = code, message = message)

        /** The blocking check of [uri]. */
        fun check(context: Context, uri: String, codecs: CodecInventory, toneMapping: ToneMappingSupport): CompatibilityMsg {
            if (!MediaSources.exists(context, uri)) return notEditable(ProbeIssue.NOT_FOUND, "file not found")
            val container = SniffedContainer.sniff(MediaSources.head(context, uri), MediaSources.hint(context, uri))
            if (container.isImage) {
                val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                MediaSources.open(context, uri).use { BitmapFactory.decodeStream(it, null, options) }
                return if (options.outWidth > 0 && options.outHeight > 0) EDITABLE
                else notEditable(ProbeIssue.CODEC_UNSUPPORTED, "image format not supported")
            }
            val formats = try {
                trackFormats(context, uri)
            } catch (e: EngineException) {
                return when (e.code) {
                    EngineErrorCode.unsupportedMedia, EngineErrorCode.decoderInitFailed ->
                        notEditable(ProbeIssue.CODEC_UNSUPPORTED, "format not supported")
                    EngineErrorCode.mediaOffline -> notEditable(ProbeIssue.NOT_FOUND, "file not found")
                    else -> throw e
                }
            }
            return decide(formats, codecs, toneMapping)
        }

        /** The verdict for the track [formats] of a file (pure; JVM-tested). */
        fun decide(formats: TrackFormats, codecs: CodecInventory, toneMapping: ToneMappingSupport): CompatibilityMsg {
            if (formats.video.isEmpty() && formats.audio.isEmpty()) {
                return notEditable(ProbeIssue.CODEC_UNSUPPORTED, "no audio or video tracks")
            }
            if (formats.protected) return notEditable(ProbeIssue.PROTECTED_CONTENT, "protected content")
            val video = formats.video.firstOrNull()
            if (video != null) {
                if (VideoFormats.transfer(video) != com.vecvel.vwish.editor.engine.pigeon.ColorTransferMsg.SDR) {
                    if (!codecs.hasDecoder(video)) return notEditable(ProbeIssue.CODEC_UNSUPPORTED, "no decoder for this HDR video")
                    if (!toneMapping.canToneMap(codecs, video)) {
                        return notEditable(ProbeIssue.HDR_UNSUPPORTED, "HDR tone mapping is not available on this device")
                    }
                    return EDITABLE
                }
                return if (codecs.hasDecoder(video)) EDITABLE else notEditable(ProbeIssue.CODEC_UNSUPPORTED, "no decoder for this video")
            }
            val audio = formats.audio.first()
            return if (codecs.hasDecoder(audio)) EDITABLE else notEditable(ProbeIssue.CODEC_UNSUPPORTED, "no decoder for this audio")
        }

        /** Track formats from MediaExtractorCompat (headers only). */
        fun trackFormats(context: Context, uri: String): TrackFormats {
            val extractor = MediaSources.extractor(context, uri)
            try {
                val video = ArrayList<Format>()
                val audio = ArrayList<Format>()
                for (i in 0 until extractor.trackCount) {
                    val format = toFormat(extractor.getTrackFormat(i))
                    when {
                        MimeTypes.isVideo(format.sampleMimeType) -> video.add(format)
                        MimeTypes.isAudio(format.sampleMimeType) -> audio.add(format)
                    }
                }
                val protected = extractor.drmInitData != null
                return TrackFormats(video, audio, protected)
            } catch (t: RuntimeException) {
                throw MediaSources.mapOpenError(t)
            } finally {
                extractor.release()
            }
        }

        /** The Media3 Format fields compatibility needs, from a platform MediaFormat. */
        fun toFormat(mf: MediaFormat): Format {
            val builder = Format.Builder().setSampleMimeType(mf.getString(MediaFormat.KEY_MIME))
            if (mf.containsKey(MediaFormat.KEY_WIDTH)) builder.setWidth(mf.getInteger(MediaFormat.KEY_WIDTH))
            if (mf.containsKey(MediaFormat.KEY_HEIGHT)) builder.setHeight(mf.getInteger(MediaFormat.KEY_HEIGHT))
            if (mf.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) builder.setChannelCount(mf.getInteger(MediaFormat.KEY_CHANNEL_COUNT))
            if (mf.containsKey(MediaFormat.KEY_SAMPLE_RATE)) builder.setSampleRate(mf.getInteger(MediaFormat.KEY_SAMPLE_RATE))
            mf.getString(KEY_CODECS_STRING)?.let { builder.setCodecs(it) }
            val mime = mf.getString(MediaFormat.KEY_MIME).orEmpty().lowercase()
            val tenBit = mf.containsKey(MediaFormat.KEY_PROFILE) && CodecInventory.isTenBit(mime, setOf(mf.getInteger(MediaFormat.KEY_PROFILE)))
            val transfer = if (mf.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) mf.getInteger(MediaFormat.KEY_COLOR_TRANSFER) else Format.NO_VALUE
            if (tenBit || transfer != Format.NO_VALUE) {
                val color = ColorInfo.Builder().setColorTransfer(transfer)
                if (tenBit) color.setLumaBitdepth(10).setChromaBitdepth(10)
                builder.setColorInfo(color.build())
            }
            return builder.build()
        }

        /** MediaFormat key of the RFC 6381 codecs string (MediaFormat.KEY_CODECS_STRING, API 30+; Media3 sets it). */
        private const val KEY_CODECS_STRING = "codecs-string"
    }
}

/** Video and audio track formats of a file. */
data class TrackFormats(val video: List<Format>, val audio: List<Format>, val protected: Boolean = false)
