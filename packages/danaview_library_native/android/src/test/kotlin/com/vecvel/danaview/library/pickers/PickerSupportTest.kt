// OWNER: HOM-20A
//
// JVM tests of the pure picker helpers (pickers/PickerSupport.kt): filters, limits, SAF types,
// display names, the copy registry, and the streamed resumable copy (fresh, resume with
// truncation, offsets past the destination or the source, cancel keeping the part bytes,
// progress throttling with fsynced checkpoints, a missing destination directory).

package com.vecvel.danaview.library.pickers

import com.vecvel.danaview.library.glue.LibraryErrorCode
import com.vecvel.danaview.library.pigeon.PhotoMediaFilterMsg
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.nio.file.Files

class PickerSupportTest {
    private lateinit var dir: File

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("picker-test").toFile()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun data(n: Int) = ByteArray(n) { ((it * 31 + (it shr 8) * 7 + 5) and 0xff).toByte() }

    private fun failure(block: () -> Unit): PickerFailure {
        try {
            block()
        } catch (f: PickerFailure) {
            return f
        }
        fail("expected a PickerFailure")
        throw AssertionError()
    }

    @Test
    fun filtersAndLimits() {
        assertEquals(VisualKind.IMAGE_AND_VIDEO, PickerRequests.visualKind(PhotoMediaFilterMsg.ALL))
        assertEquals(VisualKind.IMAGE_ONLY, PickerRequests.visualKind(PhotoMediaFilterMsg.PHOTOS))
        assertEquals(VisualKind.VIDEO_ONLY, PickerRequests.visualKind(PhotoMediaFilterMsg.VIDEOS))
        assertEquals(listOf("image/*", "video/*"), PickerRequests.visualMimeTypes(VisualKind.IMAGE_AND_VIDEO))
        assertEquals(1, PickerRequests.maxItems(1, 100))
        assertEquals(100, PickerRequests.maxItems(0, 100))
        assertEquals(Int.MAX_VALUE, PickerRequests.maxItems(0, null))
        assertEquals(5, PickerRequests.maxItems(5, 100))
        assertEquals(100, PickerRequests.maxItems(500, 100))
        assertEquals(2, PickerRequests.maxItems(2, null))
        assertEquals(listOf(1, 2), PickerRequests.limited(listOf(1, 2, 3), 2))
        assertEquals(listOf(1, 2, 3), PickerRequests.limited(listOf(1, 2, 3), 0))
    }

    @Test
    fun documentTypes() {
        assertEquals("*/*" to null, PickerRequests.documentTypes(emptyList()).let { it.first to it.second?.toList() })
        assertEquals("application/pdf" to null, PickerRequests.documentTypes(listOf(" Application/PDF ")).let { it.first to it.second?.toList() })
        val (type, extra) = PickerRequests.documentTypes(listOf("image/*", "application/pdf", "image/*", "bogus"))
        assertEquals("*/*", type)
        assertArrayEquals(arrayOf("image/*", "application/pdf"), extra)
    }

    @Test
    fun displayNames() {
        assertEquals("Holiday.jpg", PickerRequests.displayName("Holiday.jpg", "123", "jpg"))
        assertEquals("1000000034.jpg", PickerRequests.displayName(null, "1000000034", "jpg"))
        assertEquals("doc 1.pdf", PickerRequests.displayName(null, "primary:Download/doc 1.pdf", "pdf"))
        assertEquals("a_b.txt", PickerRequests.displayName("a/b.txt", null, null))
        assertEquals("Imported item", PickerRequests.displayName("  ", null, null))
        assertEquals("Scan.pdf", PickerRequests.displayName("Scan", null, "pdf"))
        assertEquals(".hidden.png", PickerRequests.displayName(".hidden", null, "png"))
    }

    @Test
    fun importNamesUseTheRealDisplayNameElseTheCaptureDate() {
        val utc = java.util.TimeZone.getTimeZone("UTC")
        val taken = 1_729_501_500_000L // 2024-10-21 09:05:00 UTC
        val added = 1_700_000_000_000L // 2023-11-14 22:13:20 UTC
        var asked = 0
        val dates = { asked++; taken to added }
        // A real DISPLAY_NAME wins; the dates are not even asked.
        assertEquals("Holiday.jpg", PickerRequests.importName("Holiday.jpg", "1000000428", "jpg", true, utc, dates))
        assertEquals("2024.pdf", PickerRequests.importName("2024.pdf", "primary:Download/2024.pdf", "pdf", false, utc, dates))
        assertEquals(0, asked)
        // The Photo Picker's media-id name: IMG_ from DATE_TAKEN, the reported extension kept.
        assertEquals("IMG_20241021_090500.mp4", PickerRequests.importName("1000000428.mp4", "1000000428", "mp4", true, utc, dates))
        assertEquals("IMG_20241021_090500.jpg", PickerRequests.importName("1000000429.JPG", "1000000429", "jpg", true, utc, dates))
        // No DATE_TAKEN: DATE_ADDED.
        assertEquals("IMG_20231114_221320.jpg", PickerRequests.importName("1000000430.jpg", "1000000430", "jpg", true, utc) { null to added })
        // No name at all: the date, with the MIME type's extension.
        assertEquals("IMG_20241021_090500.heic", PickerRequests.importName(null, "77", "heic", true, utc, dates))
        // A digits-only file name from the files picker stays, unless it is the URI's own id.
        assertEquals("12345.jpg", PickerRequests.importName("12345.jpg", "primary:DCIM/12345.jpg", "jpg", false, utc, dates))
        assertEquals("IMG_20241021_090500.jpg", PickerRequests.importName("1000000431.jpg", "1000000431", "jpg", false, utc, dates))
        // No dates either: the old fallbacks (the reported name, else the URI segment).
        assertEquals("1000000432.jpg", PickerRequests.importName("1000000432.jpg", "1000000432", "jpg", true, utc) { null to null })
        assertEquals("1000000433.png", PickerRequests.importName(null, "1000000433", "png", true, utc) { null to 0L })
        // The capture time is local time in the given zone.
        assertEquals("IMG_20241021_143500.jpg", PickerRequests.importName("1.jpg", "1", "jpg", true, java.util.TimeZone.getTimeZone("GMT+05:30"), dates))
        assertTrue(PickerRequests.isMediaIdName("1000000428.mp4", null, true))
        assertFalse(PickerRequests.isMediaIdName("IMG_0001.jpg", "1000000428", true))
        assertFalse(PickerRequests.isMediaIdName("12.jpg", "msf:13", false))
        assertTrue(PickerRequests.isMediaIdName("13.jpg", "msf:13", false))
    }

    @Test
    fun clashesInsideOnePickAreNumberedAsOnApple() {
        assertEquals("Trip (2).jpg", PickerRequests.numbered("Trip.jpg", 2))
        assertEquals("notes (3)", PickerRequests.numbered("notes", 3))
        assertEquals(".hidden (2)", PickerRequests.numbered(".hidden", 2))
        assertEquals(
            listOf("IMG_20241021_090500.jpg", "IMG_20241021_090500 (2).jpg", "IMG_20241021_090500.mp4", "IMG_20241021_090500 (3).jpg", "a.pdf", "A (2).PDF"),
            PickerRequests.uniqueNames(
                listOf("IMG_20241021_090500.jpg", "IMG_20241021_090500.jpg", "IMG_20241021_090500.mp4", "IMG_20241021_090500.jpg", "a.pdf", "A.PDF"),
            ),
        )
        // A generated number that is itself taken moves on.
        assertEquals(listOf("x.jpg", "x (2).jpg", "x (3).jpg"), PickerRequests.uniqueNames(listOf("x.jpg", "x (2).jpg", "x.jpg")))
    }

    @Test
    fun registry() {
        val r = CopyRegistry()
        assertTrue(r.start("a"))
        assertFalse(r.start("a"))
        assertFalse(r.isCancelled("a"))
        assertTrue(r.cancel("a"))
        assertTrue(r.isCancelled("a"))
        assertFalse(r.cancel("unknown"))
        r.finish("a")
        assertTrue(r.start("a"))
        assertFalse(r.isCancelled("a"))
    }

    @Test
    fun effectiveOffsets() {
        assertEquals(0, StreamCopy.effectiveOffset(0, 500, 1000))
        assertEquals(300, StreamCopy.effectiveOffset(300, 500, 1000))
        assertEquals(500, StreamCopy.effectiveOffset(800, 500, 1000))
        assertEquals(0, StreamCopy.effectiveOffset(800, 900, 700))
        assertEquals(800, StreamCopy.effectiveOffset(800, 900, null))
        assertEquals(0, StreamCopy.effectiveOffset(800, -1, null))
    }

    @Test
    fun freshCopyWritesEveryByte() {
        val src = data(10_000)
        val dest = File(dir, "a.part").apply { writeBytes(ByteArray(50_000)) } // a stale longer part
        val reports = ArrayList<Pair<Long, Long?>>()
        val (copied, total) = StreamCopy.copy(ByteArrayInputStream(src), dest, 0, 10_000L, { false }, { d, t -> reports += d to t }, chunkBytes = 1000, progressEvery = 3000, minIntervalMs = 0)
        assertEquals(10_000L to 10_000L, copied to total)
        assertArrayEquals(src, dest.readBytes())
        assertEquals(listOf(3000L, 6000L, 9000L, 10_000L), reports.map { it.first })
        assertTrue(reports.all { it.second == 10_000L })
    }

    @Test
    fun resumeTruncatesToTheOffsetAndAppends() {
        val src = data(10_000)
        // The part holds 6000 good bytes plus 1000 garbage bytes written after the last checkpoint.
        val dest = File(dir, "r.part").apply { writeBytes(src.copyOf(6000) + ByteArray(1000) { 0x7f }) }
        val (copied, total) = StreamCopy.copy(ByteArrayInputStream(src), dest, 6000, null, { false }, { _, _ -> }, chunkBytes = 777)
        assertEquals(10_000L to 10_000L, copied to total)
        assertArrayEquals(src, dest.readBytes())
    }

    @Test
    fun resumePastTheDestinationRestartsFromWhatItHas() {
        val src = data(5000)
        val dest = File(dir, "s.part").apply { writeBytes(src.copyOf(1200)) }
        StreamCopy.copy(ByteArrayInputStream(src), dest, 4000, 5000L, { false }, { _, _ -> })
        assertArrayEquals(src, dest.readBytes())
        // A missing destination resumes from 0.
        val fresh = File(dir, "missing.part")
        StreamCopy.copy(ByteArrayInputStream(src), fresh, 4000, 5000L, { false }, { _, _ -> })
        assertArrayEquals(src, fresh.readBytes())
    }

    @Test
    fun sourceShorterThanAnUnknownSizeResumeIsAnIoError() {
        val dest = File(dir, "t.part").apply { writeBytes(ByteArray(4000)) }
        val f = failure { StreamCopy.copy(ByteArrayInputStream(data(1000)), dest, 4000, null, { false }, { _, _ -> }) }
        assertEquals(LibraryErrorCode.ioError, f.code)
    }

    @Test
    fun cancelStopsAndKeepsTheCheckpointedBytes() {
        val src = data(100_000)
        val dest = File(dir, "c.part")
        var reads = 0
        val counting = object : InputStream() {
            val inner = ByteArrayInputStream(src)
            override fun read(): Int = inner.read()
            override fun read(b: ByteArray, off: Int, len: Int): Int = inner.read(b, off, len).also { reads++ }
        }
        val f = failure {
            StreamCopy.copy(counting, dest, 0, 100_000L, { reads >= 3 }, { _, _ -> }, chunkBytes = 1000)
        }
        assertEquals(LibraryErrorCode.cancelled, f.code)
        assertEquals(3000L, dest.length())
        assertArrayEquals(src.copyOf(3000), dest.readBytes())
    }

    @Test
    fun progressIsThrottledByTime() {
        val src = data(20_000)
        var now = 0L
        val reports = ArrayList<Long>()
        StreamCopy.copy(ByteArrayInputStream(src), File(dir, "p.part"), 0, null, { false }, { d, _ -> reports += d },
            chunkBytes = 1000, progressEvery = 1000, minIntervalMs = 250, clock = { now += 100; now })
        // 100 ms per chunk, at most one report per 250 ms, plus the final one.
        assertTrue(reports.size in 6..8)
        assertEquals(20_000L, reports.last())
        val gaps = reports.zipWithNext { a, b -> b - a }.dropLast(1)
        assertTrue(gaps.all { it >= 2000 })
    }

    @Test
    fun badDestinationsAndOffsets() {
        assertEquals(LibraryErrorCode.ioError, failure { StreamCopy.copy(ByteArrayInputStream(data(10)), File(dir, "no/such/dir.part"), 0, null, { false }, { _, _ -> }) }.code)
        assertEquals(LibraryErrorCode.invalidArgument, failure { StreamCopy.copy(ByteArrayInputStream(data(10)), File(dir, "x.part"), -1, null, { false }, { _, _ -> }) }.code)
        assertNull(File(dir, "no").listFiles())
    }
}
