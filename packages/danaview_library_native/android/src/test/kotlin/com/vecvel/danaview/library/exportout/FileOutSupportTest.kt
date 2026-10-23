// OWNER: HOM-22A
//
// JVM tests of the pure file-out helpers (exportout/FileOutSupport.kt): safe names, numbering,
// media kinds, MIME types, share types, MediaStore folders, validation, and TempCopyStore (batch
// layout, batch-unique names, read-only copies, sources untouched, a failed batch removed, the
// 24 h sweep).

package com.vecvel.danaview.library.exportout

import com.vecvel.danaview.library.glue.LibraryErrorCode
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

class FileOutSupportTest {
    private lateinit var dir: File
    private lateinit var cache: File
    private var now = 1_000_000_000_000L

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("fileout-test").toFile()
        cache = File(dir, "cache").apply { mkdirs() }
    }

    @After
    fun tearDown() {
        dir.walkBottomUp().forEach { it.setWritable(true); it.delete() }
    }

    private fun failure(block: () -> Unit): OutFailure {
        try {
            block()
        } catch (f: OutFailure) {
            return f
        }
        fail("expected an OutFailure")
        throw AssertionError()
    }

    private fun src(name: String, bytes: ByteArray = name.toByteArray()) = File(dir, "lib-$name").apply { writeBytes(bytes) }

    @Test
    fun safeNamesAndNumbering() {
        assertEquals("a_b_c.txt", FileOut.safeName("a/b:c.txt"))
        assertEquals("hidden", FileOut.safeName("..hidden"))
        assertEquals("file", FileOut.safeName("  "))
        assertEquals("x_y", FileOut.safeName("x\u0001y"))
        val long = "é".repeat(200) + ".jpeg"
        val safe = FileOut.safeName(long)
        assertTrue(safe.toByteArray().size <= 255)
        assertTrue(safe.endsWith(".jpeg"))
        assertEquals("Trip.jpg", FileOut.numbered("Trip.jpg", 1))
        assertEquals("Trip (2).jpg", FileOut.numbered("Trip.jpg", 2))
        assertEquals("README (3)", FileOut.numbered("README", 3))
        val taken = setOf("a.pdf", "a (2).pdf")
        assertEquals("a (3).pdf", FileOut.unique("a.pdf") { it in taken })
    }

    @Test
    fun kindsAndTypes() {
        assertEquals(OutMediaKind.PHOTO, FileOut.mediaKind(OutFile("/x", "IMG.HEIC", null)))
        assertEquals(OutMediaKind.VIDEO, FileOut.mediaKind(OutFile("/x", "clip", "video/mp4")))
        assertEquals(OutMediaKind.OTHER, FileOut.mediaKind(OutFile("/x", "doc.pdf", "application/pdf")))
        assertEquals(OutMediaKind.PHOTO, FileOut.mediaKind(OutFile("/a/b.png", "", null)))
        assertEquals("image/jpeg", FileOut.mimeType(null, "a.JPG"))
        assertEquals("application/pdf", FileOut.mimeType("Application/PDF", "a"))
        assertEquals("application/octet-stream", FileOut.mimeType("image/*", "a.unknown"))
        assertEquals("image/png", FileOut.commonType(listOf("image/png", "image/png")))
        assertEquals("image/*", FileOut.commonType(listOf("image/png", "image/jpeg")))
        assertEquals("*/*", FileOut.commonType(listOf("image/png", "application/pdf")))
    }

    @Test
    fun mediaStoreFolders() {
        assertEquals("Download/Danaview/", FileOut.downloadsPath("Danaview"))
        assertEquals("Download/", FileOut.downloadsPath(null))
        assertEquals("Download/a/b/", FileOut.downloadsPath("a/../b"))
        assertEquals("Download/x_y/", FileOut.downloadsPath("x:y"))
        assertEquals("Pictures/Danaview/", FileOut.photosPath(OutMediaKind.PHOTO))
        assertEquals("Movies/Danaview/", FileOut.photosPath(OutMediaKind.VIDEO))
    }

    @Test
    fun validation() {
        assertEquals(LibraryErrorCode.invalidArgument, failure { FileOut.validate(emptyList()) }.code)
        assertEquals(LibraryErrorCode.invalidArgument, failure { FileOut.validate(listOf(OutFile("rel/x", "x", null))) }.code)
        assertEquals(LibraryErrorCode.notFound, failure { FileOut.validate(listOf(OutFile(abs(File(dir, "gone")), "x", null))) }.code)
        assertEquals(LibraryErrorCode.notFound, failure { FileOut.validate(listOf(OutFile(abs(dir), "x", null))) }.code)
        assertEquals(LibraryErrorCode.invalidArgument, failure { FileOut.validate(listOf(OutFile(abs(src("a")), "", null))) }.code)
    }

    private fun abs(f: File): String = f.absolutePath

    @Test
    fun batchesHoldReadOnlyCopiesWithUniqueNames() {
        val a = src("a", byteArrayOf(1, 2, 3))
        val b = src("b", byteArrayOf(4, 5))
        val store = TempCopyStore(cache) { now }
        val batch = store.makeBatch(listOf(OutFile(abs(a), "Photo.jpg", null), OutFile(abs(b), "photo.JPG", null), OutFile(abs(a), "a/b", null)))
        assertEquals(File(cache, "danaview-out"), batch.directory.parentFile)
        assertEquals(listOf("Photo.jpg", "photo (2).JPG", "a_b"), batch.files.map { it.name })
        assertArrayEquals(byteArrayOf(1, 2, 3), batch.files[0].readBytes())
        assertArrayEquals(byteArrayOf(4, 5), batch.files[1].readBytes())
        assertTrue(batch.files.all { !it.canWrite() })
        assertTrue("sources stay writable and unchanged", a.canWrite() && a.readBytes().contentEquals(byteArrayOf(1, 2, 3)))
        val second = store.makeBatch(listOf(OutFile(abs(a), "Photo.jpg", null)))
        assertTrue(second.directory != batch.directory)
        assertEquals(2, store.batches().size)
        store.remove(batch)
        assertFalse(batch.directory.exists())
        assertEquals(1, store.batches().size)
    }

    @Test
    fun aFailedBatchIsRemoved() {
        val store = TempCopyStore(cache) { now }
        val a = src("a")
        val gone = File(dir, "gone")
        assertEquals(LibraryErrorCode.notFound, failure { store.makeBatch(listOf(OutFile(abs(a), "a", null), OutFile(abs(gone), "g", null))) }.code)
        assertEquals(0, store.batches().size)
    }

    @Test
    fun sweepRemovesBatchesOlderThanADay() {
        val store = TempCopyStore(cache) { now }
        val old = store.makeBatch(listOf(OutFile(abs(src("o")), "o", null)))
        val fresh = store.makeBatch(listOf(OutFile(abs(src("f")), "f", null)))
        assertTrue(old.directory.setLastModified(now - TempCopyStore.STALE_AGE_MS - 60_000))
        assertTrue(fresh.directory.setLastModified(now - 60_000))
        assertEquals(1, store.sweepStale())
        assertFalse(old.directory.exists())
        assertTrue(fresh.directory.exists())
        // makeBatch sweeps too.
        assertTrue(fresh.directory.setLastModified(now - TempCopyStore.STALE_AGE_MS - 1))
        store.makeBatch(listOf(OutFile(abs(src("n")), "n", null)))
        assertFalse(fresh.directory.exists())
        assertEquals(1, store.batches().size)
    }
}
