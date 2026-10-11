// OWNER: AND-03
//
// DiskCache on the JVM with real temporary directories: LRU by access time, caps, pinning, trim
// levels, clear refused while active, and the work/ launch wipe with the IOS-03 exemptions.

package com.vecvel.vwish.editor.engine.thumbs

import com.vecvel.vwish.editor.engine.core.Paths
import com.vecvel.vwish.editor.engine.media.CacheStore
import com.vecvel.vwish.editor.engine.media.DiskCache
import com.vecvel.vwish.editor.engine.media.WorkExemptions
import com.vecvel.vwish.editor.engine.pigeon.CacheTrimLevelMsg
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class DiskCacheTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var paths: Paths
    private val now = 1_800_000_000_000L

    @Before
    fun setUp() {
        val root = temp.newFolder("app")
        paths = Paths.fromDart(File(root, "cache/vwish/editor").absolutePath, File(root, "files/vwish/editor").absolutePath)
        assertTrue(paths.ensureRoots())
    }

    @After
    fun tearDown() {
        while (DiskCache.isActive) DiskCache.endActivity()
        DiskCache.activeWorkPaths.forEach { DiskCache.unmarkActive(File(it)) }
    }

    private fun bytes(n: Int) = ByteArray(n) { (it % 251).toByte() }

    @Test
    fun lruEvictsTheLeastRecentlyAccessedFileFirst() {
        val store = CacheStore(File(temp.newFolder(), "thumbs"), capBytes = 300)
        store.write(bytes(100), "a", "vwth", nowMs = now)
        store.write(bytes(100), "b", "vwth", nowMs = now + 1_000)
        store.write(bytes(100), "c", "vwth", nowMs = now + 2_000)
        // A hit on "a" makes it the most recently used.
        assertTrue(store.read("a", "vwth", nowMs = now + 3_000)!!.size == 100)
        store.write(bytes(100), "d", "vwth", nowMs = now + 4_000)
        assertNull("b was least recently used", store.lookup("b", "vwth"))
        assertTrue(store.file("a", "vwth").isFile)
        assertTrue(store.file("c", "vwth").isFile)
        assertTrue(store.file("d", "vwth").isFile)
        assertTrue(store.totalBytes <= 300)
    }

    @Test
    fun capIsEnforcedOnEveryWrite() {
        val store = CacheStore(File(temp.newFolder(), "waves"), capBytes = 1_000)
        for (i in 0 until 50) store.write(bytes(97), "k$i", "vwpk", nowMs = now + i)
        assertTrue(store.totalBytes <= 1_000)
        assertEquals(10, store.entries().size)
        // The newest ten survive.
        assertEquals((40 until 50).map { "k$it.vwpk" }.toSet(), store.entries().map { it.file.name }.toSet())
    }

    @Test
    fun pinnedFilesAreNeverEvicted() {
        val store = CacheStore(File(temp.newFolder(), "thumbs"), capBytes = 150)
        val pinned = store.write(bytes(100), "old", "vwth", nowMs = now)
        store.pin(pinned)
        store.pin(pinned)
        store.write(bytes(100), "new", "vwth", nowMs = now + 1_000)
        assertTrue("pinned survives the cap", pinned.isFile)
        assertFalse(store.file("new", "vwth").isFile)
        store.unpin(pinned)
        assertTrue("still pinned once", store.isPinned(pinned))
        store.unpin(pinned)
        assertFalse(store.isPinned(pinned))
        store.evict(0)
        assertFalse(pinned.isFile)
    }

    @Test
    fun keysAreSanitisedOrHashed() {
        assertEquals("abc-1.2_x", CacheStore.fileName("abc-1.2_x"))
        assertEquals(32, CacheStore.fileName("../etc/passwd").length)
        assertEquals(32, CacheStore.fileName(".hidden").length)
        assertEquals(32, CacheStore.fileName("x".repeat(121)).length)
    }

    @Test
    fun stableHashMatchesIos() {
        // Vectors computed with the iOS algorithm (128-bit FNV-1a style, CacheStore.stableHash).
        assertEquals("cbf29ce48422232584222325cbf29ce4", CacheStore.stableHash(""))
        assertEquals("a430d84680aabd0b36a9160f2bd5656b", CacheStore.stableHash("hello"))
        assertEquals("57f7fa2ac1029b392e7486222edc807f", CacheStore.stableHash("fp-1|1000|180|0|8|0"))
    }

    @Test
    fun trimBackgroundHalvesTheCapsAndMemoryPressureKeepsFiles() {
        val stores = DiskCache.stores(paths)
        stores.thumbs.capBytes = 400
        for (i in 0 until 4) stores.thumbs.write(bytes(100), "t$i", "vwth", nowMs = now + i)
        assertTrue(DiskCache.trim(CacheTrimLevelMsg.MEMORY_PRESSURE, paths))
        assertEquals(400L, stores.thumbs.totalBytes)
        assertTrue(DiskCache.trim(CacheTrimLevelMsg.BACKGROUND, paths))
        assertEquals(200L, stores.thumbs.totalBytes)
        stores.thumbs.capBytes = DiskCache.THUMBS_CAP
    }

    @Test
    fun clearAllIsRefusedWhileASessionOrJobIsActive() {
        val stores = DiskCache.stores(paths)
        stores.waves.write(bytes(10), "w", "vwpk")
        stores.proxies.write(bytes(10), "fp-540", "mp4")
        DiskCache.beginActivity()
        assertFalse(DiskCache.trim(CacheTrimLevelMsg.CLEAR_ALL, paths))
        assertTrue(stores.waves.file("w", "vwpk").isFile)
        DiskCache.endActivity()
        assertTrue(DiskCache.trim(CacheTrimLevelMsg.CLEAR_ALL, paths))
        assertFalse(stores.waves.file("w", "vwpk").isFile)
        assertFalse("clear includes proxies", stores.proxies.file("fp-540", "mp4").isFile)
    }

    @Test
    fun capsMatchTheArchitecture() {
        val mb = 1024L * 1024L
        assertEquals(300 * mb, DiskCache.THUMBS_CAP)
        assertEquals(64 * mb, DiskCache.WAVES_CAP)
        assertEquals(400 * mb, DiskCache.SPRITES_CAP)
        val stores = DiskCache.stores(paths)
        assertEquals(stores, DiskCache.stores(Paths.fromDart(paths.cacheRoot.path, paths.supportRoot.path)))
        assertEquals(stores.thumbs, stores.owning(stores.thumbs.file("x", "vwth")))
        assertNull(stores.owning(File(paths.work, "x.mp4")))
    }

    // ---- work/ wipe ----

    private fun workFile(relative: String, modifiedMs: Long = now): File {
        val f = File(paths.work, relative)
        f.parentFile!!.mkdirs()
        f.writeBytes(bytes(8))
        f.setLastModified(modifiedMs)
        return f
    }

    @Test
    fun launchWipeKeepsActiveAndExemptFiles() {
        val stale = workFile("export-old/out.mp4.part")
        val strayFile = workFile("loose.tmp")
        val active = workFile("reverse-job/chunk-0.mp4")
        val detached = workFile("export-123/out.mp4")
        val expired = workFile("export-999/out.mp4")
        DiskCache.markActive(active.parentFile!!)
        WorkExemptions.add(detached, paths, expiresMs = now + 1_000)
        WorkExemptions.add(expired, paths, expiresMs = now - 1)

        val removed = DiskCache.wipeWork(paths, nowMs = now)

        assertFalse(stale.exists())
        assertFalse(strayFile.exists())
        assertFalse("expired exemption wiped", expired.exists())
        assertTrue("active job kept", active.isFile)
        assertTrue("unconsumed detached output kept", detached.isFile)
        assertEquals(3, removed)
        // The expired entry is dropped from the persisted exemptions.
        assertEquals(setOf("export-123/out.mp4"), WorkExemptions.load(paths).keys)
    }

    @Test
    fun picksAndDropsOlderThanADayAreWiped() {
        val day = DiskCache.PICK_LIFETIME_MS
        val oldPick = workFile("picks/uuid-a/clip.mov", now - day - 1)
        File(paths.work, "picks/uuid-a").setLastModified(now - day - 1)
        val newPick = workFile("picks/uuid-b/clip.mov", now - 1_000)
        val oldDrop = workFile("drops/uuid-c/song.m4a", now - 2 * day)
        File(paths.work, "drops/uuid-c").setLastModified(now - 2 * day)
        val newDrop = workFile("drops/uuid-d/song.m4a", now)

        DiskCache.wipeWork(paths, nowMs = now)

        assertFalse(oldPick.exists())
        assertFalse(oldDrop.exists())
        assertTrue(newPick.isFile)
        assertTrue(newDrop.isFile)
        assertTrue("the picks/ and drops/ folders stay", File(paths.work, "picks").isDirectory && File(paths.work, "drops").isDirectory)
    }

    @Test
    fun exemptionsPersistAndAreConsumed() {
        val output = workFile("export-7/out.mp4")
        WorkExemptions.add(output, paths, expiresMs = now + 10_000)
        assertTrue(File(paths.cacheRoot, WorkExemptions.FILE_NAME).isFile)
        assertEquals(setOf("export-7/out.mp4"), WorkExemptions.live(paths, now))
        WorkExemptions.remove(output, paths)
        assertTrue(WorkExemptions.live(paths, now).isEmpty())
        DiskCache.wipeWork(paths, nowMs = now)
        assertFalse(output.exists())
        // Files outside work/ are never registered.
        WorkExemptions.add(File(paths.thumbs, "x.vwth"), paths)
        assertTrue(WorkExemptions.load(paths).isEmpty())
    }
}
