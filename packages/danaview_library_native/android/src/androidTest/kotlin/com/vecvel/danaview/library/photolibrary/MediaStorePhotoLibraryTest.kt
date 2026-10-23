// OWNER: HOM-02A
//
// Emulator tests of the MediaStore library (BUILD_PLAN HOM-02A: API 35 and 29 with seeded media):
// paging with change tokens, filters and albums (photo buckets only, OBS-S2A-3), assets by id, EXIF detail, create-new copies,
// change events on add and delete, and the access states including Android 14+ partial access
// (granted for real with UiAutomation; the test APK is installed fresh by connectedAndroidTest, so
// nothing is granted when the first test, in name order, runs).

package com.vecvel.danaview.library.photolibrary

import android.app.UiAutomation
import android.content.Context
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.library.pigeon.LibraryPigeonError
import com.vecvel.danaview.library.pigeon.PhotoAlbumKindMsg
import com.vecvel.danaview.library.pigeon.PhotoAssetKindMsg
import com.vecvel.danaview.library.pigeon.PhotoAuthorizationMsg
import com.vecvel.danaview.library.pigeon.PhotoCopyRequestMsg
import com.vecvel.danaview.library.pigeon.PhotoFetchRequestMsg
import com.vecvel.danaview.library.pigeon.PhotoLibraryChangeMsg
import com.vecvel.danaview.library.pigeon.PhotoMediaFilterMsg
import com.vecvel.danaview.library.pigeon.PhotoSortMsg
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.MethodSorters
import java.io.File
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class MediaStorePhotoLibraryTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val automation: UiAutomation = InstrumentationRegistry.getInstrumentation().uiAutomation
    private val sdk = Build.VERSION.SDK_INT
    private lateinit var seed: SeededMedia
    private val changes = LinkedBlockingQueue<PhotoLibraryChangeMsg>()
    private val authorizations = LinkedBlockingQueue<PhotoAuthorizationMsg>()
    private val progress = LinkedBlockingQueue<Pair<String, Long>>()
    private val events = object : PhotoLibraryEvents {
        override fun libraryChanged(change: PhotoLibraryChangeMsg) {
            changes.add(change)
        }

        override fun authorizationChanged(status: PhotoAuthorizationMsg) {
            authorizations.add(status)
        }

        override fun copyProgress(requestId: String, bytesDone: Long, bytesTotal: Long?) {
            progress.add(requestId to bytesDone)
        }
    }
    private lateinit var library: MediaStorePhotoLibrary
    private var partialAccessExercised = false
    private val copyDir by lazy { File(context.cacheDir, "copy-test").apply { deleteRecursively(); mkdirs() } }

    @Before
    fun setUp() {
        assumeTrue("seeding needs MediaStore RELATIVE_PATH (API 29+)", sdk >= 29)
        seed = SeededMedia(context)
        library = MediaStorePhotoLibrary(context, events, changeDelayMs = 150)
    }

    @After
    fun tearDown() {
        if (!::seed.isInitialized) return
        library.stopObserving()
        seed.deleteAll()
        copyDir.deleteRecursively()
    }

    private fun grant(vararg permissions: String) {
        for (p in permissions) automation.grantRuntimePermission(context.packageName, p)
    }

    private fun grantFull() = grant(*PhotoPermissions.toRequest(sdk).filter { it != PhotoPermissions.READ_MEDIA_VISUAL_USER_SELECTED }.toTypedArray())

    private fun page(filter: PhotoMediaFilterMsg, album: String?, offset: Long, limit: Long, token: String? = null, sort: PhotoSortMsg = PhotoSortMsg.CREATION_NEWEST_FIRST) =
        library.fetchPage(PhotoFetchRequestMsg(filter, sort, album, offset, limit, token))

    private fun code(block: () -> Unit): String = try {
        block()
        fail("no error")
        ""
    } catch (e: LibraryPigeonError) {
        e.code
    }

    /** Five photos one hour apart (newest last) and one video, in one fresh bucket. */
    private fun seedAlbum(): Pair<List<Long>, String> {
        val ids = (1..5).map { seed.addPhoto("seed_$it.jpg", "2024:05:0$it 10:00:00") } + seed.addVideo("seed_clip.mp4")
        return ids to seed.bucketId(ids[0])
    }

    // Runs first (name order): nothing is granted yet on a fresh install.
    @Test
    fun a1_accessStatesWithoutAndWithPartialAccess() {
        val noAccess = MediaStorePhotoLibrary(context, events, granted = { false })
        assertEquals(PhotoAuthorizationMsg.NOT_DETERMINED, noAccess.authorizationStatus())
        assertEquals("permissionDenied", code { noAccess.fetchPage(PhotoFetchRequestMsg(PhotoMediaFilterMsg.ALL, PhotoSortMsg.CREATION_NEWEST_FIRST, null, 0, 10, null)) })
        assertEquals("permissionDenied", code { noAccess.fetchAlbums() })

        // Only meaningful while nothing is granted yet (an install with -g grants everything).
        if (sdk >= 34 && !PhotoPermissions.canRead(library.authorizationStatus())) {
            partialAccessExercised = true
            library.noteAuthorization()
            grant(PhotoPermissions.READ_MEDIA_VISUAL_USER_SELECTED)
            assertEquals(PhotoAuthorizationMsg.LIMITED, library.authorizationStatus())
            library.noteAuthorization()
            assertEquals(PhotoAuthorizationMsg.LIMITED, authorizations.poll(1, TimeUnit.SECONDS))
            // Partial access still lists what the app may see (here: its own media).
            val (ids, album) = seedAlbum()
            val p = page(PhotoMediaFilterMsg.ALL, album, 0, 50)
            assertEquals(ids.size.toLong(), p.totalCount)
        }
        grantFull()
        assertEquals(PhotoAuthorizationMsg.AUTHORIZED, library.authorizationStatus())
        android.util.Log.i("MediaStorePhotoLibraryTest", if (partialAccessExercised) "partial access exercised" else "partial access skipped")
    }

    @Test
    fun b1_pagesAnAlbumNewestFirstWithoutOverlap() {
        grantFull()
        val (ids, album) = seedAlbum()
        val token = library.currentToken()
        val seen = ArrayList<String>()
        var offset = 0L
        while (true) {
            val p = page(PhotoMediaFilterMsg.ALL, album, offset, 2, token)
            assertEquals(6L, p.totalCount)
            assertEquals(offset, p.offset)
            assertEquals(token, p.changeToken)
            assertFalse(p.tokenStale)
            if (p.assets.isEmpty()) break
            assertTrue(p.assets.size <= 2)
            seen += p.assets.map { it.localIdentifier }
            offset += p.assets.size
        }
        assertEquals(ids.map { it.toString() }.toSet(), seen.toSet())
        assertEquals(seen.size, seen.toSet().size)
        val all = page(PhotoMediaFilterMsg.PHOTOS, album, 0, 10).assets
        assertEquals((5 downTo 1).map { ids[it - 1].toString() }, all.map { it.localIdentifier })
        val times = all.map { it.creationTimeMs!! }
        assertEquals(times.sortedDescending(), times)
        // API 30+'s scanner reads DateTimeOriginal with OffsetTimeOriginal; API 29's ignores the offset.
        if (sdk >= 30) assertEquals(1714557600000L, times.last()) // 2024-05-01 10:00:00 UTC
        val oldest = page(PhotoMediaFilterMsg.PHOTOS, album, 0, 1, sort = PhotoSortMsg.CREATION_OLDEST_FIRST).assets.single()
        assertEquals(ids[0].toString(), oldest.localIdentifier)
        assertEquals(1L, page(PhotoMediaFilterMsg.ALL, album, 5, 500).assets.size.toLong())
        assertTrue(page(PhotoMediaFilterMsg.ALL, album, 99, 10).assets.isEmpty())
    }

    @Test
    fun b2_photoAndVideoFields() {
        grantFull()
        val (ids, album) = seedAlbum()
        val photo = page(PhotoMediaFilterMsg.PHOTOS, album, 0, 1).assets.single()
        assertEquals(PhotoAssetKindMsg.PHOTO, photo.kind)
        assertEquals(64L, photo.widthPx)
        assertEquals(48L, photo.heightPx)
        assertEquals("image/jpeg", photo.mimeType)
        assertEquals("seed_5.jpg", photo.originalFilename)
        assertTrue(photo.sizeBytes!! > 0)
        assertFalse(photo.isRaw || photo.isLivePhoto || photo.isScreenshot)
        val video = page(PhotoMediaFilterMsg.VIDEOS, album, 0, 10).assets.single()
        assertEquals(ids.last().toString(), video.localIdentifier)
        assertEquals(PhotoAssetKindMsg.VIDEO, video.kind)
        assertEquals(160L, video.widthPx)
        assertEquals(120L, video.heightPx)
        assertTrue("duration ${video.durationMs}", video.durationMs in 500L..1500L)
        assertEquals("video/mp4", video.mimeType)
    }

    @Test
    fun b3_tokenGoesStaleWhenTheLibraryChanges() {
        grantFull()
        val (ids, album) = seedAlbum()
        val first = page(PhotoMediaFilterMsg.ALL, album, 0, 2)
        val added = seed.addPhoto("seed_new.jpg", "2024:06:01 10:00:00")
        val second = page(PhotoMediaFilterMsg.ALL, album, 2, 2, first.changeToken)
        assertTrue(second.tokenStale)
        assertNotEquals(first.changeToken, second.changeToken)
        assertEquals(7L, second.totalCount)
        seed.delete(added)
        seed.delete(ids[0])
        val third = page(PhotoMediaFilterMsg.ALL, album, 0, 2, second.changeToken)
        assertTrue(third.tokenStale)
        assertEquals(5L, third.totalCount)
    }

    @Test
    fun b4_unknownAlbumAndBadWindows() {
        grantFull()
        assertEquals("notFound", code { page(PhotoMediaFilterMsg.ALL, "123456789", 0, 10) })
        assertEquals("notFound", code { page(PhotoMediaFilterMsg.ALL, "not-a-bucket", 0, 10) })
        assertEquals("invalidArgument", code { page(PhotoMediaFilterMsg.ALL, null, -1, 10) })
        assertEquals("invalidArgument", code { page(PhotoMediaFilterMsg.ALL, null, 0, 0) })
    }

    @Test
    fun c1_assetsByIdKeepTheOrderAndSkipUnknownIds() {
        grantFull()
        val (ids, _) = seedAlbum()
        val got = library.fetchAssets(listOf(ids[2].toString(), "999999999", "x", ids[0].toString(), ids[5].toString()))
        assertEquals(listOf(ids[2], ids[0], ids[5]).map { it.toString() }, got.map { it.localIdentifier })
    }

    @Test
    fun c2_albumsListTheSeedFolder() {
        grantFull()
        val (_, album) = seedAlbum()
        // OBS-S2A-3: a second folder holding only a video is no album (it belongs in Videos).
        val videoOnly = SeededMedia(context)
        try {
            val clip = videoOnly.addVideo("only_clip.mp4")
            val videoBucket = videoOnly.bucketId(clip)
            val albums = library.fetchAlbums()
            val seeded = albums.single { it.albumId == album }
            // Five photos and one video: the album counts its photos.
            assertEquals(5L, seeded.estimatedCount)
            assertEquals(PhotoAlbumKindMsg.USER, seeded.kind)
            assertEquals(seed.folder.trimEnd('/').substringAfterLast('/'), seeded.title)
            assertTrue("video-only bucket listed", albums.none { it.albumId == videoBucket })
            // Its video is still in the library (the Videos filter of that bucket).
            assertEquals(1L, page(PhotoMediaFilterMsg.VIDEOS, videoBucket, 0, 10).totalCount)
        } finally {
            videoOnly.deleteAll()
        }
    }

    @Test
    fun c3_detailReadsExifWithoutLocation() {
        grantFull()
        val (ids, _) = seedAlbum()
        val d = library.assetDetail(ids[1].toString())
        assertEquals(ids[1].toString(), d.localIdentifier)
        assertEquals("DanaviewTest", d.cameraMake)
        assertEquals("Seed Cam 1", d.cameraModel)
        assertEquals("Seed Lens 24mm", d.lensModel)
        assertEquals(200L, d.iso)
        assertEquals(1.8, d.aperture!!, 0.001)
        assertEquals(0.01, d.exposureSeconds!!, 0.0001)
        assertEquals(24.0, d.focalLengthMm!!, 0.001)
        assertEquals(1714644000000L, d.takenAtMs) // 2024-05-02 10:00:00 UTC (EXIF with its offset)
        assertNull(d.latitude)
        assertNull(d.longitude)
        assertTrue(d.locallyAvailable)
        assertFalse(d.isRaw || d.isHdr || d.isLivePhoto)
        assertEquals("image/jpeg", d.mimeType)
        assertEquals("seed_2.jpg", d.originalFilename)
        if (sdk >= 26) {
            assertEquals("sRGB IEC61966-2.1", d.colorProfile)
            assertEquals(8L, d.bitDepth)
        }
        val v = library.assetDetail(ids[5].toString())
        assertFalse(v.isHdr)
        assertNull(v.cameraMake)
        assertEquals("notFound", code { library.assetDetail("999999999") })
    }

    @Test
    fun d1_copiesAreCreateNewAndByteForByte() {
        grantFull()
        val (ids, _) = seedAlbum()
        val id = ids[3].toString()
        val first = library.copyAsset(PhotoCopyRequestMsg("r1", id, copyDir.path, false))
        val second = library.copyAsset(PhotoCopyRequestMsg("r2", id, copyDir.path, false))
        assertEquals(File(copyDir, "seed_4.jpg").path, first.path)
        assertEquals(File(copyDir, "seed_4 (2).jpg").path, second.path)
        val original = context.contentResolver.openInputStream(
            android.content.ContentUris.withAppendedId(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, ids[3]),
        )!!.use { it.readBytes() }
        assertArrayEquals(original, File(first.path).readBytes())
        assertEquals(original.size.toLong(), first.sizeBytes)
        assertEquals("image/jpeg", first.mimeType)
        assertTrue(progress.any { it.first == "r1" && it.second == original.size.toLong() })

        val video = library.copyAsset(PhotoCopyRequestMsg("r3", ids[5].toString(), copyDir.path, false))
        assertEquals("seed_clip.mp4", File(video.path).name)
        assertEquals("video/mp4", video.mimeType)

        assertEquals("notFound", code { library.copyAsset(PhotoCopyRequestMsg("r4", id, copyDir.path, true)) })
        assertEquals("notFound", code { library.copyAsset(PhotoCopyRequestMsg("r5", "999999999", copyDir.path, false)) })
        assertEquals("invalidArgument", code { library.copyAsset(PhotoCopyRequestMsg("r6", id, File(copyDir, "missing").path, false)) })
        library.cancelCopy("not-running") // no effect
        assertEquals(3, copyDir.listFiles()!!.size)
    }

    @Test
    fun e1_changeEventsOnAddAndDelete() {
        grantFull()
        val (ids, _) = seedAlbum()
        library.startObserving()
        val before = library.currentToken()
        changes.clear()

        val added = seed.addPhoto("seed_live.jpg", "2024:07:01 10:00:00")
        val insert = waitForChange { it.changeToken != before }
        assertNotNull("no change event after an insert", insert)
        if (sdk >= 30) {
            assertTrue(insert!!.incremental)
            assertTrue("inserted ${insert.inserted}", added.toString() in insert.inserted)
        } else {
            assertFalse(insert!!.incremental)
        }

        val afterInsert = library.currentToken()
        changes.clear()
        seed.delete(ids[0])
        val delete = waitForChange { it.changeToken != afterInsert }
        assertNotNull("no change event after a delete", delete)
        if (sdk >= 30) assertTrue("removed ${delete!!.removed}", ids[0].toString() in delete.removed)

        library.stopObserving()
        changes.clear()
        seed.delete(added)
        assertNull(changes.poll(1, TimeUnit.SECONDS))
    }

    private fun waitForChange(match: (PhotoLibraryChangeMsg) -> Boolean): PhotoLibraryChangeMsg? {
        val deadline = System.currentTimeMillis() + 10_000
        while (System.currentTimeMillis() < deadline) {
            val c = changes.poll(500, TimeUnit.MILLISECONDS) ?: continue
            if (match(c)) return c
        }
        return null
    }
}
