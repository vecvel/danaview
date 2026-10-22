// OWNER: AND-14
//
// The real pickers on the emulator (BUILD_PLAN AND-14, V-D2). Media is inserted into MediaStore /
// Downloads from the ENG-05 fixtures (alpha.png, frame_counter_720p24.mp4) or written by the test
// (a .cube LUT), so the system UI has something to show; UiAutomator answers the system UI. The
// service runs through a fragment relay (PlatformTestSupport) instead of the plugin's ActivityHost,
// because the library test APK has no Flutter activity.
//
// - photoPickerMultiPickPersistsGrants: MediaPicker → Photo Picker (multi select, image + video) →
//   two content:// items (origin photos, names, sizes) → persistUriGrant for both → listed in
//   persistedUriPermissions, the budget drops by two → stat and quickHash equal the inserted bytes.
//   The test taps the first two grid items, and the grid lists the newest first (date taken, else
//   date modified), so its two items are made the newest of the gallery: the video's MP4 creation
//   time (its date taken) and the image file's modification time are set one minute past the
//   newest item already there (QA-02's exports sorted first and the test picked them, AND-14).
// - safPickerReturnsCubeLut: MediaPicker (files, LUT) → DocumentsUI → the .cube from Downloads →
//   persisted, hashed, released.
// - V-D2 across a relaunch: with `-e danaviewRelaunchPhase pick` the photo test keeps its grants and
//   records the URIs and expected hashes in the app's files dir; after `am force-stop`, a second
//   instrumentation run (a new process) with `-e danaviewRelaunchPhase verify` runs
//   relaunchedProcessStillReadsPersistedPickerUris: the URIs are still persisted and readable,
//   their hashes are unchanged; then it releases them. In a normal connected run that test is skipped
//   (assumption) and the photo test releases its grants itself.

package com.vecvel.danaview.editor.engine.platform

import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import androidx.activity.result.contract.ActivityResultContracts
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.pigeon.MediaPickKindMsg
import com.vecvel.danaview.editor.engine.pigeon.MediaPickRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.MediaPickSourceMsg
import com.vecvel.danaview.editor.engine.pigeon.MediaRefMsg
import com.vecvel.danaview.editor.engine.pigeon.MediaStatMsg
import com.vecvel.danaview.editor.engine.pigeon.PickOriginMsg
import com.vecvel.danaview.editor.engine.pigeon.PickedMediaMsg
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class PickerFlowTest {
    companion object {
        private const val TAG = "DanaviewPickerTest"
        private lateinit var ctx: EngineContext

        @BeforeClass
        @JvmStatic
        fun setUpClass() {
            ctx = PlatformTestEngine.create()
        }

        @AfterClass
        @JvmStatic
        fun tearDownClass() {
            ctx.threads.shutdown()
        }
    }

    private val app get() = PlatformTestEngine.app
    private val resolver get() = app.contentResolver
    private val phase: String? get() = InstrumentationRegistry.getArguments().getString("danaviewRelaunchPhase")
    private val record get() = File(app.filesDir, "danaview_and14_relaunch.json")
    private lateinit var relay: FragmentRequests
    private lateinit var picker: MediaPicker
    private lateinit var access: MediaAccess
    private val inserted = ArrayList<Uri>()

    @Before
    fun setUp() {
        relay = FragmentRequests.launch()
        picker = MediaPicker(ctx).also { it.requests = relay }
        access = MediaAccess(ctx)
    }

    @After
    fun tearDown() {
        SystemUi.device.pressBack()
        relay.finish()
        if (phase != "pick") inserted.forEach { runCatching { resolver.delete(it, null, null) } }
    }

    private fun insert(collection: Uri, name: String, mime: String, relativeDir: String, bytes: ByteArray): Uri {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativeDir)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)!!
        resolver.openOutputStream(uri)!!.use { it.write(bytes) }
        resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        inserted += uri
        return uri
    }

    /** The newest date (date taken, else modified or added) of the gallery's images and videos, and never before now. */
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

    /** The date the Photo Picker sorts [uri] by: date taken, else date modified (ms). */
    private fun dateOf(uri: Uri): Long {
        val columns = arrayOf(MediaStore.Images.ImageColumns.DATE_TAKEN, MediaStore.MediaColumns.DATE_MODIFIED)
        return resolver.query(uri, columns, null, null, null)!!.use { c ->
            check(c.moveToFirst()) { "inserted item not found" }
            if (!c.isNull(0)) c.getLong(0) else c.getLong(1) * 1000
        }
    }

    /**
     * Dates the inserted image (a PNG has no date taken; MediaStore clears one set by the app when the
     * item is published) by its file's modification time: the app owns the file, sets the time and
     * MediaStore rescans it.
     */
    @Suppress("DEPRECATION")
    private fun setModifiedAndRescan(uri: Uri, ms: Long) {
        val path = resolver.query(uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null)!!.use { c ->
            check(c.moveToFirst()) { "inserted item not found" }
            c.getString(0)
        }
        assertTrue("modification time of the test image set", File(path).setLastModified(ms))
        val scanned = java.util.concurrent.CountDownLatch(1)
        android.media.MediaScannerConnection.scanFile(app, arrayOf(path), null) { _, _ -> scanned.countDown() }
        assertTrue("test image rescanned", scanned.await(15, java.util.concurrent.TimeUnit.SECONDS))
    }

    /**
     * [mp4] with its movie header's creation and modification times set to [epochSeconds] (MediaStore
     * reads the video's date taken from them); every other byte is unchanged.
     */
    private fun withMp4CreationTime(mp4: ByteArray, epochSeconds: Long): ByteArray {
        val out = mp4.copyOf()
        val mp4Seconds = epochSeconds + 2_082_844_800L // since 1904-01-01
        fun u32(at: Int) = ((out[at].toLong() and 0xFF) shl 24) or ((out[at + 1].toLong() and 0xFF) shl 16) or
            ((out[at + 2].toLong() and 0xFF) shl 8) or (out[at + 3].toLong() and 0xFF)
        fun put(at: Int, value: Long, bytes: Int) {
            for (i in 0 until bytes) out[at + i] = (value ushr (8 * (bytes - 1 - i))).toByte()
        }
        fun find(type: String, from: Int, to: Int): Int {
            var at = from
            while (at + 8 <= to) {
                val size = when (val s = u32(at)) {
                    1L -> (u32(at + 8) shl 32) or u32(at + 12) // 64-bit largesize
                    0L -> (to - at).toLong() // to the end
                    else -> s
                }
                if (String(out, at + 4, 4, Charsets.US_ASCII) == type) return at
                check(size >= 8) { "unsupported MP4 box size at $at" }
                at += size.toInt()
            }
            error("no $type box")
        }
        val moov = find("moov", 0, out.size)
        val mvhd = find("mvhd", moov + 8, moov + u32(moov).toInt())
        val version = out[mvhd + 8].toInt()
        if (version == 1) {
            put(mvhd + 12, mp4Seconds, 8)
            put(mvhd + 20, mp4Seconds, 8)
        } else {
            put(mvhd + 12, mp4Seconds, 4)
            put(mvhd + 16, mp4Seconds, 4)
        }
        return out
    }

    private fun hashOfBytes(bytes: ByteArray) = bytes.inputStream().use(MediaAccess::hashStream)

    private fun hash(uri: String) = awaitResult<String> { access.quickHash(MediaRefMsg(uri), it) }.getOrThrow()

    private fun stat(uri: String) = awaitResult<MediaStatMsg?> { access.stat(MediaRefMsg(uri), it) }.getOrThrow()

    private fun persisted(uri: String) = resolver.persistedUriPermissions.any { it.uri.toString() == uri && it.isReadPermission }

    @Test
    fun photoPickerMultiPickPersistsGrants() {
        assumeTrue("relaunch verify phase runs the other test", phase != "verify")
        val stamp = System.currentTimeMillis()
        val png = TestFixtures.open(FixtureTree.ENGINE, "media/alpha.png").use { it.readBytes() }
        val photoPicker = ActivityResultContracts.PickVisualMedia.isPhotoPickerAvailable(app)
        // The Photo Picker shows the newest first: the test's own items get the newest dates.
        val newestMs = if (photoPicker) newestGalleryDateMs() + 60_000 else 0L
        val fixtureMp4 = TestFixtures.open(FixtureTree.ENGINE, "media/frame_counter_720p24.mp4").use { it.readBytes() }
        val mp4 = if (photoPicker) withMp4CreationTime(fixtureMp4, newestMs / 1000) else fixtureMp4
        if (photoPicker) {
            val image = insert(MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), "dv_pick_$stamp.png", "image/png", "Pictures/DanaviewTest", png)
            val video = insert(MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), "dv_pick_$stamp.mp4", "video/mp4", "Movies/DanaviewTest", mp4)
            setModifiedAndRescan(image, newestMs)
            assertTrue("the video is dated after every other gallery item", dateOf(video) >= newestMs - 1_000)
            assertTrue("the image is dated after every other gallery item", dateOf(image) >= newestMs - 1_000)
        } else {
            // DocumentsUI's Recent hides the app's own media: both go to Downloads, one folder.
            val downloads = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            insert(downloads, "dv_pick_$stamp.png", "image/png", "Download/", png)
            insert(downloads, "dv_pick_$stamp.mp4", "video/mp4", "Download/", mp4)
        }
        Thread.sleep(1_000)

        val pending = startOnMain<List<PickedMediaMsg>> {
            picker.pick(MediaPickRequestMsg(MediaPickSourceMsg.PHOTOS, listOf(MediaPickKindMsg.VIDEO, MediaPickKindMsg.IMAGE), multiple = true), it)
        }
        if (photoPicker) {
            selectInPhotoPicker(2)
        } else {
            // Documented fallback (API 29 emulator: no platform picker, no Play backport):
            // ACTION_OPEN_DOCUMENT in DocumentsUI with the visual MIME types.
            selectSeveralInDocumentsUi(listOf("dv_pick_$stamp.png", "dv_pick_$stamp.mp4"))
        }
        val items = pending.await(30_000).getOrThrow()
        Log.i(TAG, "photo picker (API ${Build.VERSION.SDK_INT}) returned ${items.size} item(s): ${items.map { it.uri.substringBefore("/picker").take(40) }}")
        assertEquals(2, items.size)
        val budgetBefore = awaitResult<Long> { access.remainingGrantBudget(it) }.getOrThrow()
        val expected = mapOf(png.size.toLong() to hashOfBytes(png), mp4.size.toLong() to hashOfBytes(mp4))
        for (item in items) {
            assertTrue(item.uri.startsWith("content://"))
            assertEquals("photos origin also on the fallback", PickOriginMsg.PHOTOS, item.origin)
            assertFalse(item.isTemporaryCopy)
            assertTrue(item.displayName.isNotEmpty())
            assertNotNull(item.sizeBytes)
            awaitResult<Unit> { access.persistUriGrant(item.uri, it) }.getOrThrow()
            assertTrue("grant persisted", persisted(item.uri))
            val s = stat(item.uri)!!
            assertEquals(item.sizeBytes, s.sizeBytes)
            assertEquals("quickHash of the picked item", expected.getValue(s.sizeBytes), hash(item.uri))
        }
        // Persisting again is idempotent.
        awaitResult<Unit> { access.persistUriGrant(items[0].uri, it) }.getOrThrow()
        assertEquals(budgetBefore - 2, awaitResult<Long> { access.remainingGrantBudget(it) }.getOrThrow())

        if (phase == "pick") {
            val arr = JSONArray()
            items.forEach { arr.put(JSONObject().put("uri", it.uri).put("hash", hash(it.uri)).put("size", it.sizeBytes)) }
            val ins = JSONArray().also { a -> inserted.forEach { a.put(it.toString()) } }
            record.writeText(JSONObject().put("items", arr).put("inserted", ins).toString())
            Log.i(TAG, "V-D2 pick phase: ${items.size} grants persisted and recorded")
        } else {
            items.forEach { item -> awaitResult<Unit> { access.releaseUriGrant(item.uri, it) }.getOrThrow() }
            items.forEach { assertFalse("released", persisted(it.uri)) }
            assertEquals(budgetBefore, awaitResult<Long> { access.remainingGrantBudget(it) }.getOrThrow())
        }
    }

    @Test
    fun relaunchedProcessStillReadsPersistedPickerUris() {
        assumeTrue("run with -e danaviewRelaunchPhase verify after the pick phase and am force-stop", phase == "verify")
        val doc = JSONObject(record.readText())
        val items = doc.getJSONArray("items")
        assertEquals(2, items.length())
        for (i in 0 until items.length()) {
            val o = items.getJSONObject(i)
            val uri = o.getString("uri")
            assertTrue("still persisted after relaunch", persisted(uri))
            assertEquals(o.getLong("size"), stat(uri)!!.sizeBytes)
            assertEquals(o.getString("hash"), hash(uri))
            awaitResult<Unit> { access.releaseUriGrant(uri, it) }.getOrThrow()
            assertFalse(persisted(uri))
        }
        val ins = doc.getJSONArray("inserted")
        for (i in 0 until ins.length()) runCatching { resolver.delete(Uri.parse(ins.getString(i)), null, null) }
        record.delete()
        Log.i(TAG, "V-D2 verify phase (new process, API ${Build.VERSION.SDK_INT}): ${items.length()} picker URIs still persisted and readable")
    }

    @Test
    fun safPickerReturnsCubeLut() {
        assumeTrue(phase == null)
        val name = "dv_lut_${System.currentTimeMillis()}.cube"
        val cube = "TITLE \"test\"\nLUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".toByteArray()
        insert(MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), name, "application/octet-stream", "Download/", cube)
        Thread.sleep(500)
        val pending = startOnMain<List<PickedMediaMsg>> {
            picker.pick(MediaPickRequestMsg(MediaPickSourceMsg.FILES, listOf(MediaPickKindMsg.LUT), multiple = false), it)
        }
        selectInDocumentsUi(name)
        val items = pending.await(30_000).getOrThrow()
        assertEquals(1, items.size)
        val item = items[0]
        assertEquals(name, item.displayName)
        assertEquals(PickOriginMsg.FILES, item.origin)
        assertEquals(cube.size.toLong(), item.sizeBytes)
        awaitResult<Unit> { access.persistUriGrant(item.uri, it) }.getOrThrow()
        assertTrue(persisted(item.uri))
        assertEquals(hashOfBytes(cube), hash(item.uri))
        awaitResult<Unit> { access.releaseUriGrant(item.uri, it) }.getOrThrow()
        assertFalse(persisted(item.uri))
    }

    @Test
    fun cancelledPickerReturnsEmptyList() {
        assumeTrue(phase == null)
        val pending = startOnMain<List<PickedMediaMsg>> {
            picker.pick(MediaPickRequestMsg(MediaPickSourceMsg.PHOTOS, listOf(MediaPickKindMsg.IMAGE), multiple = false), it)
        }
        Thread.sleep(2_500)
        SystemUi.device.pressBack()
        assertEquals(emptyList<PickedMediaMsg>(), pending.await(15_000).getOrThrow())
    }

    /** Selects the [count] newest items of the Photo Picker grid and confirms. */
    private fun selectInPhotoPicker(count: Int) {
        val thumbs = SystemUi.waitAny(15_000, SystemUi.byRes(".*:id/icon_thumbnail"))
        if (thumbs == null) error("no picker grid:\n" + SystemUi.dump())
        val all = SystemUi.device.findObjects(androidx.test.uiautomator.By.res(java.util.regex.Pattern.compile(".*:id/icon_thumbnail")))
        check(all.size >= count) { "picker shows ${all.size} item(s):\n" + SystemUi.dump() }
        for (i in 0 until count) {
            all[i].click()
            Thread.sleep(400)
        }
        val add = SystemUi.waitAny(5_000, SystemUi.byRes(".*:id/button_add"), SystemUi.byText("(?i)^add.*"))
            ?: error("no Add button:\n" + SystemUi.dump())
        add.click()
    }

    /** Multi-selects [names] in DocumentsUI (long press, tap, Select). */
    private fun selectSeveralInDocumentsUi(names: List<String>) {
        openDownloadsIfNeeded(names[0])
        val first = SystemUi.waitAny(10_000, SystemUi.byText(java.util.regex.Pattern.quote(names[0])))
            ?: error("${names[0]} not listed:\n" + SystemUi.dump())
        first.longClick()
        Thread.sleep(600)
        for (name in names.drop(1)) {
            (SystemUi.waitAny(5_000, SystemUi.byText(java.util.regex.Pattern.quote(name))) ?: error("$name not listed:\n" + SystemUi.dump())).click()
            Thread.sleep(400)
        }
        val select = SystemUi.waitAny(5_000, SystemUi.byRes(".*:id/action_menu_select"), SystemUi.byText("(?i)^select$"))
            ?: error("no Select action:\n" + SystemUi.dump())
        select.click()
    }

    /** Opens the Downloads root in DocumentsUI unless [name] is already listed. */
    private fun openDownloadsIfNeeded(name: String) {
        if (SystemUi.waitAny(6_000, SystemUi.byText(java.util.regex.Pattern.quote(name))) != null) return
        val roots = SystemUi.waitAny(5_000, SystemUi.byDesc("(?i)show roots")) ?: error("no roots button:\n" + SystemUi.dump())
        roots.click()
        val downloads = SystemUi.waitAny(5_000, SystemUi.byText("(?i)^downloads?$")) ?: error("no Downloads root:\n" + SystemUi.dump())
        downloads.click()
    }

    /** Opens Downloads in DocumentsUI and picks [name]. */
    private fun selectInDocumentsUi(name: String) {
        openDownloadsIfNeeded(name)
        val file = SystemUi.waitAny(10_000, SystemUi.byText(java.util.regex.Pattern.quote(name))) ?: error("file not listed:\n" + SystemUi.dump())
        file.click()
    }
}
