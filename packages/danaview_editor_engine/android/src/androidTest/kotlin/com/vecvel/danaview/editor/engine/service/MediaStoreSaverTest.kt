// OWNER: AND-12
//
// MediaStoreSaver on the emulator (BUILD_PLAN AND-12; ARCH §14.3): saveToPhotos inserts a
// MediaStore.Video item under Movies/Danaview whose IS_PENDING is cleared and whose bytes equal the
// export (verified with MediaStore queries, the way a gallery lists it); a missing file answers
// mediaOffline and leaves no row behind. photosAppOpensTheInsert hands the item to the Photos app
// (ACTION_VIEW) and records a screenshot under the test app's files dir as visual evidence; it is
// skipped where the emulator image has no Photos app.

package com.vecvel.danaview.editor.engine.service

import android.content.Intent
import android.net.Uri
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Until
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.pigeon.FileHandoffOutcomeMsg
import com.vecvel.danaview.editor.engine.pigeon.FileHandoffResultMsg
import com.vecvel.danaview.editor.engine.platform.PlatformTestEngine
import com.vecvel.danaview.editor.engine.platform.SystemUi
import com.vecvel.danaview.editor.engine.platform.awaitResult
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class MediaStoreSaverTest {
    private lateinit var ctx: EngineContext
    private val inserted = ArrayList<Uri>()

    @Before
    fun setUp() {
        ctx = PlatformTestEngine.create()
    }

    @After
    fun tearDown() {
        inserted.forEach(ServiceTest::deleteGallery)
        ctx.threads.shutdown()
    }

    private fun source(name: String): File {
        val dir = File(ctx.requirePaths().work, "and12-gallery").apply { mkdirs() }
        val out = File(dir, name)
        TestFixtures.copyToCache(FixtureTree.ENGINE, "media/frame_counter_720p24.mp4").copyTo(out, overwrite = true)
        return out
    }

    private fun save(path: String): Result<FileHandoffResultMsg> = awaitResult { done -> ctx.threads.io.execute { ctx.mediaStore.saveToPhotos(path, done) } }

    @Test
    fun saveToPhotosPublishesUnderMoviesDanaview() {
        val file = source("and12_gallery_${System.currentTimeMillis()}.mp4")
        val r = save(file.absolutePath).getOrThrow()
        assertEquals(FileHandoffOutcomeMsg.DONE, r.outcome)
        val uri = Uri.parse(r.savedUri!!)
        inserted += uri
        val row = ServiceTest.galleryRow(uri)
        assertNotNull(row)
        Log.i(SERVICE_TEST_TAG, "saveToPhotos row: $row")
        assertEquals("Movies/Danaview/", row!!.relativePath)
        assertEquals(0, row.pending)
        assertEquals(file.name, row.name)
        assertEquals("video/mp4", row.mime)
        assertEquals(file.length(), row.size)
        assertTrue("listed in the collection", ServiceTest.galleryIds().contains(row.id))
        val bytes = ServiceTest.app.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
        assertArrayEquals(file.readBytes(), bytes)
    }

    @Test
    fun missingFileAnswersMediaOfflineAndLeavesNoRow() {
        val before = ServiceTest.galleryIds().toSet()
        val r = save(File(ctx.requirePaths().work, "and12-gallery/missing.mp4").absolutePath)
        assertTrue(r.isFailure)
        assertEquals("mediaOffline", (r.exceptionOrNull() as com.vecvel.danaview.editor.engine.core.EngineException).code.name)
        assertEquals(before, ServiceTest.galleryIds().toSet())
    }

    @Test
    fun photosAppOpensTheInsert() {
        val photos = "com.google.android.apps.photos"
        assumeTrue("no Photos app on this emulator image", ServiceTest.installed(photos))
        val file = source("and12_photos_${System.currentTimeMillis()}.mp4")
        val uri = Uri.parse(save(file.absolutePath).getOrThrow().savedUri!!)
        inserted += uri
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, "video/mp4").setPackage(photos)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        ServiceTest.app.startActivity(view)
        val device = SystemUi.device
        assertTrue("Photos shows the item", device.wait(Until.hasObject(By.pkg(photos)), 20_000))
        Thread.sleep(4_000)
        val shot = File(ServiceTest.app.filesDir, "and12_photos.png")
        device.takeScreenshot(shot)
        Log.i(SERVICE_TEST_TAG, "Photos opened the gallery insert; screenshot ${shot.name} (${shot.length()} bytes); window:\n" + SystemUi.dump().lines().take(40).joinToString("\n"))
        device.pressBack()
        device.pressHome()
    }
}
