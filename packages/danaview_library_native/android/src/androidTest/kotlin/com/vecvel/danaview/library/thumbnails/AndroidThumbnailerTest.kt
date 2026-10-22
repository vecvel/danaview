// OWNER: HOM-04A
//
// Emulator tests of the Android thumbnailers (BUILD_PLAN HOM-04A: images, videos and PDFs on API 35
// and 29; a corrupt file yields a typed failure, not a crash). Everything is generated on the
// device (JPEG with EXIF orientation, H.264 MP4 through SeededMedia.encodeMp4, PDF through
// PdfDocument); MediaStore rows are seeded on API 29+ only (RELATIVE_PATH). Each test checks the
// written file decodes at the reported size and format, and that the source was not modified.

package com.vecvel.danaview.library.thumbnails

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.Paint
import android.graphics.pdf.PdfDocument
import android.os.Build
import android.provider.MediaStore
import androidx.exifinterface.media.ExifInterface
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.library.glue.LibraryErrorCode
import com.vecvel.danaview.library.photolibrary.PhotoPermissions
import com.vecvel.danaview.library.photolibrary.SeededMedia
import com.vecvel.danaview.library.pigeon.ThumbnailFormatMsg
import com.vecvel.danaview.library.pigeon.ThumbnailModeMsg
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class AndroidThumbnailerTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val sdk = Build.VERSION.SDK_INT
    private val thumbnailer = AndroidThumbnailer(context)
    private lateinit var dir: File
    private lateinit var out: File
    private var seed: SeededMedia? = null

    @Before
    fun setUp() {
        dir = File(context.cacheDir, "thumb-test-${UUID.randomUUID()}").apply { mkdirs() }
        out = File(dir, "out")
    }

    @After
    fun tearDown() {
        seed?.deleteAll()
        dir.deleteRecursively()
    }

    // ---------------------------------------------------------------------------------------------
    // Fixtures

    /** An [w]×[h] JPEG, left half red and right half blue, with EXIF [orientation]. */
    private fun jpeg(name: String, w: Int, h: Int, orientation: Int = ExifInterface.ORIENTATION_NORMAL): File {
        val f = File(dir, name)
        val b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = android.graphics.Canvas(b)
        c.drawColor(Color.RED)
        c.drawRect(w / 2f, 0f, w.toFloat(), h.toFloat(), Paint().apply { color = Color.BLUE })
        f.outputStream().use { b.compress(Bitmap.CompressFormat.JPEG, 95, it) }
        b.recycle()
        if (orientation != ExifInterface.ORIENTATION_NORMAL) {
            ExifInterface(f).apply { setAttribute(ExifInterface.TAG_ORIENTATION, orientation.toString()); saveAttributes() }
        }
        return f
    }

    private fun mp4(name: String): File = File(dir, name).also { SeededMedia.encodeMp4(it, 160, 120, 15) }

    /** A two-page PDF (US Letter, 612×792 pt) with a black square near the top-left of page 1. */
    private fun pdf(name: String): File {
        val f = File(dir, name)
        val doc = PdfDocument()
        for (n in 1..2) {
            val page = doc.startPage(PdfDocument.PageInfo.Builder(612, 792, n).create())
            if (n == 1) page.canvas.drawRect(36f, 36f, 236f, 236f, Paint().apply { color = Color.BLACK })
            doc.finishPage(page)
        }
        f.outputStream().use { doc.writeTo(it) }
        doc.close()
        return f
    }

    private fun junk(name: String, header: ByteArray = ByteArray(0)): File =
        File(dir, name).apply { writeBytes(header + ByteArray(4096) { (it * 31 + 7).toByte() }) }

    private fun bytes(vararg b: Int) = ByteArray(b.size) { b[it].toByte() }

    private fun media(source: String, w: Int, h: Int, mode: ThumbnailModeMsg = ThumbnailModeMsg.FILL, format: ThumbnailFormatMsg = ThumbnailFormatMsg.WEBP, token: ThumbnailCancelToken = ThumbnailCancelToken()) =
        thumbnailer.media(ThumbnailSource.parse(source), PxSize(w, h), mode, format, 0.8, out.path, token)

    private fun failure(block: () -> Unit): ThumbnailFailure {
        try {
            block()
        } catch (f: ThumbnailFailure) {
            return f
        }
        fail("expected a ThumbnailFailure")
        throw AssertionError()
    }

    /** Decodes [o]'s file and checks it matches the reported size; returns the bitmap. */
    private fun decoded(o: ThumbnailOutput): Bitmap {
        val f = File(o.path)
        assertTrue("thumbnail written", f.isFile && f.length() > 0)
        val b = BitmapFactory.decodeFile(f.path) ?: error("thumbnail does not decode")
        assertEquals(o.widthPx, b.width)
        assertEquals(o.heightPx, b.height)
        val head = f.readBytes().copyOf(12)
        when (o.format) {
            ThumbnailFormatMsg.WEBP -> assertEquals("RIFF", String(head, 0, 4)).also { assertEquals("WEBP", String(head, 8, 4)) }
            ThumbnailFormatMsg.JPEG -> assertEquals(0xFF.toByte(), head[0]).also { assertEquals(0xD8.toByte(), head[1]) }
            ThumbnailFormatMsg.PNG -> assertEquals("PNG", String(head, 1, 3))
            else -> fail("unexpected format")
        }
        assertTrue("no part files left", dir.listFiles()!!.none { it.name.endsWith(".part") })
        return b
    }

    private fun isRedish(c: Int) = Color.red(c) > 180 && Color.blue(c) < 90
    private fun isBlueish(c: Int) = Color.blue(c) > 180 && Color.red(c) < 90

    private fun seeded(): SeededMedia {
        assumeTrue("MediaStore seeding needs RELATIVE_PATH (API 29+)", sdk >= 29)
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        PhotoPermissions.toRequest(sdk).filter { it != PhotoPermissions.READ_MEDIA_VISUAL_USER_SELECTED }
            .forEach { automation.grantRuntimePermission(context.packageName, it) }
        return SeededMedia(context).also { seed = it }
    }

    // ---------------------------------------------------------------------------------------------
    // Files

    @Test
    fun imageFileFillIsWebpAtTheBox() {
        val src = jpeg("photo.jpg", 400, 300)
        val before = src.readBytes()
        val stamp = src.lastModified()
        val o = media(src.path, 192, 192)
        assertEquals(ThumbnailFormatMsg.WEBP, o.format)
        assertEquals(192 to 192, o.widthPx to o.heightPx)
        val b = decoded(o)
        // Centre crop of a red|blue image: red on the left edge, blue on the right edge.
        assertTrue(isRedish(b.getPixel(4, 96)))
        assertTrue(isBlueish(b.getPixel(187, 96)))
        assertArrayEquals("source unchanged", before, src.readBytes())
        assertEquals(stamp, src.lastModified())
    }

    @Test
    fun imageFileHonoursExifOrientationInFitMode() {
        // Stored 400×200 landscape, EXIF "rotate 90": displayed as 200×400 portrait.
        val src = jpeg("turned.jpg", 400, 200, ExifInterface.ORIENTATION_ROTATE_90)
        val o = media(src.path, 128, 128, ThumbnailModeMsg.FIT, ThumbnailFormatMsg.JPEG)
        assertEquals(ThumbnailFormatMsg.JPEG, o.format)
        assertEquals(64 to 128, o.widthPx to o.heightPx)
        val b = decoded(o)
        // Rotated 90° clockwise: the stored left (red) half is now on top.
        assertTrue(isRedish(b.getPixel(32, 8)))
        assertTrue(isBlueish(b.getPixel(32, 120)))
    }

    @Test
    fun fitNeverUpscalesAndHeicIsWrittenAsJpeg() {
        val src = jpeg("small.jpg", 64, 48)
        val o = media("file://" + src.path, 1280, 1280, ThumbnailModeMsg.FIT, ThumbnailFormatMsg.HEIC)
        assertEquals(ThumbnailFormatMsg.JPEG, o.format)
        assertEquals(64 to 48, o.widthPx to o.heightPx)
        decoded(o)
    }

    @Test
    fun pngKeepsAlpha() {
        val src = File(dir, "alpha.png")
        Bitmap.createBitmap(50, 50, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.TRANSPARENT) }
            .also { b -> src.outputStream().use { b.compress(Bitmap.CompressFormat.PNG, 100, it) } }
        val o = media(src.path, 50, 50, ThumbnailModeMsg.FIT, ThumbnailFormatMsg.PNG)
        assertEquals(0, Color.alpha(decoded(o).getPixel(25, 25)))
    }

    @Test
    fun videoFileGivesAFrame() {
        val src = mp4("clip.mp4")
        val before = src.readBytes()
        val o = media(src.path, 192, 192)
        assertEquals(192 to 192, o.widthPx to o.heightPx)
        decoded(o)
        assertArrayEquals(before, src.readBytes())
        // Fit keeps the 4:3 aspect.
        val fit = media(src.path, 1280, 1280, ThumbnailModeMsg.FIT)
        assertTrue(abs(fit.widthPx.toDouble() / fit.heightPx - 4.0 / 3.0) < 0.05)
        decoded(fit)
    }

    @Test
    fun videoWithoutAKnownExtensionIsStillFound() {
        val src = mp4("clip.bin")
        decoded(media(src.path, 96, 96))
    }

    // ---------------------------------------------------------------------------------------------
    // MediaStore and content URIs (API 29+)

    @Test
    fun mediaStorePhotoAndVideo() {
        val s = seeded()
        val photo = s.addPhoto("thumb-photo.jpg", "2026:10:01 10:00:00")
        val video = s.addVideo("thumb-video.mp4")
        val p = media("ms:$photo", 192, 192)
        assertEquals(ThumbnailFormatMsg.WEBP, p.format)
        decoded(p)
        val v = media("ms:$video", 384, 384)
        assertEquals(384 to 384, v.widthPx to v.heightPx)
        decoded(v)
        // Large class: never upscaled past the 64×48 original.
        val l = media("ms:$photo", 1280, 1280, ThumbnailModeMsg.FIT)
        assertEquals(64 to 48, l.widthPx to l.heightPx)
    }

    @Test
    fun contentUriImage() {
        val s = seeded()
        val photo = s.addPhoto("thumb-content.jpg", "2026:10:01 10:00:00", Color.GREEN)
        val uri = android.content.ContentUris.withAppendedId(MediaStore.Images.Media.getContentUri("external"), photo)
        val b = decoded(media(uri.toString(), 32, 32, ThumbnailModeMsg.FILL, ThumbnailFormatMsg.JPEG))
        val c = b.getPixel(16, 16)
        assertTrue(Color.green(c) > 180 && Color.red(c) < 90)
    }

    @Test
    fun unknownMediaStoreIdIsNotFound() {
        seeded()
        assertEquals(LibraryErrorCode.notFound, failure { media("ms:999999999", 64, 64) }.code)
    }

    // ---------------------------------------------------------------------------------------------
    // Documents

    @Test
    fun pdfFirstPageFitsTheBoxOnWhite() {
        val src = pdf("doc.pdf")
        val before = src.readBytes()
        val o = thumbnailer.document(src.path, PxSize(384, 384), ThumbnailFormatMsg.WEBP, 0.9, out.path, ThumbnailCancelToken())
        assertNotNull(o)
        // 612×792 pt fitted into 384: 297×384 (upscaling is allowed for vector pages too).
        assertEquals(297 to 384, o!!.widthPx to o.heightPx)
        val b = decoded(o)
        val ink = b.getPixel(40, 40)
        assertTrue("black square drawn", Color.red(ink) < 60 && Color.green(ink) < 60)
        val paper = b.getPixel(250, 350)
        assertTrue("white paper", Color.red(paper) > 230 && Color.green(paper) > 230 && Color.blue(paper) > 230)
        assertArrayEquals(before, src.readBytes())
        // A PDF without the extension is recognised by its header.
        val renamed = File(dir, "doc-no-ext").apply { writeBytes(before) }
        assertNotNull(thumbnailer.document(renamed.path, PxSize(96, 96), ThumbnailFormatMsg.PNG, 0.9, out.path, ThumbnailCancelToken()))
    }

    @Test
    fun nonPdfDocumentHasNoThumbnail() {
        val txt = File(dir, "notes.txt").apply { writeText("hello") }
        assertNull(thumbnailer.document(txt.path, PxSize(96, 96), ThumbnailFormatMsg.WEBP, 0.8, out.path, ThumbnailCancelToken()))
        assertFalse(out.exists())
    }

    // ---------------------------------------------------------------------------------------------
    // Failures: typed, never a crash

    @Test
    fun corruptFilesAreTypedFailures() {
        assertEquals(LibraryErrorCode.ioError, failure { media(junk("broken.jpg", bytes(0xFF, 0xD8, 0xFF, 0xE0)).path, 96, 96) }.code)
        assertEquals(LibraryErrorCode.ioError, failure { media(junk("broken.mp4", bytes(0, 0, 0, 0x18) + "ftypmp42".toByteArray()).path, 96, 96) }.code)
        assertEquals(LibraryErrorCode.ioError, failure { media(junk("mystery.bin").path, 96, 96) }.code)
        assertEquals(LibraryErrorCode.ioError, failure {
            thumbnailer.document(junk("broken.pdf", "%PDF-1.4\n".toByteArray()).path, PxSize(96, 96), ThumbnailFormatMsg.WEBP, 0.8, out.path, ThumbnailCancelToken())
        }.code)
        assertEquals(LibraryErrorCode.ioError, failure { media(File(dir, "empty.jpg").apply { writeBytes(ByteArray(0)) }.path, 96, 96) }.code)
        assertFalse(out.exists())
        assertTrue(dir.listFiles()!!.none { it.name.endsWith(".part") })
    }

    @Test
    fun missingSourcesAndBadSourcesAreTyped() {
        assertEquals(LibraryErrorCode.notFound, failure { media(File(dir, "gone.jpg").path, 96, 96) }.code)
        assertEquals(LibraryErrorCode.notFound, failure { media(dir.path, 96, 96) }.code)
        assertEquals(LibraryErrorCode.notFound, failure {
            thumbnailer.document(File(dir, "gone.pdf").path, PxSize(96, 96), ThumbnailFormatMsg.WEBP, 0.8, out.path, ThumbnailCancelToken())
        }.code)
        assertEquals(LibraryErrorCode.notSupportedOnDevice, failure { media(pdf("x.pdf").path, 96, 96) }.code)
        assertEquals(LibraryErrorCode.notSupportedOnDevice, failure { media("ph:AAAA/L0/001", 96, 96) }.code)
    }

    @Test
    fun cancelledRequestsWriteNothing() {
        val src = jpeg("c.jpg", 400, 300)
        val token = ThumbnailCancelToken().apply { cancel() }
        assertEquals(LibraryErrorCode.cancelled, failure { media(src.path, 96, 96, token = token) }.code)
        assertFalse(out.exists())
    }

    @Test
    fun outputReplacesAnOlderThumbnailAndCreatesDirectories() {
        val src = jpeg("r.jpg", 400, 300)
        val nested = File(dir, "a/b/c.webp")
        out = nested
        decoded(media(src.path, 64, 64))
        val first = nested.length()
        decoded(media(src.path, 128, 128))
        assertTrue(nested.length() != first)
        assertTrue(nested.parentFile!!.listFiles()!!.none { it.name.endsWith(".part") })
    }
}
