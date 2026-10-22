// OWNER: HOM-02A
//
// JVM tests of the pure MediaStore helpers (photolibrary/MediaStoreSupport.kt): cursor row mapping,
// query building and page windows, change tokens and change collection, albums, EXIF dates and
// create-new naming.

package com.vecvel.danaview.library.photolibrary

import com.vecvel.danaview.library.pigeon.LibraryPigeonError
import com.vecvel.danaview.library.pigeon.PhotoAlbumKindMsg
import com.vecvel.danaview.library.pigeon.PhotoAssetKindMsg
import com.vecvel.danaview.library.pigeon.PhotoMediaFilterMsg
import com.vecvel.danaview.library.pigeon.PhotoSortMsg
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.TimeZone

class MediaStoreSupportTest {
    private class Row(private val values: Map<String, Any?>) : MediaRow {
        override fun long(column: String): Long? = (values[column] as Number?)?.toLong()

        override fun string(column: String): String? = values[column] as String?
    }

    private fun photo(vararg extra: Pair<String, Any?>) = Row(
        mapOf(
            Col.ID to 42L, Col.MEDIA_TYPE to 1, Col.MIME_TYPE to "image/jpeg", Col.DISPLAY_NAME to "IMG_0001.jpg",
            Col.SIZE to 123456L, Col.WIDTH to 4000, Col.HEIGHT to 3000, Col.DATE_TAKEN to 1_700_000_000_123L,
            Col.DATE_ADDED to 1_700_000_100L, Col.DATE_MODIFIED to 1_700_000_200L, Col.BUCKET_DISPLAY_NAME to "Camera",
        ) + extra,
    )

    private fun errorCode(block: () -> Unit): String = try {
        block()
        fail("no error")
        ""
    } catch (e: LibraryPigeonError) {
        e.code
    }

    // Row mapping

    @Test
    fun mapsAPhotoRow() {
        val a = PhotoAssetMapping.asset(photo())!!
        assertEquals("42", a.localIdentifier)
        assertEquals(PhotoAssetKindMsg.PHOTO, a.kind)
        assertEquals(4000L, a.widthPx)
        assertEquals(3000L, a.heightPx)
        assertEquals(1_700_000_000_123L, a.creationTimeMs)
        assertEquals(1_700_000_200_000L, a.modificationTimeMs)
        assertEquals(0L, a.durationMs)
        assertFalse(a.isFavorite)
        assertFalse(a.isRaw)
        assertFalse(a.isHdr)
        assertFalse(a.isLivePhoto)
        assertFalse(a.isScreenshot)
        assertEquals("IMG_0001.jpg", a.originalFilename)
        assertNull(a.uti)
        assertEquals("image/jpeg", a.mimeType)
        assertEquals(123456L, a.sizeBytes)
    }

    @Test
    fun mapsAVideoRowWithDurationAndFavourite() {
        val a = PhotoAssetMapping.asset(
            photo(Col.MEDIA_TYPE to 3, Col.MIME_TYPE to "video/mp4", Col.DISPLAY_NAME to "clip.mp4", Col.DURATION to 12_345L, Col.IS_FAVORITE to 1),
        )!!
        assertEquals(PhotoAssetKindMsg.VIDEO, a.kind)
        assertEquals(12_345L, a.durationMs)
        assertTrue(a.isFavorite)
        assertFalse(a.isRaw)
    }

    @Test
    fun skipsRowsThatAreNotImagesOrVideos() {
        assertNull(PhotoAssetMapping.asset(photo(Col.MEDIA_TYPE to 2))) // audio
        assertNull(PhotoAssetMapping.asset(photo(Col.MEDIA_TYPE to 0)))
        assertNull(PhotoAssetMapping.asset(photo(Col.ID to null)))
    }

    @Test
    fun aQuarterTurnSwapsTheDimensions() {
        for (o in listOf(90, 270, -90)) {
            val a = PhotoAssetMapping.asset(photo(Col.ORIENTATION to o))!!
            assertEquals("orientation $o", 3000L, a.widthPx)
            assertEquals(4000L, a.heightPx)
        }
        val upright = PhotoAssetMapping.asset(photo(Col.ORIENTATION to 180))!!
        assertEquals(4000L, upright.widthPx)
    }

    @Test
    fun missingValuesFallBack() {
        val a = PhotoAssetMapping.asset(
            photo(Col.DATE_TAKEN to 0L, Col.WIDTH to null, Col.HEIGHT to null, Col.SIZE to null, Col.DATE_MODIFIED to null, Col.MIME_TYPE to null),
        )!!
        assertEquals("date added (s) when there is no capture date", 1_700_000_100_000L, a.creationTimeMs)
        assertEquals(0L, a.widthPx)
        assertEquals(0L, a.heightPx)
        assertNull(a.sizeBytes)
        assertNull(a.modificationTimeMs)
        assertEquals("image/jpeg", a.mimeType) // from the extension
        assertNull(PhotoAssetMapping.asset(photo(Col.DATE_TAKEN to null, Col.DATE_ADDED to null))!!.creationTimeMs)
    }

    @Test
    fun rawByMimeOrExtension() {
        assertTrue(PhotoAssetMapping.asset(photo(Col.MIME_TYPE to "image/x-adobe-dng", Col.DISPLAY_NAME to "a.dng"))!!.isRaw)
        assertTrue(PhotoAssetMapping.asset(photo(Col.MIME_TYPE to "image/x-sony-arw", Col.DISPLAY_NAME to "b"))!!.isRaw)
        assertTrue(PhotoAssetMapping.asset(photo(Col.MIME_TYPE to "application/octet-stream", Col.DISPLAY_NAME to "c.CR3"))!!.isRaw)
        assertFalse(PhotoAssetMapping.asset(photo(Col.MIME_TYPE to "image/heic", Col.DISPLAY_NAME to "d.heic"))!!.isRaw)
        assertEquals("image/heic", PhotoAssetMapping.asset(photo(Col.MIME_TYPE to null, Col.DISPLAY_NAME to "d.HEIC"))!!.mimeType)
        assertEquals("image/avif", PhotoAssetMapping.asset(photo(Col.MIME_TYPE to "image/avif", Col.DISPLAY_NAME to "e.avif"))!!.mimeType)
    }

    @Test
    fun screenshotsByFolder() {
        assertTrue(PhotoAssetMapping.asset(photo(Col.BUCKET_DISPLAY_NAME to "Screenshots"))!!.isScreenshot)
        assertTrue(PhotoAssetMapping.asset(photo(Col.BUCKET_DISPLAY_NAME to "x", Col.RELATIVE_PATH to "DCIM/Screenshots/"))!!.isScreenshot)
        assertFalse(PhotoAssetMapping.asset(photo(Col.RELATIVE_PATH to "Pictures/MyScreenshotsAlbum/"))!!.isScreenshot)
        assertFalse(
            "videos are never screenshots",
            PhotoAssetMapping.asset(photo(Col.MEDIA_TYPE to 3, Col.BUCKET_DISPLAY_NAME to "Screenshots"))!!.isScreenshot,
        )
    }

    @Test
    fun gridProjectionPerApiLevel() {
        val p24 = Col.gridProjection(24).toSet()
        assertFalse(Col.RELATIVE_PATH in p24)
        assertFalse(Col.IS_FAVORITE in p24)
        assertFalse(Col.ORIENTATION in p24)
        val p29 = Col.gridProjection(29).toSet()
        assertTrue(Col.RELATIVE_PATH in p29 && Col.ORIENTATION in p29)
        assertFalse(Col.IS_FAVORITE in p29)
        assertTrue(Col.IS_FAVORITE in Col.gridProjection(30).toSet())
    }

    // Query

    @Test
    fun selectionPerFilterAndAlbum() {
        assertEquals("media_type IN (1,3)", MediaStoreQuery.selection(PhotoMediaFilterMsg.ALL, null).sql)
        assertEquals("media_type=1", MediaStoreQuery.selection(PhotoMediaFilterMsg.PHOTOS, null).sql)
        assertEquals("media_type=3", MediaStoreQuery.selection(PhotoMediaFilterMsg.VIDEOS, null).sql)
        val album = MediaStoreQuery.selection(PhotoMediaFilterMsg.PHOTOS, "-1739773001")
        assertEquals("media_type=1 AND bucket_id=?", album.sql)
        assertArrayEquals(arrayOf("-1739773001"), album.args)
        assertEquals("notFound", errorCode { MediaStoreQuery.selection(PhotoMediaFilterMsg.ALL, "Camera'; DROP") })
    }

    @Test
    fun idSelectionBindsOnlyNumericIds() {
        val s = MediaStoreQuery.idSelection(listOf("1", "x", "22"))
        assertEquals("media_type IN (1,3) AND _id IN (?,?)", s.sql)
        assertArrayEquals(arrayOf("1", "22"), s.args)
    }

    @Test
    fun sortOrdersBreakTiesById() {
        assertEquals("datetaken DESC, _id DESC", MediaStoreQuery.sortOrder(PhotoSortMsg.CREATION_NEWEST_FIRST))
        assertEquals("datetaken ASC, _id ASC", MediaStoreQuery.sortOrder(PhotoSortMsg.CREATION_OLDEST_FIRST))
        assertEquals("date_modified DESC, _id DESC", MediaStoreQuery.sortOrder(PhotoSortMsg.MODIFICATION_NEWEST_FIRST))
    }

    @Test
    fun pageWindowValidatesAndClamps() {
        assertEquals(0 to 200, MediaStoreQuery.window(0, 200))
        assertEquals(400 to 500, MediaStoreQuery.window(400, 10_000))
        assertEquals(7 to 1, MediaStoreQuery.window(7, 1))
        assertEquals("invalidArgument", errorCode { MediaStoreQuery.window(-1, 10) })
        assertEquals("invalidArgument", errorCode { MediaStoreQuery.window(0, 0) })
        assertEquals("invalidArgument", errorCode { MediaStoreQuery.window(Long.MAX_VALUE, 10) })
    }

    // Tokens and changes

    @Test
    fun tokensMoveOnInsertAndDelete() {
        val base = ChangeTokens.of(10, 100)
        assertEquals(base, ChangeTokens.of(10, 100))
        assertTrue(base != ChangeTokens.of(11, 101), "insert")
        assertTrue(base != ChangeTokens.of(9, 100), "delete of an older asset")
        assertTrue(base != ChangeTokens.of(9, 99), "delete of the newest")
        assertTrue(base != ChangeTokens.of(10, 101), "one deleted, one added")
        assertEquals("c0-m0", ChangeTokens.of(0, null))
        assertFalse(ChangeTokens.isStale(null, base))
        assertFalse(ChangeTokens.isStale(base, base))
        assertTrue(ChangeTokens.isStale("c1-m1", base))
    }

    @Test
    fun publishedPendingItemsCountAsInserted() {
        val previous = ChangeTokens.of(10, 100)
        assertEquals(100L, ChangeTokens.maxId(previous))
        assertNull(ChangeTokens.maxId("g1"))
        val (inserted, changed) = ChangeTokens.reclassify(previous, listOf("105"), listOf("101", "50", "105"))
        assertEquals(listOf("105", "101"), inserted)
        assertEquals(listOf("50"), changed)
        assertEquals(listOf("7") to listOf("200"), ChangeTokens.reclassify(null, listOf("7"), listOf("200")))
    }

    private fun assertTrue(condition: Boolean, message: String) = assertTrue(message, condition)

    @Test
    fun collectsIncrementalChanges() {
        val c = ChangeCollector()
        assertTrue(c.isEmpty)
        c.add("1", ChangeCollector.NOTIFY_INSERT)
        c.add("1", ChangeCollector.NOTIFY_UPDATE) // update of a new asset stays an insert
        c.add("2", ChangeCollector.NOTIFY_UPDATE)
        c.add("3", ChangeCollector.NOTIFY_DELETE)
        c.add("4", ChangeCollector.NOTIFY_INSERT)
        c.add("4", ChangeCollector.NOTIFY_DELETE) // inserted then deleted: nothing
        c.add("2", ChangeCollector.NOTIFY_UPDATE)
        val d = c.drain()
        assertTrue(d.incremental)
        assertEquals(listOf("1"), d.inserted)
        assertEquals(listOf("3"), d.removed)
        assertEquals(listOf("2"), d.changed)
        assertTrue(c.isEmpty)
    }

    @Test
    fun unknownChangesAreNotIncremental() {
        val c = ChangeCollector()
        c.add("1", ChangeCollector.NOTIFY_INSERT)
        c.add(null, ChangeCollector.NOTIFY_UPDATE) // a collection URI
        val d = c.drain()
        assertFalse(d.incremental)
        assertTrue(d.inserted.isEmpty() && d.removed.isEmpty() && d.changed.isEmpty())

        c.add("5", 0) // no flags (API ≤ 29 path)
        assertFalse(c.drain().incremental)
        c.addUnknown()
        assertFalse(c.isEmpty)
        assertFalse(c.drain().incremental)
        assertTrue(c.drain().incremental) // drained: fresh again
    }

    @Test
    fun tooManyIdsFallBackToAFullReload() {
        val c = ChangeCollector(maxIds = 3)
        for (i in 1..4) c.add("$i", ChangeCollector.NOTIFY_INSERT)
        assertFalse(c.drain().incremental)
    }

    // Albums

    @Test
    fun albumsPutCameraAndScreenshotsFirst() {
        val albums = Albums.albums(
            listOf(
                Albums.Bucket("3", "WhatsApp Images", 4),
                Albums.Bucket("1", "Screenshots", 2),
                Albums.Bucket("2", "Camera", 10),
                Albums.Bucket("4", "Download", 1),
                Albums.Bucket("5", "Empty", 0),
                Albums.Bucket("6", null, 1),
            ),
        )
        assertEquals(listOf("2", "1", "6", "4", "3"), albums.map { it.albumId })
        assertEquals(listOf(PhotoAlbumKindMsg.SMART, PhotoAlbumKindMsg.SMART, PhotoAlbumKindMsg.USER, PhotoAlbumKindMsg.USER, PhotoAlbumKindMsg.USER), albums.map { it.kind })
        assertEquals(10L, albums[0].estimatedCount)
        assertEquals("", albums[2].title)
    }

    // EXIF dates

    @Test
    fun exifDatesWithAndWithoutOffset() {
        val utc = TimeZone.getTimeZone("UTC")
        assertEquals(1_700_000_000_000L, ExifDates.parse("2023:11:14 22:13:20", null, utc))
        assertEquals(1_700_000_000_000L, ExifDates.parse("2023:11:15 03:43:20", "+05:30", utc))
        assertEquals(1_700_000_000_000L, ExifDates.parse("2023:11:14 17:13:20", "-0500", utc))
        assertNull(ExifDates.parse("0000:00:00 00:00:00", null, utc))
        assertNull(ExifDates.parse("2023:02:30 10:00:00", null, utc))
        assertNull(ExifDates.parse("garbage", null, utc))
        assertNull(ExifDates.parse(null, "+01:00", utc))
    }

    // Naming

    @Test
    fun sanitizesNames() {
        assertEquals("a_b_c.jpg", CopyNaming.sanitize("a/b:c.jpg", "Photo.jpg"))
        assertEquals("hidden.jpg", CopyNaming.sanitize("..hidden.jpg", "Photo.jpg"))
        assertEquals("Photo.jpg", CopyNaming.sanitize("  ", "Photo.jpg"))
        assertEquals("Photo.jpg", CopyNaming.sanitize(null, "Photo.jpg"))
        assertEquals("x_y.png", CopyNaming.sanitize("x\\y.png", "Photo.jpg"))
        val long = CopyNaming.sanitize("n".repeat(300) + ".heic", "Photo.jpg")
        assertEquals(185, long.length)
        assertTrue(long.endsWith(".heic"))
    }

    @Test
    fun uniqueNamesNeverOverwrite() {
        val taken = setOf("/d/a.jpg", "/d/a (2).jpg", "/d/b")
        assertEquals("/d/c.jpg", CopyNaming.unique("/d/", "c.jpg") { it in taken })
        assertEquals("/d/a (3).jpg", CopyNaming.unique("/d", "a.jpg") { it in taken })
        assertEquals("/d/b (2)", CopyNaming.unique("/d", "b") { it in taken })
        assertNull(CopyNaming.unique("/d", "a.jpg") { true })
    }
}
