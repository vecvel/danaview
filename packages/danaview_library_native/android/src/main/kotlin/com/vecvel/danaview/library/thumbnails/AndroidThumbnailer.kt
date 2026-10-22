// OWNER: HOM-04A
//
// The Flutter-free Android thumbnailers (ARCH v1.2 V2-28, V2-104; BUILD_PLAN HOM-04A), run on a
// background thread by ThumbnailHostApiImpl and directly by the instrumented tests:
//
// * MediaStore rows (`ms:<id>`): `ContentResolver.loadThumbnail` on API 29+ (images and videos;
//   when MediaStore's cached thumbnail is too small for the request, the original is decoded
//   instead), below that a sampled decode of the original with the row's ORIENTATION (images) or
//   `MediaMetadataRetriever` (videos).
// * Files (absolute path, `file://`): `ThumbnailUtils.createImageThumbnail` /
//   `createVideoThumbnail` on API 29+, a sampled BitmapFactory decode with the EXIF orientation /
//   `MediaMetadataRetriever` below.
// * Other `content://` URIs: a sampled decode with the EXIF orientation (images) or
//   `MediaMetadataRetriever` (videos).
// * Documents: `PdfRenderer`'s first page (white paper, fitted into the box, may upscale: PDF is
//   vector); other documents have no thumbnail (null, the caller shows a type icon).
//
// The bitmap is then cropped / fitted into the box (ThumbnailGeometry, the same rules as HOM-04 on
// Apple) and encoded as lossy WebP (V2-28), JPEG or PNG as asked (HEIC is written as JPEG) into a
// part file that is renamed over the output path. Sources are only ever opened read-only (rule 27);
// the only file written is the output in the thumbnail cache. Corrupt or unreadable media fail with
// a typed ThumbnailFailure (ioError), never a crash. Nothing is logged (rule 30).

package com.vecvel.danaview.library.thumbnails

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.pdf.PdfRenderer
import android.media.MediaMetadataRetriever
import android.media.ThumbnailUtils
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.OperationCanceledException
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Size
import androidx.exifinterface.media.ExifInterface
import com.vecvel.danaview.library.pigeon.ThumbnailFormatMsg
import com.vecvel.danaview.library.pigeon.ThumbnailModeMsg
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** A cancellation flag shared by a request and its cancel call; also cancels platform signals. Thread-safe. */
class ThumbnailCancelToken {
    private val cancelled = AtomicBoolean(false)
    private val signals = ArrayList<CancellationSignal>()

    val isCancelled: Boolean get() = cancelled.get()

    /** A CancellationSignal cancelled together with this token. */
    fun signal(): CancellationSignal {
        val s = CancellationSignal()
        synchronized(signals) { signals.add(s) }
        if (isCancelled) s.cancel()
        return s
    }

    fun cancel() {
        if (!cancelled.compareAndSet(false, true)) return
        val all = synchronized(signals) { signals.toList() }
        all.forEach { runCatching { it.cancel() } }
    }

    fun check() {
        if (isCancelled) throw ThumbnailFailure.cancelled()
    }
}

/** What was written. */
data class ThumbnailOutput(val path: String, val widthPx: Int, val heightPx: Int, val format: ThumbnailFormatMsg)

class AndroidThumbnailer(context: Context) {
    private val app = context.applicationContext
    private val resolver: ContentResolver = app.contentResolver

    /** Writes the thumbnail of a media [source] (an image or a video) into [box] at [outputPath]. */
    fun media(
        source: ThumbnailSource,
        box: PxSize,
        mode: ThumbnailModeMsg,
        format: ThumbnailFormatMsg,
        quality: Double,
        outputPath: String,
        token: ThumbnailCancelToken,
    ): ThumbnailOutput {
        token.check()
        val bitmap = try {
            when (source) {
                is ThumbnailSource.MediaStoreItem -> mediaStoreBitmap(source.id, box, mode, token)
                is ThumbnailSource.LocalFile -> fileBitmap(source.path, box, mode, token)
                is ThumbnailSource.Content -> contentBitmap(Uri.parse(source.uri), box, mode, token)
            }
        } catch (f: ThumbnailFailure) {
            throw f
        } catch (e: OperationCanceledException) {
            throw ThumbnailFailure.cancelled()
        } catch (e: FileNotFoundException) {
            throw if (token.isCancelled) ThumbnailFailure.cancelled() else ThumbnailFailure.notFound("source not found")
        } catch (e: SecurityException) {
            throw ThumbnailFailure.permission("source not readable")
        } catch (e: IOException) {
            throw if (token.isCancelled) ThumbnailFailure.cancelled() else ThumbnailFailure.io("unreadable or corrupt media")
        } catch (e: OutOfMemoryError) {
            throw ThumbnailFailure.io("media too large to decode")
        } catch (e: RuntimeException) {
            // MediaMetadataRetriever / decoders throw IllegalArgumentException or
            // IllegalStateException on broken input.
            throw if (token.isCancelled) ThumbnailFailure.cancelled() else ThumbnailFailure.io("unreadable or corrupt media")
        } ?: throw ThumbnailFailure.io("unreadable or corrupt media")
        try {
            token.check()
            return write(bitmap, box, mode, format, quality, outputPath, token)
        } finally {
            bitmap.recycle()
        }
    }

    /**
     * Writes the first-page thumbnail of the document at [path] fitted into [box]; null when the
     * document has no thumbnail here (not a PDF, or an encrypted one).
     */
    fun document(path: String, box: PxSize, format: ThumbnailFormatMsg, quality: Double, outputPath: String, token: ThumbnailCancelToken): ThumbnailOutput? {
        token.check()
        val file = checkedFile(path)
        val isPdf = ThumbnailTypes.kind(null, file.name) == MediaKind.PDF || readHead(file)?.let(ThumbnailTypes::looksLikePdf) == true
        if (!isPdf) return null
        val bitmap = try {
            renderPdfFirstPage(file, box, token)
        } catch (f: ThumbnailFailure) {
            throw f
        } catch (e: SecurityException) {
            return null // password-protected: no thumbnail, the caller shows the type icon
        } catch (e: IOException) {
            throw ThumbnailFailure.io("unreadable or corrupt document")
        } catch (e: OutOfMemoryError) {
            throw ThumbnailFailure.io("document page too large")
        } catch (e: RuntimeException) {
            throw ThumbnailFailure.io("unreadable or corrupt document")
        } ?: return null
        try {
            token.check()
            return write(bitmap, box, ThumbnailModeMsg.FIT, format, quality, outputPath, token)
        } finally {
            bitmap.recycle()
        }
    }

    // ---------------------------------------------------------------------------------------------
    // MediaStore

    private class Row(val uri: Uri, val kind: MediaKind, val size: PxSize?, val orientation: Int)

    private fun mediaStoreRow(id: Long): Row {
        val files = MediaStore.Files.getContentUri("external")
        val projection = arrayOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.WIDTH,
            MediaStore.MediaColumns.HEIGHT,
            MediaStore.Images.ImageColumns.ORIENTATION,
            MediaStore.MediaColumns.DISPLAY_NAME,
        )
        resolver.query(files, projection, "${MediaStore.Files.FileColumns._ID} = ?", arrayOf(id.toString()), null)?.use { c ->
            if (!c.moveToFirst()) throw ThumbnailFailure.notFound("no such asset")
            val mediaType = if (c.isNull(0)) 0 else c.getInt(0)
            val mime = if (c.isNull(1)) null else c.getString(1)
            val name = if (c.isNull(5)) null else c.getString(5)
            val kind = when (mediaType) {
                MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE -> MediaKind.IMAGE
                MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO -> MediaKind.VIDEO
                else -> ThumbnailTypes.kind(mime, name)
            }
            val w = if (c.isNull(2)) 0 else c.getInt(2)
            val h = if (c.isNull(3)) 0 else c.getInt(3)
            val orientation = if (c.isNull(4)) 0 else c.getInt(4)
            val uri = when (kind) {
                MediaKind.IMAGE -> ContentUris.withAppendedId(MediaStore.Images.Media.getContentUri("external"), id)
                MediaKind.VIDEO -> ContentUris.withAppendedId(MediaStore.Video.Media.getContentUri("external"), id)
                else -> throw ThumbnailFailure.notSupported("not a photo or video")
            }
            // Displayed size: the stored size turned by the orientation (WIDTH/HEIGHT are the raw ones).
            val size = if (w > 0 && h > 0) ThumbnailGeometry.rotated(PxSize(w, h), orientation) else null
            return Row(uri, kind, size, orientation)
        } ?: throw ThumbnailFailure.io("MediaStore query failed")
    }

    private fun mediaStoreBitmap(id: Long, box: PxSize, mode: ThumbnailModeMsg, token: ThumbnailCancelToken): Bitmap? {
        val row = mediaStoreRow(id)
        val want = ThumbnailGeometry.requestSize(row.size, box, mode)
        token.check()
        if (Build.VERSION.SDK_INT >= 29) {
            val thumb = resolver.loadThumbnail(row.uri, Size(want.width, want.height), token.signal())
            if (row.kind != MediaKind.IMAGE || !ThumbnailGeometry.tooSmall(PxSize(thumb.width, thumb.height), want, mode, row.size)) return thumb
            // MediaStore's cached thumbnail is smaller than the request (large size class): decode the original.
            thumb.recycle()
            token.check()
            return decodeSampled({ resolver.openInputStream(row.uri) ?: throw FileNotFoundException() }, want, row.orientation, token)
        }
        return when (row.kind) {
            MediaKind.IMAGE -> decodeSampled({ resolver.openInputStream(row.uri) ?: throw FileNotFoundException() }, want, row.orientation, token)
            else -> videoFrame(want, token) { it.setDataSource(app, row.uri) }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Files and content URIs

    private fun checkedFile(path: String): File {
        val file = File(path)
        if (!file.exists() || file.isDirectory) throw ThumbnailFailure.notFound("no such file")
        if (!file.canRead()) throw ThumbnailFailure.permission("file not readable")
        return file
    }

    private fun fileBitmap(path: String, box: PxSize, mode: ThumbnailModeMsg, token: ThumbnailCancelToken): Bitmap? {
        val file = checkedFile(path)
        val kind = ThumbnailTypes.kind(null, file.name)
        if (kind == MediaKind.VIDEO) return fileVideo(file, box, mode, token)
        if (kind == MediaKind.PDF) throw ThumbnailFailure.notSupported("documents use documentThumbnail")
        // An image, or an unknown extension: try it as an image first, then as a video.
        val image = fileImage(file, box, mode, token)
        if (image != null || kind == MediaKind.IMAGE) return image
        token.check()
        return fileVideo(file, box, mode, token)
    }

    private fun fileImage(file: File, box: PxSize, mode: ThumbnailModeMsg, token: ThumbnailCancelToken): Bitmap? {
        val bounds = imageBounds { file.inputStream() }
        val orientation = exifRotation { file.inputStream() }
        val source = bounds?.let { ThumbnailGeometry.rotated(it, orientation) }
        val want = ThumbnailGeometry.requestSize(source, box, mode)
        if (Build.VERSION.SDK_INT >= 29) {
            return try {
                ThumbnailUtils.createImageThumbnail(file, Size(want.width, want.height), token.signal())
            } catch (e: IOException) {
                if (bounds == null && ThumbnailTypes.kind(null, file.name) != MediaKind.IMAGE) null else throw e
            }
        }
        if (bounds == null) return null
        return decodeSampled({ file.inputStream() }, want, orientation, token)
    }

    private fun fileVideo(file: File, box: PxSize, mode: ThumbnailModeMsg, token: ThumbnailCancelToken): Bitmap? {
        val want = ThumbnailGeometry.requestSize(null, box, mode)
        if (Build.VERSION.SDK_INT >= 29) {
            return ThumbnailUtils.createVideoThumbnail(file, Size(want.width, want.height), token.signal())
        }
        return videoFrame(want, token) { r -> ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { r.setDataSource(it.fileDescriptor) } }
    }

    private fun contentBitmap(uri: Uri, box: PxSize, mode: ThumbnailModeMsg, token: ThumbnailCancelToken): Bitmap? {
        val mime = runCatching { resolver.getType(uri) }.getOrNull()
        val name = runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c -> if (c.moveToFirst() && !c.isNull(0)) c.getString(0) else null }
        }.getOrNull()
        val kind = ThumbnailTypes.kind(mime, name)
        if (kind == MediaKind.PDF) throw ThumbnailFailure.notSupported("documents use documentThumbnail")
        val open = { resolver.openInputStream(uri) ?: throw FileNotFoundException() }
        if (kind != MediaKind.VIDEO) {
            val bounds = imageBounds(open)
            if (bounds != null) {
                val orientation = exifRotation(open)
                val want = ThumbnailGeometry.requestSize(ThumbnailGeometry.rotated(bounds, orientation), box, mode)
                return decodeSampled(open, want, orientation, token)
            }
            if (kind == MediaKind.IMAGE) throw ThumbnailFailure.io("unreadable or corrupt media")
        }
        token.check()
        return videoFrame(ThumbnailGeometry.requestSize(null, box, mode), token) { it.setDataSource(app, uri) }
    }

    // ---------------------------------------------------------------------------------------------
    // Decoders

    /** The raw (unrotated) pixel size from the image header, or null when it isn't a decodable image. */
    private fun imageBounds(open: () -> InputStream): PxSize? {
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        open().use { BitmapFactory.decodeStream(it, null, o) }
        return if (o.outWidth > 0 && o.outHeight > 0) PxSize(o.outWidth, o.outHeight) else null
    }

    /** The EXIF rotation in degrees (0 when there is none or it can't be read). */
    private fun exifRotation(open: () -> InputStream): Int = try {
        open().use { ExifInterface(it).rotationDegrees }
    } catch (e: IOException) {
        0
    } catch (e: RuntimeException) {
        0
    }

    /**
     * A sampled decode of the image [open] returns, rotated by [rotation] degrees so the result is
     * at least [want] (displayed orientation) where the source allows. Null for a corrupt image.
     */
    private fun decodeSampled(open: () -> InputStream, want: PxSize, rotation: Int, token: ThumbnailCancelToken): Bitmap? {
        val raw = imageBounds(open) ?: return null
        val rawWant = ThumbnailGeometry.rotated(want, rotation)
        val opts = BitmapFactory.Options().apply {
            inSampleSize = ThumbnailGeometry.sampleSize(raw, rawWant)
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        token.check()
        val decoded = open().use { BitmapFactory.decodeStream(it, null, opts) } ?: return null
        if (rotation % 360 == 0) return decoded
        val m = Matrix().apply { postRotate(rotation.toFloat()) }
        val turned = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, m, true)
        if (turned !== decoded) decoded.recycle()
        return turned
    }

    /** A frame near the start of a video (rotation applied by the retriever), scaled toward [want]. */
    private fun videoFrame(want: PxSize, token: ThumbnailCancelToken, setSource: (MediaMetadataRetriever) -> Unit): Bitmap? {
        val r = MediaMetadataRetriever()
        try {
            setSource(r)
            token.check()
            val timeUs = 100_000L
            val frame = if (Build.VERSION.SDK_INT >= 27) {
                r.getScaledFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, want.width, want.height)
            } else {
                r.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            }
            return frame ?: r.frameAtTime
        } finally {
            runCatching { r.release() }
        }
    }

    private fun readHead(file: File): ByteArray? = try {
        file.inputStream().use { s ->
            val buf = ByteArray(1024)
            val n = s.read(buf)
            if (n <= 0) null else buf.copyOf(n)
        }
    } catch (e: IOException) {
        null
    }

    /** Page 1 of the PDF rendered on white, fitted into [box] (upscaled when the page is smaller). */
    private fun renderPdfFirstPage(file: File, box: PxSize, token: ThumbnailCancelToken): Bitmap? = PDF_LOCK.withLock {
        token.check()
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { pfd ->
            PdfRenderer(pfd).use { renderer ->
                if (renderer.pageCount < 1) return@withLock null
                renderer.openPage(0).use { page ->
                    val pw = max(1, page.width)
                    val ph = max(1, page.height)
                    val s = min(box.width.toDouble() / pw, box.height.toDouble() / ph)
                    val w = max(1, (pw * s).roundToInt())
                    val h = max(1, (ph * s).roundToInt())
                    val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                    bitmap.eraseColor(Color.WHITE)
                    token.check()
                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    bitmap
                }
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Encoding

    /** Crops / fits [image] into [box] and writes it to [outputPath] atomically. */
    private fun write(image: Bitmap, box: PxSize, mode: ThumbnailModeMsg, requested: ThumbnailFormatMsg, quality: Double, outputPath: String, token: ThumbnailCancelToken): ThumbnailOutput {
        val src = PxSize(image.width, image.height)
        val format = ThumbnailEncoding.effectiveFormat(requested)
        val size = ThumbnailGeometry.outputSize(src, box, mode)
        val crop = ThumbnailGeometry.cropRect(src, box, mode)
        val out = Bitmap.createBitmap(size.width, size.height, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(out)
            if (!ThumbnailEncoding.keepsAlpha(format)) canvas.drawColor(Color.BLACK)
            canvas.drawBitmap(
                image,
                Rect(crop.left, crop.top, crop.left + crop.width, crop.top + crop.height),
                Rect(0, 0, size.width, size.height),
                Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG),
            )
            token.check()
            val target = File(outputPath)
            val dir = target.parentFile ?: throw ThumbnailFailure.invalid("output path has no directory")
            if (!dir.isDirectory && !dir.mkdirs() && !dir.isDirectory) throw ThumbnailFailure.io("could not create the cache directory")
            val part = File(dir, ".${UUID.randomUUID()}.part")
            try {
                FileOutputStream(part).use { stream ->
                    if (!out.compress(compressFormat(format), ThumbnailEncoding.quality100(quality, format), stream)) {
                        throw ThumbnailFailure.io("could not encode")
                    }
                    stream.fd.sync()
                }
                token.check()
                if (!part.renameTo(target)) throw ThumbnailFailure.io("could not move the thumbnail into place")
            } catch (e: IOException) {
                throw ThumbnailFailure.io("could not write the thumbnail")
            } finally {
                if (part.exists()) part.delete()
            }
            return ThumbnailOutput(outputPath, size.width, size.height, format)
        } finally {
            out.recycle()
        }
    }

    @Suppress("DEPRECATION")
    private fun compressFormat(format: ThumbnailFormatMsg): Bitmap.CompressFormat = when (format) {
        ThumbnailFormatMsg.PNG -> Bitmap.CompressFormat.PNG
        ThumbnailFormatMsg.WEBP -> if (Build.VERSION.SDK_INT >= 30) Bitmap.CompressFormat.WEBP_LOSSY else Bitmap.CompressFormat.WEBP
        else -> Bitmap.CompressFormat.JPEG
    }

    private companion object {
        /** PdfRenderer instances share pdfium state on older releases: one render at a time. */
        val PDF_LOCK = java.util.concurrent.locks.ReentrantLock()
    }
}

private inline fun <T> java.util.concurrent.locks.ReentrantLock.withLock(block: () -> T): T {
    lock()
    try {
        return block()
    } finally {
        unlock()
    }
}
