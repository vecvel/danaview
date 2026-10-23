// OWNER: HOM-20A
//
// Emulator tests of the Android import pickers (BUILD_PLAN HOM-20A: API 35 and 29, importing an
// image, a PDF and a video; the source URI is never opened for writing).
//
// - Read-only check (every API): RecordingProvider serves a JPEG, a PDF and an MP4 and records
//   each open mode; describe + copy of each yields the exact bytes, and every recorded mode is "r".
// - Real pickers (API 29+, media seeded through MediaStore): the SAF document picker in
//   DocumentsUI multi-selects an image, a PDF and a video from Downloads; the photo picker (the
//   system Photo Picker on API 35; on the API 29 emulator, which has neither the platform picker
//   nor the Play services back-port, androidx's ACTION_OPEN_DOCUMENT fallback in DocumentsUI)
//   picks a photo and a video. Every picked item is described and copied, and must equal the
//   seeded bytes, which are unchanged afterwards. A cancelled picker answers an empty list.
// - Names (OBS-S2A-1): media-id names ("1000000777.jpg") become IMG_yyyyMMdd_HHmmss.<ext> from
//   DATE_TAKEN, else DATE_ADDED, real names stay, clashes inside one pick are "Name (2).ext"; the
//   system Photo Picker's own items come back with such names.
// - Clean-up: the system Photo Picker path seeds into the fixed folders Pictures/DanaviewTest and
//   Movies/DanaviewTest; deleting the rows leaves the folders behind (on disk and as MediaStore
//   folder rows the test APK cannot see), so every test removes both through the shell user before
//   it starts (an aborted earlier run's) and after it ends.

package com.vecvel.danaview.library.pickers

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Paint
import android.graphics.pdf.PdfDocument
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.library.glue.LibraryErrorCode
import com.vecvel.danaview.library.photolibrary.SeededMedia
import com.vecvel.danaview.library.pigeon.PickedSourceMsg
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class AndroidPickersTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val resolver get() = context.contentResolver
    private val pickers = AndroidPickers(context)
    private lateinit var dir: File
    private val inserted = ArrayList<Uri>()
    private var launcher: FragmentLauncher? = null
    private val stamp = UUID.randomUUID().toString().take(8)

    @Before
    fun setUp() {
        dir = File(context.cacheDir, "picker-test-$stamp").apply { mkdirs() }
        RecordingProvider.modes.clear()
        removeSeedFolders()
    }

    @After
    fun tearDown() {
        launcher?.let {
            SystemUi.device.pressBack()
            it.finish()
        }
        inserted.forEach { runCatching { resolver.delete(it, null, null) } }
        removeSeedFolders()
        dir.deleteRecursively()
        RecordingProvider.dir(context).deleteRecursively()
    }

    /** Removes Pictures/DanaviewTest and Movies/DanaviewTest (disk + MediaStore rows); API 29+ only seeds there. */
    @Suppress("DEPRECATION")
    private fun removeSeedFolders() {
        if (Build.VERSION.SDK_INT < 29) return
        val root = Environment.getExternalStorageDirectory()
        for (folder in SEED_FOLDERS) SeededMedia.removeShared(File(root, folder).absolutePath)
    }

    private companion object {
        /** Fixed-name folders the system Photo Picker path seeds into. */
        val SEED_FOLDERS = listOf("${Environment.DIRECTORY_PICTURES}/DanaviewTest", "${Environment.DIRECTORY_MOVIES}/DanaviewTest")
    }

    // ---------------------------------------------------------------------------------------------
    // Fixtures

    private fun jpegBytes(color: Int): ByteArray {
        val b = Bitmap.createBitmap(96, 64, Bitmap.Config.ARGB_8888).apply { eraseColor(color) }
        return ByteArrayOutputStream().also { b.compress(Bitmap.CompressFormat.JPEG, 90, it); b.recycle() }.toByteArray()
    }

    private fun pdfBytes(): ByteArray {
        val doc = PdfDocument()
        val page = doc.startPage(PdfDocument.PageInfo.Builder(300, 400, 1).create())
        page.canvas.drawRect(20f, 20f, 120f, 120f, Paint().apply { color = Color.BLACK })
        doc.finishPage(page)
        return ByteArrayOutputStream().also { doc.writeTo(it); doc.close() }.toByteArray()
    }

    private fun mp4Bytes(): ByteArray {
        val tmp = File(dir, "enc-$stamp.mp4")
        SeededMedia.encodeMp4(tmp, 160, 120, 15)
        return tmp.readBytes().also { tmp.delete() }
    }

    private fun insert(collection: Uri, name: String, mime: String, relativeDir: String, bytes: ByteArray): Uri {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativeDir)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)!!
        inserted += uri
        resolver.openOutputStream(uri)!!.use { it.write(bytes) }
        resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        return uri
    }

    private fun readAll(uri: Uri): ByteArray = resolver.openInputStream(uri)!!.use { it.readBytes() }

    /** Starts [pick] on the main thread with a fresh relay; returns a latch-backed result. */
    private fun startPick(pick: (ResultLauncher, (Result<List<Uri>>) -> Unit) -> Unit): () -> List<Uri> {
        val relay = FragmentLauncher.launch().also { launcher = it }
        val latch = CountDownLatch(1)
        var result: Result<List<Uri>>? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            pick(relay) { r ->
                result = r
                latch.countDown()
            }
        }
        return {
            check(latch.await(30, TimeUnit.SECONDS)) { "picker did not answer:\n" + SystemUi.dump() }
            result!!.getOrThrow()
        }
    }

    /** Copies [uri] into a fresh part file; returns its bytes. */
    private fun copied(uri: Uri, progress: MutableList<Long> = ArrayList()): ByteArray {
        val dest = File(dir, "import-${UUID.randomUUID()}.part")
        val (n, total) = pickers.copy(uri.toString(), dest.path, 0, { false }) { done, _ -> progress += done }
        assertEquals(dest.length(), n)
        assertEquals(n, total)
        assertEquals(n, progress.last())
        return dest.readBytes()
    }

    private fun failure(block: () -> Unit): PickerFailure {
        try {
            block()
        } catch (f: PickerFailure) {
            return f
        }
        fail("expected a PickerFailure")
        throw AssertionError()
    }

    // ---------------------------------------------------------------------------------------------
    // Read-only copies (every API)

    @Test
    fun copiesFromAProviderAreExactAndReadOnly() {
        val files = mapOf("photo-$stamp.jpg" to jpegBytes(Color.RED), "doc-$stamp.pdf" to pdfBytes(), "clip-$stamp.mp4" to mp4Bytes())
        for ((name, bytes) in files) File(RecordingProvider.dir(context), name).writeBytes(bytes)
        val mimes = mapOf("jpg" to "image/jpeg", "pdf" to "application/pdf", "mp4" to "video/mp4")
        for ((name, bytes) in files) {
            val uri = RecordingProvider.uri(context, name)
            val item = pickers.describe(uri, PickedSourceMsg.FILES)
            assertEquals(name, item.displayName)
            assertEquals(bytes.size.toLong(), item.sizeBytes)
            assertEquals(mimes[name.substringAfterLast('.')], item.mimeType)
            assertTrue(item.needsCopy)
            assertNull(item.path)
            assertEquals(uri.toString(), item.uri)
            assertArrayEquals(name, bytes, copied(uri))
            assertArrayEquals("source unchanged", bytes, File(RecordingProvider.dir(context), name).readBytes())
        }
        assertTrue("sources were opened", RecordingProvider.modes.isNotEmpty())
        assertEquals("every open was read-only", setOf("r"), RecordingProvider.modes.toSet())
    }

    @Test
    fun mediaIdNamesBecomeCaptureDateNamesAndClashesAreNumbered() {
        val takenMs = 1_729_501_500_000L // 2024-10-21 09:05:00 UTC
        val addedS = 1_700_000_000L
        val files = listOf("1000000777.jpg", "1000000778.jpg", "1000000779.mp4", "Holiday.jpg", "1000000780.jpg")
        for (name in files) File(RecordingProvider.dir(context), name).writeBytes(jpegBytes(Color.RED))
        RecordingProvider.dates["1000000777.jpg"] = takenMs to addedS
        RecordingProvider.dates["1000000778.jpg"] = takenMs to null // the same second: a clash
        RecordingProvider.dates["1000000779.mp4"] = null to addedS // no DATE_TAKEN: DATE_ADDED
        RecordingProvider.dates["Holiday.jpg"] = takenMs to addedS // a real name stays
        // 1000000780.jpg: no dates at all, the reported name stays.
        try {
            val stampOf = { ms: Long -> java.text.SimpleDateFormat("yyyyMMdd_HHmmss", java.util.Locale.US).format(java.util.Date(ms)) }
            val photos = pickers.describeAll(files.map { RecordingProvider.uri(context, it) }, PickedSourceMsg.PHOTO_LIBRARY)
            assertEquals(
                listOf(
                    "IMG_${stampOf(takenMs)}.jpg",
                    "IMG_${stampOf(takenMs)} (2).jpg",
                    "IMG_${stampOf(addedS * 1000)}.mp4",
                    "Holiday.jpg",
                    "1000000780.jpg",
                ),
                photos.map { it.displayName },
            )
            // A files pick keeps a digits-only name that is not the URI's id.
            File(RecordingProvider.dir(context), "2024.jpg").writeBytes(jpegBytes(Color.BLUE))
            RecordingProvider.dates["2024.jpg"] = takenMs to addedS
            val doc = pickers.describeAll(listOf(RecordingProvider.uri(context, "2024.jpg"), RecordingProvider.uri(context, "Holiday.jpg")), PickedSourceMsg.FILES)
            assertEquals(listOf("2024.jpg", "Holiday.jpg"), doc.map { it.displayName })
        } finally {
            RecordingProvider.dates.clear()
        }
    }

    @Test
    fun resumeAfterAnInterruptedCopy() {
        val bytes = ByteArray(9 shl 20) { ((it * 31 + (it shr 8) * 7 + 5) and 0xff).toByte() }
        val name = "big-$stamp.mp4"
        File(RecordingProvider.dir(context), name).writeBytes(bytes)
        val uri = RecordingProvider.uri(context, name)
        val dest = File(dir, "resume.part")
        // A cancelled run stops with `cancelled`.
        val f = failure { pickers.copy(uri.toString(), dest.path, 0, { true }) { _, _ -> } }
        assertEquals(LibraryErrorCode.cancelled, f.code)
        // An interrupted run left a 3 MB checkpoint plus unsynced junk after it.
        val checkpoint = 3L shl 20
        dest.writeBytes(bytes.copyOf(checkpoint.toInt()) + ByteArray(4096) { 0x7f })
        // The resume truncates to the checkpoint and appends the rest.
        val (n, total) = pickers.copy(uri.toString(), dest.path, checkpoint, { false }) { _, _ -> }
        assertEquals(bytes.size.toLong() to bytes.size.toLong(), n to total)
        assertArrayEquals(bytes, dest.readBytes())
        assertEquals(setOf("r"), RecordingProvider.modes.toSet())
    }

    @Test
    fun badSourcesAreTyped() {
        val dest = File(dir, "x.part").path
        assertEquals(LibraryErrorCode.notFound, failure { pickers.copy(RecordingProvider.uri(context, "missing.jpg").toString(), dest, 0, { false }) { _, _ -> } }.code)
        assertEquals(LibraryErrorCode.notFound, failure { pickers.copy("content://no.such.authority.$stamp/x", dest, 0, { false }) { _, _ -> } }.code)
        assertEquals(LibraryErrorCode.notFound, failure { pickers.copy(File(dir, "gone").path, dest, 0, { false }) { _, _ -> } }.code)
        assertEquals(LibraryErrorCode.invalidArgument, failure { pickers.copy("https://example.com/x", dest, 0, { false }) { _, _ -> } }.code)
        assertEquals(LibraryErrorCode.invalidArgument, failure { pickers.copy(File(dir, "gone").path, "relative.part", 0, { false }) { _, _ -> } }.code)
        // A plain file path source works too (incoming files, HOM-21A).
        val src = File(dir, "plain.pdf").apply { writeBytes(pdfBytes()) }
        assertArrayEquals(src.readBytes(), copied(Uri.fromFile(src)))
    }

    @Test
    fun intentsAreReadOnlyImports() {
        val doc = pickers.documentIntent(true, listOf("image/*", "application/pdf"))
        assertEquals(android.content.Intent.ACTION_OPEN_DOCUMENT, doc.action)
        assertTrue(doc.hasCategory(android.content.Intent.CATEGORY_OPENABLE))
        assertEquals("*/*", doc.type)
        assertArrayEquals(arrayOf("image/*", "application/pdf"), doc.getStringArrayExtra(android.content.Intent.EXTRA_MIME_TYPES))
        assertTrue(doc.getBooleanExtra(android.content.Intent.EXTRA_ALLOW_MULTIPLE, false))
        // Neither picker asks for write or persistable grants.
        val photo = pickers.photoIntent(VisualKind.IMAGE_AND_VIDEO, 5)
        for (i in listOf(doc, photo)) {
            assertEquals(0, i.flags and android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            assertEquals(0, i.flags and android.content.Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        if (pickers.systemPhotoPickerAvailable()) assertEquals(MediaStore.ACTION_PICK_IMAGES, photo.action)
    }

    // ---------------------------------------------------------------------------------------------
    // The real pickers (API 29+: seeding uses RELATIVE_PATH)

    @Test
    fun documentPickerImportsAnImageAPdfAndAVideo() {
        assumeTrue("seeding Downloads needs API 29+", Build.VERSION.SDK_INT >= 29)
        val downloads = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val seeded = linkedMapOf(
            "dv_imp_$stamp.jpg" to jpegBytes(Color.BLUE),
            "dv_imp_$stamp.pdf" to pdfBytes(),
            "dv_imp_$stamp.mp4" to mp4Bytes(),
        )
        val mimes = mapOf("jpg" to "image/jpeg", "pdf" to "application/pdf", "mp4" to "video/mp4")
        val rows = seeded.map { (name, bytes) -> insert(downloads, name, mimes.getValue(name.substringAfterLast('.')), "Download/", bytes) }
        Thread.sleep(800)
        val result = startPick { l, done -> pickers.pickDocuments(l, true, emptyList(), done) }
        SystemUi.selectSeveralInDocumentsUi(seeded.keys.toList())
        val uris = result()
        assertEquals(3, uris.size)
        val byName = HashMap<String, ByteArray>()
        for (uri in uris) {
            val item = pickers.describe(uri, PickedSourceMsg.FILES)
            assertTrue(item.uri.startsWith("content://"))
            assertTrue(item.needsCopy)
            assertEquals(PickedSourceMsg.FILES, item.source)
            assertEquals(seeded.getValue(item.displayName).size.toLong(), item.sizeBytes)
            assertEquals(mimes[item.displayName.substringAfterLast('.')], item.mimeType)
            assertTrue("modification time reported", (item.modifiedTimeMs ?: 0) > 0)
            byName[item.displayName] = copied(uri)
        }
        for ((name, bytes) in seeded) assertArrayEquals(name, bytes, byName.getValue(name))
        rows.zip(seeded.values).forEach { (row, bytes) -> assertArrayEquals("source unchanged", bytes, readAll(row)) }
    }

    @Test
    fun photoPickerImportsAPhotoAndAVideo() {
        assumeTrue("seeding MediaStore needs API 29+", Build.VERSION.SDK_INT >= 29)
        val system = pickers.photoPickerAvailable()
        val photo = jpegBytes(Color.GREEN)
        val names = listOf("dv_ph_$stamp.jpg", "dv_ph_$stamp.mp4")
        val rows: List<Uri>
        val video: ByteArray
        if (system) {
            // The Photo Picker lists the newest first: the test's items get the newest dates.
            val newestMs = newestGalleryDateMs() + 60_000
            video = withMp4CreationTime(mp4Bytes(), newestMs / 1000)
            val image = insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, names[0], "image/jpeg", "${SEED_FOLDERS[0]}/", photo)
            val clip = insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, names[1], "video/mp4", "${SEED_FOLDERS[1]}/", video)
            setModifiedAndRescan(image, newestMs)
            rows = listOf(image, clip)
        } else {
            // The fallback is DocumentsUI, whose Recent hides the app's own media: use Downloads.
            video = mp4Bytes()
            rows = listOf(
                insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, names[0], "image/jpeg", "Download/", photo),
                insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, names[1], "video/mp4", "Download/", video),
            )
        }
        Thread.sleep(1_000)
        val result = startPick { l, done -> pickers.pickPhotos(l, VisualKind.IMAGE_AND_VIDEO, 0, done) }
        if (system) SystemUi.selectInPhotoPicker(2) else SystemUi.selectSeveralInDocumentsUi(names)
        val uris = result()
        assertEquals(2, uris.size)
        val expected = setOf(photo.toList(), video.toList())
        val got = HashSet<List<Byte>>()
        val items = pickers.describeAll(uris, PickedSourceMsg.PHOTO_LIBRARY)
        if (system) {
            // OBS-S2A-1: the Photo Picker reports "<media id>.<ext>"; imports are named by capture date.
            for (item in items) {
                assertTrue(item.displayName, Regex("""IMG_\d{8}_\d{6}( \(\d+\))?\.(jpg|mp4)""").matches(item.displayName))
                assertEquals(if (item.mimeType!!.startsWith("video/")) "mp4" else "jpg", item.displayName.substringAfterLast('.'))
            }
        } else {
            assertEquals(names.toSet(), items.map { it.displayName }.toSet())
        }
        android.util.Log.i("AndroidPickersTest", "photo picker names: ${items.map { it.displayName }}")
        for ((uri, item) in uris.zip(items)) {
            assertEquals(PickedSourceMsg.PHOTO_LIBRARY, item.source)
            assertTrue(item.needsCopy)
            assertTrue(item.displayName.isNotEmpty())
            assertTrue(item.mimeType!!.startsWith("image/") || item.mimeType!!.startsWith("video/"))
            got += copied(uri).toList()
        }
        assertEquals(expected, got)
        assertArrayEquals(photo, readAll(rows[0]))
        assertArrayEquals(video, readAll(rows[1]))
    }

    @Test
    fun aLimitOfOneIsASingleSelection() {
        assumeTrue("seeding MediaStore needs API 29+", Build.VERSION.SDK_INT >= 29)
        val system = pickers.photoPickerAvailable()
        val name = "dv_one_$stamp.jpg"
        val photo = jpegBytes(Color.MAGENTA)
        if (system) {
            val image = insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, name, "image/jpeg", "${SEED_FOLDERS[0]}/", photo)
            setModifiedAndRescan(image, newestGalleryDateMs() + 60_000)
        } else {
            insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, name, "image/jpeg", "Download/", photo)
        }
        Thread.sleep(1_000)
        val result = startPick { l, done -> pickers.pickPhotos(l, VisualKind.IMAGE_ONLY, 1, done) }
        if (system) {
            SystemUi.selectInPhotoPicker(1)
        } else {
            // An image-only pick opens DocumentsUI in grid view, where items carry only a description.
            val quoted = java.util.regex.Pattern.quote(name)
            if (SystemUi.waitAny(6_000, SystemUi.byText(quoted), SystemUi.byDesc("^$quoted.*")) == null) SystemUi.openDownloadsIfNeeded(name)
            (SystemUi.listed(name, 10_000, SystemUi.byDesc("^$quoted.*")) ?: error("not listed:\n" + SystemUi.dump())).click()
        }
        val uris = result()
        assertEquals(1, uris.size)
        assertArrayEquals(photo, copied(uris[0]))
    }

    @Test
    fun aCancelledPickerAnswersNothing() {
        val result = startPick { l, done -> pickers.pickDocuments(l, true, emptyList(), done) }
        Thread.sleep(2_500)
        SystemUi.device.pressBack()
        assertEquals(emptyList<Uri>(), result())
    }

    // ---------------------------------------------------------------------------------------------
    // Photo Picker ordering helpers (from the editor engine's AND-14 PickerFlowTest)

    private fun newestGalleryDateMs(): Long {
        var newest = System.currentTimeMillis()
        val columns = arrayOf(MediaStore.Images.ImageColumns.DATE_TAKEN, MediaStore.MediaColumns.DATE_MODIFIED, MediaStore.MediaColumns.DATE_ADDED)
        for (collection in listOf(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, MediaStore.Video.Media.EXTERNAL_CONTENT_URI)) {
            resolver.query(collection, columns, null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    if (!c.isNull(0)) newest = maxOf(newest, c.getLong(0))
                    if (!c.isNull(1)) newest = maxOf(newest, c.getLong(1) * 1000)
                    if (!c.isNull(2)) newest = maxOf(newest, c.getLong(2) * 1000)
                }
            }
        }
        return newest
    }

    @Suppress("DEPRECATION")
    private fun setModifiedAndRescan(uri: Uri, ms: Long) {
        val path = resolver.query(uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)!!.use { c ->
            check(c.moveToFirst()) { "inserted item not found" }
            c.getString(0)
        }
        assertTrue("modification time set", File(path).setLastModified(ms))
        val scanned = CountDownLatch(1)
        android.media.MediaScannerConnection.scanFile(context, arrayOf(path), null) { _, _ -> scanned.countDown() }
        assertTrue("rescanned", scanned.await(15, TimeUnit.SECONDS))
    }

    /** [mp4] with its movie header's creation and modification times set to [epochSeconds]. */
    private fun withMp4CreationTime(mp4: ByteArray, epochSeconds: Long): ByteArray {
        val out = mp4.copyOf()
        val mp4Seconds = epochSeconds + 2_082_844_800L
        fun u32(at: Int) = ((out[at].toLong() and 0xFF) shl 24) or ((out[at + 1].toLong() and 0xFF) shl 16) or
            ((out[at + 2].toLong() and 0xFF) shl 8) or (out[at + 3].toLong() and 0xFF)
        fun put(at: Int, value: Long, bytes: Int) {
            for (i in 0 until bytes) out[at + i] = (value ushr (8 * (bytes - 1 - i))).toByte()
        }
        fun find(type: String, from: Int, to: Int): Int {
            var at = from
            while (at + 8 <= to) {
                val size = when (val s = u32(at)) {
                    1L -> (u32(at + 8) shl 32) or u32(at + 12)
                    0L -> (to - at).toLong()
                    else -> s
                }
                if (String(out, at + 4, 4, Charsets.US_ASCII) == type) return at
                check(size >= 8) { "unsupported MP4 box size" }
                at += size.toInt()
            }
            error("no $type box")
        }
        val moov = find("moov", 0, out.size)
        val mvhd = find("mvhd", moov + 8, moov + u32(moov).toInt())
        if (out[mvhd + 8].toInt() == 1) {
            put(mvhd + 12, mp4Seconds, 8)
            put(mvhd + 20, mp4Seconds, 8)
        } else {
            put(mvhd + 12, mp4Seconds, 4)
            put(mvhd + 16, mp4Seconds, 4)
        }
        return out
    }
}
