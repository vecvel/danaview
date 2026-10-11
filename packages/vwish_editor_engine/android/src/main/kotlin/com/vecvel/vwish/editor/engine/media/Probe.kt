@file:OptIn(UnstableApi::class, ExperimentalApi::class)
// OWNER: AND-02
//
// Media probe (ARCH §15 'Probe / compatibility', §12.5, D-27; BUILD_PLAN AND-02). Read-only, for
// file paths, file:// and content:// URIs:
//
// - container: sniffed from the first 64 bytes (EBML DocType for Matroska/WebM, ftyp brands, RIFF
//   forms, magic numbers), falling back to the extension or the content MIME type. Same names as
//   iOS (`SniffedContainer`): mp4, mov, m4a, 3gp, matroska, webm, avi, wav, ... MKV and WebM are
//   editable on Android when decoders exist (ARCH §15).
// - images: BitmapFactory bounds + EXIF orientation.
// - audio/video: Media3 `MetadataRetriever` (track groups -> Formats: codec, size, rotation,
//   pixel aspect, colour info -> transfer and bit depth, channels, rate, DRM; duration with edit
//   lists applied) plus `MediaExtractorCompat` for the first video samples' presentation times,
//   which give the measured fps and the VFR flag (shortest frame > 5 % shorter than the average,
//   the same rule as iOS `isVariableFrameRate`).
// - editable: a decoder exists for the first video track (or the first audio track of an audio
//   file) via `CodecInventory` (MediaCodecList), the file is not DRM-protected, and HDR video can be
//   tone-mapped on this device (`Compatibility.hdrToneMappable`: GL_EXT_YUV_target + a 10-bit
//   decoder for the OpenGL path, or API 31+ for MediaCodec tone mapping; AND-01 V-N5).
//
// `MediaSources` holds the URI helpers the other media services share (AND-03..AND-07).
// Never puts paths, URIs or user content into errors or logs.

package com.vecvel.vwish.editor.engine.media

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.BitmapFactory
import android.media.ExifInterface
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.ExperimentalApi
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.source.TrackGroupArray
import androidx.media3.inspector.MediaExtractorCompat
import androidx.media3.inspector.MetadataRetriever
import com.vecvel.vwish.editor.engine.core.CodecInventory
import com.vecvel.vwish.editor.engine.core.Completion
import com.vecvel.vwish.editor.engine.core.EngineContext
import com.vecvel.vwish.editor.engine.core.EngineErrorCode
import com.vecvel.vwish.editor.engine.core.EngineErrors
import com.vecvel.vwish.editor.engine.core.EngineException
import com.vecvel.vwish.editor.engine.core.ToneMappingSupport
import com.vecvel.vwish.editor.engine.core.fail
import com.vecvel.vwish.editor.engine.core.succeed
import com.vecvel.vwish.editor.engine.pigeon.ColorTransferMsg
import com.vecvel.vwish.editor.engine.pigeon.MediaKindMsg
import com.vecvel.vwish.editor.engine.pigeon.ProbeMsg
import com.vecvel.vwish.editor.engine.pigeon.ResolvedMediaMsg
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/** Container families recognised from the first bytes of a file (names equal iOS `SniffedContainer`). */
enum class SniffedContainer(val wireName: String) {
    MP4("mp4"), MOV("mov"), M4A("m4a"), THREE_GP("3gp"), MATROSKA("matroska"), WEBM("webm"), AVI("avi"),
    WAV("wav"), AIFF("aiff"), MP3("mp3"), AAC("aac"), FLAC("flac"), CAF("caf"), OGG("ogg"),
    JPEG("jpeg"), PNG("png"), HEIC("heic"), GIF("gif"), TIFF("tiff"), WEBP("webp"), BMP("bmp"),
    UNKNOWN("unknown");

    /** Whether this is a still-image container. */
    val isImage: Boolean get() = this == JPEG || this == PNG || this == HEIC || this == GIF || this == TIFF || this == WEBP || this == BMP

    companion object {
        /** Sniffs [head] (the first bytes); [hint] is a lower-case extension or MIME type used as fallback. */
        fun sniff(head: ByteArray, hint: String?): SniffedContainer {
            val b = head
            fun ascii(offset: Int, length: Int): String? =
                if (b.size >= offset + length) String(b, offset, length, Charsets.ISO_8859_1) else null
            fun u(i: Int) = b[i].toInt() and 0xFF
            if (b.size >= 4 && u(0) == 0x1A && u(1) == 0x45 && u(2) == 0xDF && u(3) == 0xA3) {
                // EBML: the DocType decides between Matroska and WebM.
                return if (String(b, Charsets.ISO_8859_1).contains("webm")) WEBM else MATROSKA
            }
            if (ascii(0, 4) == "RIFF") {
                when (ascii(8, 4)) {
                    "AVI " -> return AVI
                    "WAVE" -> return WAV
                    "WEBP" -> return WEBP
                }
            }
            if (ascii(0, 4) == "FORM" && (ascii(8, 4) == "AIFF" || ascii(8, 4) == "AIFC")) return AIFF
            if (ascii(0, 4) == "OggS") return OGG
            if (ascii(0, 4) == "fLaC") return FLAC
            if (ascii(0, 4) == "caff") return CAF
            if (ascii(0, 3) == "ID3") return MP3
            if (b.size >= 3 && u(0) == 0xFF && u(1) == 0xD8 && u(2) == 0xFF) return JPEG
            if (b.size >= 8 && u(0) == 0x89 && ascii(1, 3) == "PNG") return PNG
            if (ascii(0, 4) == "GIF8") return GIF
            if (ascii(0, 4) == "II*\u0000" || ascii(0, 4) == "MM\u0000*") return TIFF
            if (b.size >= 2 && u(0) == 0x42 && u(1) == 0x4D && hintIs(hint, "bmp")) return BMP
            if (ascii(4, 4) == "ftyp") {
                val brand = ascii(8, 4)
                when (brand) {
                    "qt  " -> return MOV
                    "M4A ", "M4B ", "M4P " -> return M4A
                    "3gp4", "3gp5", "3gp6", "3gp7", "3ge6", "3g2a" -> return THREE_GP
                    "heic", "heix", "mif1", "msf1", "heim", "heis", "avif" -> return HEIC
                }
                if (hintIs(hint, "mov") || hintIs(hint, "quicktime")) return MOV
                if (hintIs(hint, "m4a")) return M4A
                return MP4
            }
            val atom = ascii(4, 4)
            if (atom in setOf("moov", "mdat", "wide", "free", "skip", "pnot")) return MOV
            if (b.size >= 2 && u(0) == 0xFF && (u(1) and 0xF6) == 0xF0) return AAC // ADTS sync word
            if (b.size >= 2 && u(0) == 0xFF && (u(1) and 0xE0) == 0xE0) return MP3 // MPEG audio frame sync
            return fromHint(hint)
        }

        private fun hintIs(hint: String?, token: String): Boolean = hint?.contains(token) == true

        /** The container named by an extension or MIME type. */
        fun fromHint(hint: String?): SniffedContainer {
            val h = hint?.lowercase() ?: return UNKNOWN
            return when {
                h == "mp4" || h == "m4v" || h.endsWith("/mp4") -> MP4
                h == "mov" || h == "qt" || h.endsWith("/quicktime") -> MOV
                h == "m4a" || h.endsWith("/mp4a-latm") || h.endsWith("/x-m4a") || h == "audio/mp4" -> M4A
                h == "3gp" || h.endsWith("/3gpp") -> THREE_GP
                h == "mkv" || h.endsWith("matroska") || h.endsWith("/x-matroska") -> MATROSKA
                h == "webm" || h.endsWith("/webm") -> WEBM
                h == "avi" || h.endsWith("/x-msvideo") -> AVI
                h == "wav" || h.endsWith("/wav") || h.endsWith("/x-wav") -> WAV
                h == "mp3" || h.endsWith("/mpeg") -> MP3
                h == "aac" || h.endsWith("/aac") -> AAC
                h == "flac" || h.endsWith("/flac") -> FLAC
                h == "ogg" || h == "opus" || h.endsWith("/ogg") -> OGG
                h == "jpg" || h == "jpeg" || h.endsWith("/jpeg") -> JPEG
                h == "png" || h.endsWith("/png") -> PNG
                h == "heic" || h == "heif" || h.endsWith("/heic") || h.endsWith("/heif") -> HEIC
                h == "gif" || h.endsWith("/gif") -> GIF
                h == "webp" || h.endsWith("/webp") -> WEBP
                h == "bmp" || h.endsWith("/bmp") -> BMP
                else -> UNKNOWN
            }
        }
    }
}

/** Probe and compatibility issue codes (`MediaProbe.issues`, `NotEditable.code`; iOS `ProbeIssue`). */
object ProbeIssue {
    const val CODEC_UNSUPPORTED = "codec_unsupported"
    const val PROTECTED_CONTENT = "protected_content"
    const val NOT_FOUND = "not_found"
    const val NO_TRACKS = "no_tracks"

    /** HDR video whose tone mapping this device cannot run (no GL_EXT_YUV_target + 10-bit decoder, API < 31). */
    const val HDR_UNSUPPORTED = "hdr_unsupported"

    // Informational (still editable).
    const val HDR = "hdr"
    const val HIGH_BIT_DEPTH = "high_bit_depth"
    const val VARIABLE_FRAME_RATE = "variable_frame_rate"

    /** A video whose audio track has no decoder: the video stays editable, its audio is silent (AND-08 drops it). */
    const val AUDIO_CODEC_UNSUPPORTED = "audio_codec_unsupported"
}

/** Codec names as iOS reports them (`ProbeMsg.videoCodec` / `audioCodec`). */
object CodecNames {
    /** The name of [mime] (a sample MIME type); [pcmEncoding] names raw audio. */
    fun of(mime: String?, pcmEncoding: Int = Format.NO_VALUE): String? = when (mime) {
        null -> null
        MimeTypes.VIDEO_H264 -> "h264"
        MimeTypes.VIDEO_H265, MimeTypes.VIDEO_DOLBY_VISION -> "hevc"
        MimeTypes.VIDEO_VP9 -> "vp9"
        MimeTypes.VIDEO_VP8 -> "vp8"
        MimeTypes.VIDEO_AV1 -> "av1"
        MimeTypes.VIDEO_MP4V -> "mpeg4"
        MimeTypes.VIDEO_H263 -> "h263"
        MimeTypes.VIDEO_MPEG2 -> "mpeg2"
        MimeTypes.VIDEO_MJPEG -> "mjpeg"
        MimeTypes.AUDIO_AAC -> "aac"
        MimeTypes.AUDIO_MPEG -> "mp3"
        MimeTypes.AUDIO_OPUS -> "opus"
        MimeTypes.AUDIO_VORBIS -> "vorbis"
        MimeTypes.AUDIO_FLAC -> "flac"
        MimeTypes.AUDIO_ALAC -> "alac"
        MimeTypes.AUDIO_AC3 -> "ac3"
        MimeTypes.AUDIO_E_AC3, MimeTypes.AUDIO_E_AC3_JOC -> "eac3"
        MimeTypes.AUDIO_AC4 -> "ac4"
        MimeTypes.AUDIO_DTS, MimeTypes.AUDIO_DTS_HD -> "dts"
        MimeTypes.AUDIO_AMR_NB -> "amr_nb"
        MimeTypes.AUDIO_AMR_WB -> "amr_wb"
        MimeTypes.AUDIO_ALAW -> "pcm_alaw"
        MimeTypes.AUDIO_MLAW -> "pcm_mulaw"
        MimeTypes.AUDIO_RAW -> when (pcmEncoding) {
            C.ENCODING_PCM_8BIT -> "pcm_u8"
            C.ENCODING_PCM_16BIT -> "pcm_s16le"
            C.ENCODING_PCM_16BIT_BIG_ENDIAN -> "pcm_s16be"
            C.ENCODING_PCM_24BIT -> "pcm_s24le"
            C.ENCODING_PCM_24BIT_BIG_ENDIAN -> "pcm_s24be"
            C.ENCODING_PCM_32BIT -> "pcm_s32le"
            C.ENCODING_PCM_32BIT_BIG_ENDIAN -> "pcm_s32be"
            C.ENCODING_PCM_FLOAT -> "pcm_f32le"
            else -> "pcm"
        }
        else -> mime.substringAfter('/').lowercase()
    }
}

/** Frame-rate facts of a video track measured from sample presentation times. */
data class FrameRateFacts(
    /** Average frames per second over the measured samples (null with fewer than 2 samples). */
    val averageFps: Double?,
    /** Shortest frame clearly (> 5 %) shorter than the average frame. */
    val variableFrameRate: Boolean,
) {
    /** Integer project rate nearest to [averageFps] (29.97 -> 30), at least 1. */
    val nominalFrameRate: Long? get() = averageFps?.let { kotlin.math.max(1L, it.roundToLong()) }

    companion object {
        /** VFR threshold: average frame duration / shortest frame duration (iOS `isVariableFrameRate`). */
        const val VFR_RATIO = 1.05

        /**
         * Facts of the presentation times [ptsUs] (any order; decode order is fine). With
         * [containerFps] (the container's declared rate) and fewer than 2 samples the declared rate
         * is used.
         */
        fun measure(ptsUs: LongArray, containerFps: Float = Format.NO_VALUE.toFloat()): FrameRateFacts {
            var sorted = ptsUs.distinct().sorted()
            // Samples come in decode order: the last few presentation times of a prefix can be
            // missing (B-frame reordering), so the tail is left out of the measurement.
            if (sorted.size > REORDER_TAIL * 4) sorted = sorted.subList(0, sorted.size - REORDER_TAIL)
            if (sorted.size < 2) {
                val fps = containerFps.takeIf { it > 0f }?.toDouble()
                return FrameRateFacts(fps, false)
            }
            val span = (sorted.last() - sorted.first()).toDouble()
            if (span <= 0.0) return FrameRateFacts(containerFps.takeIf { it > 0f }?.toDouble(), false)
            val average = span / (sorted.size - 1)
            var shortest = Long.MAX_VALUE
            for (i in 1 until sorted.size) shortest = kotlin.math.min(shortest, sorted[i] - sorted[i - 1])
            val vfr = shortest > 0 && average / shortest > VFR_RATIO
            return FrameRateFacts(1_000_000.0 / average, vfr)
        }

        /** Presentation times left out at the end of a decode-order prefix (reorder window). */
        const val REORDER_TAIL = 8
    }
}

/** URI helpers shared by the Android media services (AND-02..AND-07). */
object MediaSources {
    /** [uri] (a `file://` or `content://` URI, or an absolute path) as an Android Uri. */
    fun toUri(uri: String): Uri = when {
        uri.startsWith("content://") || uri.startsWith("file://") -> Uri.parse(uri)
        else -> Uri.fromFile(File(uri))
    }

    /** The local file of a path or `file://` URI, or null for `content://`. */
    fun localFile(uri: String): File? = when {
        uri.startsWith("content://") -> null
        uri.startsWith("file://") -> Uri.parse(uri).path?.let(::File)
        else -> File(uri)
    }

    /** A Media3 MediaItem for [uri]. */
    fun mediaItem(uri: String): MediaItem = MediaItem.fromUri(toUri(uri))

    /** Opens [uri] for reading; `mediaOffline` when it is gone, `permissionDenied` when access was revoked. */
    fun open(context: Context, uri: String): InputStream {
        val file = localFile(uri)
        return try {
            if (file != null) {
                if (!file.isFile) throw EngineException(EngineErrorCode.mediaOffline, "file not found")
                if (!file.canRead()) throw EngineException(EngineErrorCode.permissionDenied, "file not readable")
                file.inputStream()
            } else {
                context.contentResolver.openInputStream(toUri(uri))
                    ?: throw EngineException(EngineErrorCode.mediaOffline, "content not available")
            }
        } catch (e: FileNotFoundException) {
            throw EngineException(EngineErrorCode.mediaOffline, "file not found", cause = e)
        } catch (e: SecurityException) {
            throw EngineException(EngineErrorCode.permissionDenied, "access denied", cause = e)
        }
    }

    /** The first [count] bytes of [uri] (fewer for short files). */
    fun head(context: Context, uri: String, count: Int = 64): ByteArray = open(context, uri).use { input ->
        val buffer = ByteArray(count)
        var read = 0
        while (read < count) {
            val n = input.read(buffer, read, count - read)
            if (n < 0) break
            read += n
        }
        buffer.copyOf(read)
    }

    /** Size in bytes of [uri] (0 when unknown). */
    fun size(context: Context, uri: String): Long {
        localFile(uri)?.let { return if (it.isFile) it.length() else 0L }
        return try {
            context.contentResolver.openAssetFileDescriptor(toUri(uri), "r")?.use { afd ->
                if (afd.length >= 0) afd.length else afd.parcelFileDescriptor.statSize.coerceAtLeast(0)
            } ?: 0L
        } catch (e: IOException) {
            0L
        } catch (e: SecurityException) {
            0L
        }
    }

    /** Whether [uri] exists and is readable; throws `permissionDenied` for a revoked grant. */
    fun exists(context: Context, uri: String): Boolean {
        localFile(uri)?.let { return it.isFile }
        return try {
            context.contentResolver.openAssetFileDescriptor(toUri(uri), "r")?.use { true } ?: false
        } catch (e: FileNotFoundException) {
            false
        } catch (e: SecurityException) {
            throw EngineException(EngineErrorCode.permissionDenied, "access denied", cause = e)
        }
    }

    /** Lower-case extension of a path/file URI, or the MIME type of a content URI (sniff fallback). */
    fun hint(context: Context, uri: String): String? {
        localFile(uri)?.let { return it.extension.lowercase().ifEmpty { null } }
        return try {
            context.contentResolver.getType(toUri(uri))?.lowercase()
        } catch (e: RuntimeException) {
            null
        }
    }

    /** A MediaExtractorCompat with [uri] set as its data source (caller releases it). */
    fun extractor(context: Context, uri: String): MediaExtractorCompat {
        val extractor = MediaExtractorCompat(context)
        try {
            val file = localFile(uri)
            if (file != null) {
                if (!file.isFile) throw EngineException(EngineErrorCode.mediaOffline, "file not found")
                extractor.setDataSource(file.absolutePath)
            } else {
                extractor.setDataSource(toUri(uri), 0L)
            }
            return extractor
        } catch (t: Throwable) {
            extractor.release()
            throw mapOpenError(t)
        }
    }

    /** Maps a failure to open or parse media to an [EngineException]. */
    fun mapOpenError(t: Throwable): EngineException {
        val cause = if (t is ExecutionException) t.cause ?: t else t
        return when (cause) {
            is EngineException -> cause
            is FileNotFoundException -> EngineException(EngineErrorCode.mediaOffline, "file not found", cause = cause)
            is SecurityException -> EngineException(EngineErrorCode.permissionDenied, "access denied", cause = cause)
            is androidx.media3.common.ParserException ->
                EngineException(EngineErrorCode.unsupportedMedia, "unrecognised media format", cause = cause)
            is androidx.media3.exoplayer.source.UnrecognizedInputFormatException ->
                EngineException(EngineErrorCode.unsupportedMedia, "unrecognised media format", cause = cause)
            is IOException -> {
                val nested = cause.cause
                if (nested is androidx.media3.common.ParserException) {
                    EngineException(EngineErrorCode.unsupportedMedia, "unrecognised media format", cause = cause)
                } else {
                    EngineErrors.from(cause)
                }
            }
            else -> EngineErrors.from(cause)
        }
    }
}

/** Media probe (ARCH §15 Probe; AND-02). Called on vwish-io. */
class Probe(private val ctx: EngineContext) {
    /** Probes [media] (read-only; content:// and file paths). */
    fun probe(media: ResolvedMediaMsg, done: Completion<ProbeMsg>) {
        try {
            done.succeed(probe(media.uri))
        } catch (t: Throwable) {
            done.fail(EngineErrors.from(t).withFingerprint(media.fingerprint))
        }
    }

    /** Probes [uri] synchronously (blocking; never on main). */
    fun probe(uri: String): ProbeMsg = probe(ctx.appContext, uri, ctx.deviceProfile.codecs(), ctx.deviceProfile.toneMapping())

    companion object {
        /** Wait limit for Media3's MetadataRetriever futures. */
        const val RETRIEVE_TIMEOUT_MS = 10_000L

        /** Video samples read to measure fps and VFR. */
        const val FPS_SAMPLES = 240

        /** Probes [uri] with the device's [codecs] and [toneMapping] facts. */
        fun probe(context: Context, uri: String, codecs: CodecInventory, toneMapping: ToneMappingSupport): ProbeMsg {
            if (!MediaSources.exists(context, uri)) throw EngineException(EngineErrorCode.mediaOffline, "file not found")
            val size = MediaSources.size(context, uri)
            val container = SniffedContainer.sniff(MediaSources.head(context, uri), MediaSources.hint(context, uri))
            if (container.isImage) return probeImage(context, uri, container, size)
            return probeAv(context, uri, container, size, codecs, toneMapping)
        }

        // The platform ExifInterface is reliable from API 25 and the editor gates on API 29
        // (androidx.exifinterface is not a dependency of the frozen build).
        @SuppressLint("ExifInterface")
        private fun probeImage(context: Context, uri: String, container: SniffedContainer, size: Long): ProbeMsg {
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            MediaSources.open(context, uri).use { BitmapFactory.decodeStream(it, null, options) }
            if (options.outWidth <= 0 || options.outHeight <= 0) {
                throw EngineException(EngineErrorCode.unsupportedMedia, "image not decodable")
            }
            val rotation = try {
                MediaSources.open(context, uri).use { input ->
                    when (ExifInterface(input).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                        ExifInterface.ORIENTATION_ROTATE_180, ExifInterface.ORIENTATION_FLIP_VERTICAL -> 180L
                        ExifInterface.ORIENTATION_ROTATE_90, ExifInterface.ORIENTATION_TRANSPOSE -> 90L
                        ExifInterface.ORIENTATION_ROTATE_270, ExifInterface.ORIENTATION_TRANSVERSE -> 270L
                        else -> 0L
                    }
                }
            } catch (e: IOException) {
                0L
            }
            val swap = rotation == 90L || rotation == 270L
            val w = options.outWidth.toLong()
            val h = options.outHeight.toLong()
            return ProbeMsg(
                kind = MediaKindMsg.IMAGE, durationUs = 0, hasVideo = false, hasAudio = false,
                width = if (swap) h else w, height = if (swap) w else h, rotation = rotation,
                variableFrameRate = false, container = container.wireName, audioStreams = 0,
                bitDepth = 8, transfer = ColorTransferMsg.SDR, sizeBytes = size, editable = true, issues = emptyList(),
            )
        }

        private fun probeAv(
            context: Context,
            uri: String,
            container: SniffedContainer,
            size: Long,
            codecs: CodecInventory,
            toneMapping: ToneMappingSupport,
        ): ProbeMsg {
            val (groups, durationUs) = retrieve(context, uri)
            val videos = ArrayList<Format>()
            val audios = ArrayList<Format>()
            for (i in 0 until groups.length) {
                val group = groups[i]
                if (group.length == 0) continue
                val format = group.getFormat(0)
                when (MimeTypes.getTrackType(format.sampleMimeType)) {
                    C.TRACK_TYPE_VIDEO -> if (!MimeTypes.isImage(format.sampleMimeType)) videos.add(format)
                    C.TRACK_TYPE_AUDIO -> audios.add(format)
                }
            }
            if (videos.isEmpty() && audios.isEmpty()) {
                throw EngineException(EngineErrorCode.unsupportedMedia, "no audio or video tracks")
            }
            val issues = ArrayList<String>()
            var editable = true
            if ((videos + audios).any { it.drmInitData != null || it.cryptoType != C.CRYPTO_TYPE_NONE }) {
                issues.add(ProbeIssue.PROTECTED_CONTENT)
                editable = false
            }
            val video = videos.firstOrNull()
            val audio = audios.firstOrNull()

            var width: Long? = null
            var height: Long? = null
            var rotation = 0L
            var bitDepth: Long? = null
            var transfer = ColorTransferMsg.SDR
            var rate = FrameRateFacts(null, false)
            if (video != null) {
                rotation = (((video.rotationDegrees % 360) + 360) % 360).toLong()
                val par = if (video.pixelWidthHeightRatio > 0f) video.pixelWidthHeightRatio else 1f
                val w = if (par != 1f) (video.width * par).roundToInt() else video.width
                val h = video.height
                val swap = rotation == 90L || rotation == 270L
                if (w > 0 && h > 0) {
                    width = (if (swap) h else w).toLong()
                    height = (if (swap) w else h).toLong()
                }
                bitDepth = VideoFormats.bitDepth(video).toLong()
                transfer = VideoFormats.transfer(video)
                rate = measureFrameRate(context, uri, video.frameRate)
                if (!codecs.hasDecoder(video)) {
                    issues.add(ProbeIssue.CODEC_UNSUPPORTED)
                    editable = false
                } else if (transfer != ColorTransferMsg.SDR && !toneMapping.canToneMap(codecs, video)) {
                    issues.add(ProbeIssue.HDR_UNSUPPORTED)
                    editable = false
                }
                if (transfer != ColorTransferMsg.SDR) issues.add(ProbeIssue.HDR)
                if ((bitDepth ?: 8L) > 8L) issues.add(ProbeIssue.HIGH_BIT_DEPTH)
                if (rate.variableFrameRate) issues.add(ProbeIssue.VARIABLE_FRAME_RATE)
            }
            if (audio != null && !codecs.hasDecoder(audio)) {
                if (video == null) {
                    issues.add(ProbeIssue.CODEC_UNSUPPORTED)
                    editable = false
                } else {
                    issues.add(ProbeIssue.AUDIO_CODEC_UNSUPPORTED)
                }
            }
            return ProbeMsg(
                kind = if (video != null) MediaKindMsg.VIDEO else MediaKindMsg.AUDIO,
                durationUs = durationUs,
                hasVideo = video != null,
                hasAudio = audio != null,
                width = width,
                height = height,
                rotation = rotation,
                nominalFrameRate = rate.nominalFrameRate,
                nominalFps = rate.averageFps,
                variableFrameRate = rate.variableFrameRate,
                container = container.takeIf { it != SniffedContainer.UNKNOWN }?.wireName,
                videoCodec = video?.let { CodecNames.of(it.sampleMimeType) },
                audioCodec = audio?.let { CodecNames.of(it.sampleMimeType, it.pcmEncoding) },
                audioStreams = audios.size.toLong(),
                channels = audio?.channelCount?.takeIf { it > 0 }?.toLong(),
                sampleRate = audio?.sampleRate?.takeIf { it > 0 }?.toLong(),
                bitDepth = bitDepth,
                transfer = transfer,
                sizeBytes = size,
                editable = editable,
                issues = issues.distinct(),
            )
        }

        /** Track groups and duration (µs, edit lists applied) via Media3's MetadataRetriever. */
        private fun retrieve(context: Context, uri: String): Pair<TrackGroupArray, Long> {
            try {
                MetadataRetriever.Builder(context, MediaSources.mediaItem(uri)).build().use { retriever ->
                    val groups = retriever.retrieveTrackGroups().get(RETRIEVE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                    val duration = retriever.retrieveDurationUs().get(RETRIEVE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                    return groups to (if (duration == C.TIME_UNSET || duration < 0) 0L else duration)
                }
            } catch (e: TimeoutException) {
                throw EngineException(EngineErrorCode.io, "probe timed out", retryable = true, cause = e)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                throw EngineException(EngineErrorCode.interrupted, "probe interrupted", cause = e)
            } catch (t: Throwable) {
                throw MediaSources.mapOpenError(t)
            }
        }

        /** Measures fps/VFR from the first [FPS_SAMPLES] video sample times (edit lists applied by Media3). */
        private fun measureFrameRate(context: Context, uri: String, containerFps: Float): FrameRateFacts {
            val extractor = try {
                MediaSources.extractor(context, uri)
            } catch (e: EngineException) {
                return FrameRateFacts.measure(LongArray(0), containerFps)
            }
            try {
                val track = (0 until extractor.trackCount).firstOrNull {
                    extractor.getTrackFormat(it).getString(android.media.MediaFormat.KEY_MIME)?.startsWith("video/") == true
                } ?: return FrameRateFacts.measure(LongArray(0), containerFps)
                extractor.selectTrack(track)
                val times = LongArray(FPS_SAMPLES)
                var n = 0
                while (n < FPS_SAMPLES) {
                    val t = extractor.sampleTime
                    if (t < 0) break
                    times[n++] = t
                    if (!extractor.advance()) break
                }
                return FrameRateFacts.measure(times.copyOf(n), containerFps)
            } catch (e: RuntimeException) {
                return FrameRateFacts.measure(LongArray(0), containerFps)
            } finally {
                extractor.release()
            }
        }
    }
}

/** Video format facts shared by probe and compatibility. */
object VideoFormats {
    /** Luma bit depth from the colour info, else from the codec profile (Main10, VP9 profile 2/3), else 8. */
    fun bitDepth(format: Format): Int {
        val luma = format.colorInfo?.lumaBitdepth ?: Format.NO_VALUE
        if (luma > 0) return luma
        val codecs = format.codecs?.lowercase()
        if (codecs != null) {
            // hvc1.2.* / hev1.2.* = HEVC Main10; vp09.02.* / vp09.03.* = VP9 profile 2/3; av01.*.*.10 = 10-bit.
            if (Regex("""^(hvc1|hev1|dvh1|dvhe)\.2\.""").containsMatchIn(codecs)) return 10
            Regex("""^vp09\.0([0-3])\.\d+\.(\d+)""").find(codecs)?.let { return it.groupValues[2].toInt() }
            Regex("""^av01\.\d\.\d+[mh]\.(\d+)""").find(codecs)?.let { return it.groupValues[1].toInt() }
        }
        val transfer = format.colorInfo?.colorTransfer ?: Format.NO_VALUE
        if (transfer == C.COLOR_TRANSFER_HLG || transfer == C.COLOR_TRANSFER_ST2084) return 10
        return 8
    }

    /** HLG/PQ/SDR from the colour info. */
    fun transfer(format: Format): ColorTransferMsg = when (format.colorInfo?.colorTransfer) {
        C.COLOR_TRANSFER_HLG -> ColorTransferMsg.HLG
        C.COLOR_TRANSFER_ST2084 -> ColorTransferMsg.PQ
        else -> ColorTransferMsg.SDR
    }
}

/** Adds [fingerprint] to an engine error (job and probe failures carry the media fingerprint). */
internal fun EngineException.withFingerprint(fingerprint: String): EngineException =
    if (mediaFingerprint != null) this else EngineException(code, message ?: code.name, itemId, fingerprint, retryable, cause)
