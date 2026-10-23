// OWNER: HOM-04A
//
// Emulator tests of the Android thumbnailers (BUILD_PLAN HOM-04A: images, videos and PDFs on API 35
// and 29; a corrupt file yields a typed failure, not a crash). Everything is generated on the
// device (JPEG with EXIF orientation, H.264 MP4 through SeededMedia.encodeMp4, PDF through
// PdfDocument; an encrypted PDF written by hand); MediaStore rows are seeded with RELATIVE_PATH on
// API 29+ and by scanning files in the app's external files folder below 29 (the pre-29 paths, run
// on Pixel_API_28). Each test checks the written file decodes at the reported size and format, and
// that the source was not modified.

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
import java.io.ByteArrayOutputStream
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

    /** A two-page PDF (US Letter, 612×792 pt unless given) with a black square near the top-left of page 1. */
    private fun pdf(name: String, widthPt: Int = 612, heightPt: Int = 792): File {
        val f = File(dir, name)
        val doc = PdfDocument()
        for (n in 1..2) {
            val page = doc.startPage(PdfDocument.PageInfo.Builder(widthPt, heightPt, n).create())
            if (n == 1) page.canvas.drawRect(36f, 36f, 236f, 236f, Paint().apply { color = Color.BLACK })
            doc.finishPage(page)
        }
        f.outputStream().use { doc.writeTo(it) }
        doc.close()
        return f
    }

    /**
     * A one-page PDF encrypted with the standard security handler (RC4, R2) whose stored O/U
     * entries match neither an empty user password nor any password the test knows: opening it
     * needs a password, as a password-protected document from a user would.
     */
    private fun encryptedPdf(name: String): File {
        val out = ByteArrayOutputStream()
        val offsets = ArrayList<Int>()
        fun w(t: String) = out.write(t.toByteArray(Charsets.ISO_8859_1))
        val hex32 = (0 until 32).joinToString("") { "%02X".format((it * 37 + 11) and 0xFF) }
        val id = (0 until 16).joinToString("") { "%02X".format((it * 53 + 7) and 0xFF) }
        w("%PDF-1.4\n")
        val objects = listOf(
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            "<< /Filter /Standard /V 1 /R 2 /O <$hex32> /U <${hex32.reversed()}> /P -44 >>",
        )
        objects.forEachIndexed { i, body ->
            offsets.add(out.size())
            w("${i + 1} 0 obj\n$body\nendobj\n")
        }
        val xref = out.size()
        w("xref\n0 ${objects.size + 1}\n0000000000 65535 f \n")
        for (o in offsets) w("%010d 00000 n \n".format(o))
        w("trailer\n<< /Size ${objects.size + 1} /Root 1 0 R /Encrypt 4 0 R /ID [<$id> <$id>] >>\nstartxref\n$xref\n%%EOF\n")
        return File(dir, name).apply { writeBytes(out.toByteArray()) }
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
    // MediaStore below API 29 (HOM-04A (3)): seeded by writing files into fresh public
    // Pictures/Movies folders (WRITE_EXTERNAL_STORAGE, test APK only, maxSdk 28) and scanning them
    // (no RELATIVE_PATH below 29), read through the pre-29 paths: a sampled decode turned by the
    // row's ORIENTATION, and MediaMetadataRetriever on the row's URI.

    /** Scans [file] into MediaStore and returns its id (null when the scan gives no row). */
    private fun scanned(file: File): Long? {
        val latch = java.util.concurrent.CountDownLatch(1)
        var uri: android.net.Uri? = null
        android.media.MediaScannerConnection.scanFile(context, arrayOf(file.path), null) { _, u -> uri = u; latch.countDown() }
        assertTrue("scanned", latch.await(20, java.util.concurrent.TimeUnit.SECONDS))
        return uri?.let { android.content.ContentUris.parseId(it) }
    }

    /** Deletes [files] and scans them again, which drops their MediaStore rows. */
    private fun unscan(files: List<File>) {
        files.forEach { it.delete() }
        val latch = java.util.concurrent.CountDownLatch(files.size)
        android.media.MediaScannerConnection.scanFile(context, files.map { it.path }.toTypedArray(), null) { _, _ -> latch.countDown() }
        latch.await(20, java.util.concurrent.TimeUnit.SECONDS)
    }

    @Test
    fun mediaStoreBelowApi29TurnsByOrientationAndReadsVideoFrames() {
        assumeTrue("the pre-29 MediaStore paths (API 24-28)", sdk < 29)
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        (PhotoPermissions.toRequest(sdk) + android.Manifest.permission.WRITE_EXTERNAL_STORAGE)
            .forEach { automation.grantRuntimePermission(context.packageName, it) }
        val tag = UUID.randomUUID().toString().take(8)
        @Suppress("DEPRECATION")
        fun publicDir(type: String) = File(android.os.Environment.getExternalStoragePublicDirectory(type), "DanaviewTest-$tag").apply { mkdirs() }
        val pictures = publicDir(android.os.Environment.DIRECTORY_PICTURES)
        val movies = publicDir(android.os.Environment.DIRECTORY_MOVIES)
        // Stored 400×200 landscape, EXIF "rotate 90": the scanner records ORIENTATION 90.
        val photoFile = File(pictures, "pre29-$tag.jpg").also { jpeg("pre29-src.jpg", 400, 200, ExifInterface.ORIENTATION_ROTATE_90).copyTo(it) }
        val videoFile = File(movies, "pre29-$tag.mp4").also { SeededMedia.encodeMp4(it, 160, 120, 15) }
        try {
            val photo = scanned(photoFile) ?: error("photo not scanned")
            val video = scanned(videoFile) ?: error("video not scanned")
            val before = photoFile.readBytes()
            // Fit: displayed portrait 200×400 into 128 -> 64×128, red (stored left) on top.
            val fit = media("ms:$photo", 128, 128, ThumbnailModeMsg.FIT, ThumbnailFormatMsg.JPEG)
            assertEquals(64 to 128, fit.widthPx to fit.heightPx)
            val b = decoded(fit)
            assertTrue(isRedish(b.getPixel(32, 8)))
            assertTrue(isBlueish(b.getPixel(32, 120)))
            // Fill: the box, centre-cropped; WebP as the cache asks.
            val fill = media("ms:$photo", 96, 96)
            assertEquals(ThumbnailFormatMsg.WEBP, fill.format)
            assertEquals(96 to 96, fill.widthPx to fill.heightPx)
            decoded(fill)
            // Large class: never upscaled past the displayed 200×400.
            val large = media("ms:$photo", 1280, 1280, ThumbnailModeMsg.FIT)
            assertEquals(200 to 400, large.widthPx to large.heightPx)
            decoded(large)
            // Video: a frame through MediaMetadataRetriever on the MediaStore URI, 4:3 kept in fit.
            val v = media("ms:$video", 192, 192)
            assertEquals(192 to 192, v.widthPx to v.heightPx)
            decoded(v)
            val vf = media("ms:$video", 1280, 1280, ThumbnailModeMsg.FIT)
            assertTrue(abs(vf.widthPx.toDouble() / vf.heightPx - 4.0 / 3.0) < 0.05)
            decoded(vf)
            // Sources are only read.
            assertArrayEquals(before, photoFile.readBytes())
            // An id that is gone.
            assertEquals(LibraryErrorCode.notFound, failure { media("ms:999999999", 64, 64) }.code)
        } finally {
            unscan(listOf(photoFile, videoFile))
            pictures.delete()
            movies.delete()
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Documents

    @Test
    fun pdfFirstPageFitsTheBoxOnWhite() {
        val src = pdf("doc.pdf")
        val before = src.readBytes()
        val o = thumbnailer.document(src.path, PxSize(384, 384), 1.0, ThumbnailFormatMsg.WEBP, 0.9, out.path, ThumbnailCancelToken())
        assertNotNull(o)
        // 612×792 pt at scale 1 fitted into 384: 297×384.
        assertEquals(297 to 384, o!!.widthPx to o.heightPx)
        val b = decoded(o)
        val ink = b.getPixel(40, 40)
        assertTrue("black square drawn", Color.red(ink) < 60 && Color.green(ink) < 60)
        val paper = b.getPixel(250, 350)
        assertTrue("white paper", Color.red(paper) > 230 && Color.green(paper) > 230 && Color.blue(paper) > 230)
        assertArrayEquals(before, src.readBytes())
        // A PDF without the extension is recognised by its header.
        val renamed = File(dir, "doc-no-ext").apply { writeBytes(before) }
        assertNotNull(thumbnailer.document(renamed.path, PxSize(96, 96), 1.0, ThumbnailFormatMsg.PNG, 0.9, out.path, ThumbnailCancelToken()))
    }

    @Test
    fun pdfHonoursScaleAndFitNeverUpscaling() {
        fun doc(src: File, box: Int, scale: Double): Pair<Int, Int> {
            val o = thumbnailer.document(src.path, PxSize(box, box), scale, ThumbnailFormatMsg.PNG, 0.9, out.path, ThumbnailCancelToken())!!
            decoded(o)
            return o.widthPx to o.heightPx
        }
        val letter = pdf("letter.pdf")
        // A large box: the page's natural size at the scale, not blown up to the box.
        assertEquals(612 to 792, doc(letter, 1600, 1.0))
        assertEquals(1224 to 1584, doc(letter, 1600, 2.0))
        // Larger than the box at scale 3: fitted into it.
        assertEquals(1236 to 1600, doc(letter, 1600, 3.0))
        // A small page (100×50 pt).
        val small = pdf("small.pdf", 100, 50)
        assertEquals(100 to 50, doc(small, 384, 1.0))
        assertEquals(300 to 150, doc(small, 384, 3.0))
        assertEquals(384 to 192, doc(small, 384, 10.0))
        // The ink scales with the page: the square from 36 pt starts at 72 px at scale 2.
        val o = thumbnailer.document(letter.path, PxSize(1600, 1600), 2.0, ThumbnailFormatMsg.PNG, 0.9, out.path, ThumbnailCancelToken())!!
        val b = decoded(o)
        assertTrue("ink at scale 2", Color.red(b.getPixel(80, 80)) < 60)
        assertTrue("paper before the square", Color.red(b.getPixel(60, 60)) > 230)
        // A bad scale is an invalid argument; nothing written.
        out.delete()
        for (bad in listOf(0.0, -1.0, Double.NaN, Double.POSITIVE_INFINITY)) {
            assertEquals(LibraryErrorCode.invalidArgument, failure {
                thumbnailer.document(letter.path, PxSize(96, 96), bad, ThumbnailFormatMsg.PNG, 0.9, out.path, ThumbnailCancelToken())
            }.code)
        }
        assertFalse(out.exists())
    }

    @Test
    fun encryptedPdfHasNoThumbnail() {
        val src = encryptedPdf("locked.pdf")
        val before = src.readBytes()
        assertNull(thumbnailer.document(src.path, PxSize(384, 384), 2.0, ThumbnailFormatMsg.WEBP, 0.8, out.path, ThumbnailCancelToken()))
        assertFalse(out.exists())
        assertTrue(dir.listFiles()!!.none { it.name.endsWith(".part") })
        assertArrayEquals(before, src.readBytes())
        // The same file without the extension (header sniff) too.
        val renamed = File(dir, "locked-no-ext").apply { writeBytes(before) }
        assertNull(thumbnailer.document(renamed.path, PxSize(96, 96), 1.0, ThumbnailFormatMsg.WEBP, 0.8, out.path, ThumbnailCancelToken()))
    }

    @Test
    fun nonPdfDocumentHasNoThumbnail() {
        val txt = File(dir, "notes.txt").apply { writeText("hello") }
        assertNull(thumbnailer.document(txt.path, PxSize(96, 96), 1.0, ThumbnailFormatMsg.WEBP, 0.8, out.path, ThumbnailCancelToken()))
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
            thumbnailer.document(junk("broken.pdf", "%PDF-1.4\n".toByteArray()).path, PxSize(96, 96), 1.0, ThumbnailFormatMsg.WEBP, 0.8, out.path, ThumbnailCancelToken())
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
            thumbnailer.document(File(dir, "gone.pdf").path, PxSize(96, 96), 1.0, ThumbnailFormatMsg.WEBP, 0.8, out.path, ThumbnailCancelToken())
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
