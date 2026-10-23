// OWNER: HOM-04A
//
// The pure, Flutter-free and Android-free helpers of the Android thumbnailers (ARCH v1.2 V2-28,
// V2-104; BUILD_PLAN HOM-04A), JVM-tested (src/test/.../thumbnails/): request validation, source
// classification (`ms:<id>`, absolute path, `file://`, `content://`; `ph:` is Apple's), box
// geometry (fill = cover and centre-crop, fit = inside keeping the aspect ratio, as HOM-04's
// ThumbnailCore.swift), decode sample sizes, the encoder format actually written (WebP lossy on
// Android, V2-28; HEIC has no platform encoder here and is written as JPEG, the result says so)
// and the typed failures. Nothing here logs (rule 30) or opens a socket (rule 21).

package com.vecvel.danaview.library.thumbnails

import com.vecvel.danaview.library.glue.LibraryErrorCode
import com.vecvel.danaview.library.pigeon.ThumbnailFormatMsg
import com.vecvel.danaview.library.pigeon.ThumbnailModeMsg
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** A typed thumbnail failure: [code] becomes the Pigeon error code, [message] has no names or paths. */
class ThumbnailFailure(val code: LibraryErrorCode, message: String) : Exception(message) {
    companion object {
        fun notFound(m: String) = ThumbnailFailure(LibraryErrorCode.notFound, m)
        fun cancelled(m: String = "thumbnail cancelled") = ThumbnailFailure(LibraryErrorCode.cancelled, m)
        fun io(m: String) = ThumbnailFailure(LibraryErrorCode.ioError, m)
        fun invalid(m: String) = ThumbnailFailure(LibraryErrorCode.invalidArgument, m)
        fun busy(m: String) = ThumbnailFailure(LibraryErrorCode.busy, m)
        fun notSupported(m: String) = ThumbnailFailure(LibraryErrorCode.notSupportedOnDevice, m)
        fun permission(m: String) = ThumbnailFailure(LibraryErrorCode.permissionDenied, m)
    }
}

/** An integer pixel size. */
data class PxSize(val width: Int, val height: Int) {
    val longSide: Int get() = max(width, height)
}

/** An integer pixel rectangle (left, top, width, height) in source pixels. */
data class PxRect(val left: Int, val top: Int, val width: Int, val height: Int)

/** What a thumbnail `source` names. */
sealed class ThumbnailSource {
    /** A MediaStore row (`ms:<_ID>`). */
    data class MediaStoreItem(val id: Long) : ThumbnailSource()

    /** A local file (absolute path or `file://` URL), opened read-only. */
    data class LocalFile(val path: String) : ThumbnailSource()

    /** Any other `content://` URI, opened read-only. */
    data class Content(val uri: String) : ThumbnailSource()

    companion object {
        /** The source [s] names, or a typed failure (`ph:` is Apple's: notSupportedOnDevice). */
        fun parse(s: String): ThumbnailSource = when {
            s.startsWith("ms:") -> s.removePrefix("ms:").toLongOrNull()?.takeIf { it >= 0 }?.let { MediaStoreItem(it) }
                ?: throw ThumbnailFailure.invalid("bad MediaStore id")
            s.startsWith("ph:") -> throw ThumbnailFailure.notSupported("Apple photo library source")
            s.startsWith("content://") -> Content(s)
            s.startsWith("file://") -> LocalFile(decodeFileUrl(s) ?: throw ThumbnailFailure.invalid("bad file URL"))
            s.startsWith("/") -> LocalFile(s)
            else -> throw ThumbnailFailure.invalid("unknown source")
        }

        /** The path of a `file://` URL (percent-decoded), or null. */
        fun decodeFileUrl(s: String): String? {
            val rest = s.removePrefix("file://")
            val path = if (rest.startsWith("localhost/")) rest.removePrefix("localhost") else rest
            if (!path.startsWith("/")) return null
            return try {
                java.net.URLDecoder.decode(path.replace("+", "%2B"), "UTF-8")
            } catch (e: IllegalArgumentException) {
                null
            }
        }
    }
}

/** What kind of media a file is, by MIME type first, then extension. */
enum class MediaKind { IMAGE, VIDEO, PDF, OTHER }

object ThumbnailTypes {
    private val videoExt = setOf("mp4", "m4v", "mov", "3gp", "3g2", "webm", "mkv", "avi", "ts", "mts", "m2ts", "wmv", "flv", "mpg", "mpeg")
    private val imageExt = setOf("jpg", "jpeg", "png", "webp", "gif", "bmp", "heic", "heif", "avif", "dng", "wbmp", "ico")

    fun kind(mime: String?, name: String?): MediaKind {
        val m = mime?.lowercase()
        if (m != null) {
            if (m == "application/pdf") return MediaKind.PDF
            if (m.startsWith("video/")) return MediaKind.VIDEO
            if (m.startsWith("image/")) return MediaKind.IMAGE
        }
        val ext = name?.substringAfterLast('/')?.substringAfterLast('.', "")?.lowercase().orEmpty()
        return when {
            ext == "pdf" -> MediaKind.PDF
            ext in videoExt -> MediaKind.VIDEO
            ext in imageExt -> MediaKind.IMAGE
            else -> MediaKind.OTHER
        }
    }

    /** True when [head] (the first bytes of a file) starts like a PDF (`%PDF-`). */
    fun looksLikePdf(head: ByteArray): Boolean {
        val magic = "%PDF-".toByteArray(Charsets.US_ASCII)
        if (head.size < magic.size) return false
        // A PDF may have up to 1024 bytes of junk before the header; accept it anywhere in the head.
        outer@ for (i in 0..(head.size - magic.size)) {
            for (j in magic.indices) if (head[i + j] != magic[j]) continue@outer
            return true
        }
        return false
    }
}

object ThumbnailGeometry {
    /** Largest box side accepted (as on Apple). */
    const val MAX_SIDE = 4096

    /**
     * The pixel size of the thumbnail of a [source]-sized image in a [box]: exactly the box for
     * `fill`, the aspect-fitted size (at least 1 px per side, never upscaled) for `fit`.
     */
    fun outputSize(source: PxSize, box: PxSize, mode: ThumbnailModeMsg): PxSize {
        if (source.width <= 0 || source.height <= 0) return box
        if (mode == ThumbnailModeMsg.FILL) return box
        val s = min(min(box.width.toDouble() / source.width, box.height.toDouble() / source.height), 1.0)
        return PxSize(max(1, (source.width * s).roundToInt()), max(1, (source.height * s).roundToInt()))
    }

    /**
     * The pixel size of a document page thumbnail (HOM-04A, honouring scale and fit): the page of
     * [pageWidthPt]×[pageHeightPt] points (1/72 in) is [scale] pixels per point at its natural
     * size, and is fitted into [box] (`fit`: aspect kept, at least 1 px per side, never larger
     * than the natural size). A small page on a 1x screen stays small instead of being blown up.
     */
    fun documentSize(pageWidthPt: Int, pageHeightPt: Int, scale: Double, box: PxSize): PxSize {
        val pw = max(1, pageWidthPt).toDouble()
        val ph = max(1, pageHeightPt).toDouble()
        val s = min(scale, min(box.width / pw, box.height / ph))
        return PxSize(max(1, (pw * s).roundToInt()), max(1, (ph * s).roundToInt()))
    }

    /** The centred crop with the box's aspect for `fill`, the whole image for `fit` (source pixels). */
    fun cropRect(source: PxSize, box: PxSize, mode: ThumbnailModeMsg): PxRect {
        val whole = PxRect(0, 0, source.width, source.height)
        if (mode != ThumbnailModeMsg.FILL || source.width <= 0 || source.height <= 0 || box.width <= 0 || box.height <= 0) return whole
        val boxAspect = box.width.toDouble() / box.height
        val srcAspect = source.width.toDouble() / source.height
        return if (srcAspect > boxAspect) {
            val w = max(1, min(source.width, (source.height * boxAspect).roundToInt()))
            PxRect((source.width - w) / 2, 0, w, source.height)
        } else {
            val h = max(1, min(source.height, (source.width / boxAspect).roundToInt()))
            PxRect(0, (source.height - h) / 2, source.width, h)
        }
    }

    /**
     * The size to ask a fitting decoder for so its result covers [box] (`fill`) or fits it (`fit`);
     * [source] is the pixel size when known. Capped at [MAX_SIDE].
     */
    fun requestSize(source: PxSize?, box: PxSize, mode: ThumbnailModeMsg): PxSize {
        if (mode != ThumbnailModeMsg.FILL) return box
        if (source == null || source.width <= 0 || source.height <= 0) {
            val side = min(MAX_SIDE, ceil(max(box.width, box.height) * 16.0 / 9.0).toInt())
            return PxSize(side, side)
        }
        val scale = max(box.width.toDouble() / source.width, box.height.toDouble() / source.height)
        return PxSize(min(MAX_SIDE, ceil(source.width * scale).toInt()), min(MAX_SIDE, ceil(source.height * scale).toInt()))
    }

    /**
     * The largest power-of-two `inSampleSize` that keeps a [source]-sized decode at least [want]
     * on both sides (1 when the source is already smaller).
     */
    fun sampleSize(source: PxSize, want: PxSize): Int {
        if (source.width <= 0 || source.height <= 0 || want.width <= 0 || want.height <= 0) return 1
        var s = 1
        while (source.width / (s * 2) >= want.width && source.height / (s * 2) >= want.height) s *= 2
        return s
    }

    /**
     * True when a decoded [have]-sized image is noticeably smaller (more than 10 %) than the [want]
     * size it was asked for while the original ([source], when known) is larger: the caller then
     * decodes the original instead (MediaStore's cached thumbnails are ~512 px).
     */
    fun tooSmall(have: PxSize, want: PxSize, mode: ThumbnailModeMsg, source: PxSize?): Boolean {
        val needed = if (mode == ThumbnailModeMsg.FILL) {
            // Must cover the box: compare the short sides scaled to the box's aspect.
            max(want.width.toDouble() / max(1, have.width), want.height.toDouble() / max(1, have.height))
        } else {
            // Must reach the fitted size: the larger image side vs the box's limiting side.
            min(want.width.toDouble() / max(1, have.width), want.height.toDouble() / max(1, have.height))
        }
        if (needed <= 1.1) return false
        return source == null || source.longSide > have.longSide
    }

    /** [size] with width and height swapped for quarter-turn [rotationDegrees]. */
    fun rotated(size: PxSize, rotationDegrees: Int): PxSize =
        if (((rotationDegrees % 360) + 360) % 180 == 90) PxSize(size.height, size.width) else size
}

object ThumbnailEncoding {
    /** The format actually written for a [requested] one (no HEIC encoder on Android: JPEG). */
    fun effectiveFormat(requested: ThumbnailFormatMsg): ThumbnailFormatMsg = when (requested) {
        ThumbnailFormatMsg.HEIC -> ThumbnailFormatMsg.JPEG
        else -> requested
    }

    /** Encoder quality 0…100 of [quality] 0…1; lossy WebP below 100 on API < 30 needs < 100. */
    fun quality100(quality: Double, format: ThumbnailFormatMsg): Int {
        val q = (quality.coerceIn(0.0, 1.0) * 100).roundToInt()
        return if (format == ThumbnailFormatMsg.WEBP) min(q, 99) else q
    }

    /** True when the output keeps an alpha channel (PNG); the others are drawn on black, as on Apple. */
    fun keepsAlpha(format: ThumbnailFormatMsg): Boolean = format == ThumbnailFormatMsg.PNG
}

object ThumbnailRequests {
    /** The validation failure of a request with these fields, or null when it is well-formed. */
    fun validate(requestId: String, widthPx: Long, heightPx: Long, quality: Double, outputPath: String): ThumbnailFailure? {
        val side = ThumbnailGeometry.MAX_SIDE.toLong()
        if (requestId.isEmpty()) return ThumbnailFailure.invalid("empty request id")
        if (widthPx < 1 || heightPx < 1 || widthPx > side || heightPx > side) return ThumbnailFailure.invalid("box out of range")
        if (quality.isNaN() || quality < 0.0 || quality > 1.0) return ThumbnailFailure.invalid("quality out of range")
        if (!outputPath.startsWith("/")) return ThumbnailFailure.invalid("output path is not absolute")
        return null
    }

    /** The validation failure of a document request's screen [scale] (finite, above 0), or null. */
    fun validateScale(scale: Double): ThumbnailFailure? =
        if (scale.isNaN() || scale.isInfinite() || scale <= 0.0) ThumbnailFailure.invalid("scale out of range") else null
}
