// OWNER: HOM-22A
//
// Emulator tests of getting files out on Android (BUILD_PLAN HOM-22A: API 35, 29 and an API 28 AVD
// for the Home-only path; each action works with no storage permission; grants are read-only).
// The test APK never declares WRITE_EXTERNAL_STORAGE and no test grants a storage permission.
//
// - Save to Downloads / Photos on API 29+: new MediaStore rows in Download/<sub>/, Pictures/Danaview/,
//   Movies/Danaview/ with the exact bytes; saving again creates a second item (never overwrites);
//   a document sent to Photos counts as failed. On API 24-28 they open the system "save as".
// - Save to Files: ACTION_CREATE_DOCUMENT in DocumentsUI (one file, saved into Downloads) and
//   ACTION_OPEN_DOCUMENT_TREE (several files into a chosen folder); closing the dialog = cancelled.
// - Share: copies in cacheDir/danaview-out/<UUID>/, read-only, ACTION_SEND_MULTIPLE through the
//   system chooser to the test APK's ShareTargetActivity, which can read the bytes but not write;
//   completed + the chosen package are reported; Back = not completed.
// - Open in: ACTION_VIEW resolves to ShareTargetActivity (read grant only); an unknown type -> false.
// - The FileProvider serves only danaview-out/, never the library.
// - Clean-up: every test removes what it put in shared storage (MediaStore rows, documents, and the
//   Download/Danaview-<stamp>/ and Download/dv_tree_<stamp>/ folders, which API 29 leaves behind on
//   disk and as MediaStore folder rows that DocumentsUI keeps listing), and setUp sweeps such folders
//   left by an aborted earlier run, so DocumentsUI's Downloads (where the picker tests seed their
//   files) doesn't fill up with folders.

package com.vecvel.danaview.library.exportout

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.library.glue.LibraryErrorCode
import com.vecvel.danaview.library.pickers.FragmentLauncher
import com.vecvel.danaview.library.pickers.SystemUi
import com.vecvel.danaview.library.pigeon.SaveOutDestinationMsg
import com.vecvel.danaview.library.pigeon.SaveOutResultMsg
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
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.regex.Pattern

@RunWith(AndroidJUnit4::class)
class FileOutTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val resolver get() = context.contentResolver
    private val sdk = Build.VERSION.SDK_INT
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val out = AndroidFileOut(context)
    private val post: (() -> Unit) -> Unit = { block -> main.post(block) }
    private val stamp = UUID.randomUUID().toString().take(8)
    private lateinit var lib: File
    private val created = ArrayList<Uri>()
    /** Folders this test made under Download/ (names only). */
    private val downloadFolders = ArrayList<String>()
    private var relay: FragmentLauncher? = null

    @Before
    fun setUp() {
        lib = File(context.filesDir, "library-test-$stamp").apply { mkdirs() }
        sweepLeftovers()
        ShareTargetActivity.received.clear()
        assertEquals("no storage write permission", PackageManager.PERMISSION_DENIED, context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE))
    }

    @After
    fun tearDown() {
        // Documents first: the dialogs' grants hold while the relay activity is alive.
        created.forEach { u -> runCatching { resolver.delete(u, null, null) }; runCatching { android.provider.DocumentsContract.deleteDocument(resolver, u) } }
        relay?.let {
            SystemUi.device.pressBack()
            it.finish()
        }
        // Deleting the rows leaves their folders behind (on API 29, also as MediaStore rows): remove them too.
        downloadFolders.forEach { removeFromDownloads(it) }
        // The product's Photos folders only if the saves above left them empty (rmdir never deletes content).
        listOf(Environment.DIRECTORY_PICTURES, Environment.DIRECTORY_MOVIES).forEach { dir ->
            @Suppress("DEPRECATION")
            shell("rmdir ${File(Environment.getExternalStoragePublicDirectory(dir), "Danaview").absolutePath}")
        }
        lib.deleteRecursively()
        out.store.batches().forEach { out.store.remove(TempBatch(it, emptyList())) }
        worker.shutdown()
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers

    @Suppress("DEPRECATION")
    private val downloads: File get() = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)

    /**
     * Runs [command] as the shell user, which can change shared storage on every API level without
     * the test APK holding a storage permission (arguments are split on spaces: no globs or quotes).
     */
    private fun shell(command: String): String = runCatching { SystemUi.device.executeShellCommand(command) }.getOrDefault("")

    /**
     * Removes a folder (or file) this test made in Download/: from disk, and its MediaStore row.
     * On API 29 deleting the rows inside a folder leaves both the folder and MediaStore's own row
     * for it (format 0x3001, no owner, so the test APK can't see or delete it); DocumentsUI's
     * Downloads root lists such rows as folders even once the directory is gone from disk.
     */
    private fun removeFromDownloads(name: String) {
        val path = File(downloads, name).absolutePath
        shell("rm -r $path")
        shell("content delete --uri content://media/external/file --where _data='$path'")
    }

    /**
     * Removes what an earlier, aborted run of this class left in Download/ (only names it creates),
     * on disk and as stale MediaStore folder rows.
     */
    private fun sweepLeftovers() {
        val ours = Regex("^(Danaview-[0-9a-f]{8}|dv_tree_[0-9a-f]{8}|dv_saveas_[0-9a-f]{8}.*\\.txt)$")
        val onDisk = shell("ls -1 ${downloads.absolutePath}").lineSequence().map { it.trim() }
        val prefix = downloads.absolutePath + "/"
        val folderRows = shell("content query --uri content://media/external/file --projection _data --where format=12289")
            .lineSequence().mapNotNull { Regex("_data=(.*)$").find(it.trim())?.groupValues?.get(1) }
            .filter { it.startsWith(prefix) }.map { it.removePrefix(prefix) }
        (onDisk + folderRows).filter { ours.matches(it) }.toSet().forEach { removeFromDownloads(it) }
    }

    private fun libFile(name: String, bytes: ByteArray) = File(lib, name).apply { writeBytes(bytes) }

    private fun bytes(n: Int, seed: Int) = ByteArray(n) { ((it * 31 + seed) and 0xff).toByte() }

    private fun item(f: File, name: String = f.name, mime: String? = null) = OutFile(f.absolutePath, name, mime)

    private fun launcher(): OutLauncher {
        val r = FragmentLauncher.launch().also { relay = it }
        return OutLauncher { intent, done -> r.start(intent, done) }
    }

    private class Pending<T> {
        val latch = CountDownLatch(1)
        @Volatile var result: Result<T>? = null
        val callback: (Result<T>) -> Unit = { result = it; latch.countDown() }
        fun await(seconds: Long = 30): T {
            check(latch.await(seconds, TimeUnit.SECONDS)) { "no reply:\n" + SystemUi.dump() }
            return result!!.getOrThrow()
        }
        fun failure(seconds: Long = 30): OutFailure {
            check(latch.await(seconds, TimeUnit.SECONDS)) { "no reply" }
            return (result!!.exceptionOrNull() as? OutFailure) ?: error("expected an OutFailure, got $result")
        }
    }

    private fun <T> onMain(block: (Pending<T>) -> Unit): Pending<T> {
        val p = Pending<T>()
        InstrumentationRegistry.getInstrumentation().runOnMainSync { block(p) }
        return p
    }

    private fun save(files: List<OutFile>, destination: SaveOutDestinationMsg, launcher: OutLauncher = OutLauncher { _, _ -> false }, sub: String? = "Danaview-$stamp") =
        onMain<SaveOutResultMsg> { SaveOutFlow(out, worker, post).save(files, destination, sub, launcher, it.callback) }

    private fun read(uri: String): ByteArray = resolver.openInputStream(Uri.parse(uri))!!.use { it.readBytes() }

    private fun column(uri: String, column: String): String? =
        resolver.query(Uri.parse(uri), arrayOf(column), null, null, null)?.use { c -> if (c.moveToFirst()) c.getString(0) else null }

    /** Taps DocumentsUI's Save button (text varies by release). */
    private fun tapSave() {
        (SystemUi.waitAny(10_000, SystemUi.byText("(?i)^save$"), SystemUi.byRes("android:id/button1")) ?: error("no Save:\n" + SystemUi.dump())).click()
        // A freshly booted device can drop the first tap while DocumentsUI is still loading: tap again
        // if the dialog is still there (nothing matches once it has closed).
        Thread.sleep(3_000)
        runCatching { SystemUi.byText("(?i)^save$")()?.click() }
    }

    // ---------------------------------------------------------------------------------------------
    // MediaStore saves (API 29+)

    @Test
    fun saveToDownloadsCreatesNewItemsWithTheBytes() {
        assumeTrue("MediaStore Downloads is API 29+ (24-28: save as, tested below)", sdk >= 29)
        downloadFolders += "Danaview-$stamp"
        val a = libFile("Report.pdf", bytes(5000, 1))
        val b = libFile("clip.mp4", bytes(7000, 2))
        val r = save(listOf(item(a, mime = "application/pdf"), item(b)), SaveOutDestinationMsg.DOWNLOADS).await()
        assertFalse(r.cancelled)
        assertEquals(0L, r.failedCount)
        assertEquals(2, r.savedUris.size)
        r.savedUris.forEach { created += Uri.parse(it) }
        assertArrayEquals(a.readBytes(), read(r.savedUris[0]))
        assertArrayEquals(b.readBytes(), read(r.savedUris[1]))
        assertEquals("Download/Danaview-$stamp/", column(r.savedUris[0], MediaStore.MediaColumns.RELATIVE_PATH))
        assertEquals("Report.pdf", column(r.savedUris[0], MediaStore.MediaColumns.DISPLAY_NAME))
        assertEquals("0", column(r.savedUris[0], MediaStore.MediaColumns.IS_PENDING))
        // Saving again never overwrites: a second item with its own name.
        val again = save(listOf(item(a)), SaveOutDestinationMsg.DOWNLOADS).await()
        again.savedUris.forEach { created += Uri.parse(it) }
        assertNotEquals(r.savedUris[0], again.savedUris[0])
        assertNotEquals("Report.pdf", column(again.savedUris[0], MediaStore.MediaColumns.DISPLAY_NAME))
        assertArrayEquals(a.readBytes(), read(r.savedUris[0]))
        // The library files are untouched and still there.
        assertArrayEquals(bytes(5000, 1), a.readBytes())
    }

    @Test
    fun saveToPhotosAddsMediaAndRejectsDocuments() {
        assumeTrue("MediaStore Images/Video is API 29+", sdk >= 29)
        val jpg = libFile("p.jpg", bytes(3000, 3))
        val mp4 = libFile("v.mp4", bytes(4000, 4))
        val pdf = libFile("d.pdf", bytes(100, 5))
        val r = save(listOf(item(jpg), item(mp4), item(pdf)), SaveOutDestinationMsg.PHOTOS).await()
        r.savedUris.forEach { created += Uri.parse(it) }
        assertFalse(r.cancelled)
        assertEquals(1L, r.failedCount)
        assertEquals(2, r.savedUris.size)
        assertTrue(r.savedUris[0].contains("/images/"))
        assertTrue(r.savedUris[1].contains("/video/"))
        assertEquals("Pictures/Danaview/", column(r.savedUris[0], MediaStore.MediaColumns.RELATIVE_PATH))
        assertEquals("Movies/Danaview/", column(r.savedUris[1], MediaStore.MediaColumns.RELATIVE_PATH))
        assertArrayEquals(jpg.readBytes(), read(r.savedUris[0]))
        // Only documents: nothing saved, all failed, no dialog.
        val none = save(listOf(item(pdf)), SaveOutDestinationMsg.PHOTOS).await()
        assertEquals(SaveOutResultMsg(false, emptyList(), 1L), none)
    }

    @Test
    fun badRequestsAreTyped() {
        assertEquals(LibraryErrorCode.notFound, save(listOf(OutFile(File(lib, "gone").absolutePath, "g", null)), SaveOutDestinationMsg.DOWNLOADS).failure().code)
        assertEquals(LibraryErrorCode.invalidArgument, save(emptyList(), SaveOutDestinationMsg.FILES).failure().code)
        // Without an Activity the save dialog can't open.
        val f = libFile("x.txt", bytes(10, 6))
        assertEquals(LibraryErrorCode.busy, save(listOf(item(f)), SaveOutDestinationMsg.FILES).failure().code)
    }

    // ---------------------------------------------------------------------------------------------
    // System "save as" (Save to Files everywhere; Downloads and Photos on API 24-28)

    @Test
    fun saveAsOneFileWritesTheCreatedDocument() {
        val name = "dv_saveas_$stamp.txt"
        val f = libFile(name, bytes(2048, 7))
        // On API 24-28 Save to Downloads takes this path (answer 9); elsewhere Save to Files does.
        val destination = if (sdk < 29) SaveOutDestinationMsg.DOWNLOADS else SaveOutDestinationMsg.FILES
        val p = save(listOf(item(f, mime = "text/plain")), destination, launcher())
        Thread.sleep(1_500)
        SystemUi.openDownloadsIfNeeded("\u0000never-listed")
        Thread.sleep(800)
        tapSave()
        val r = p.await()
        assertFalse(r.cancelled)
        assertEquals(0L, r.failedCount)
        assertEquals(1, r.savedUris.size)
        created += Uri.parse(r.savedUris[0])
        assertArrayEquals(f.readBytes(), read(r.savedUris[0]))
    }

    @Test
    fun saveAsSeveralFilesGoesIntoTheChosenFolder() {
        assumeTrue("the test folder is seeded through MediaStore (API 29+)", sdk >= 29)
        // Android 11+ refuses the Download root as a tree: seed a sub-folder to choose.
        val folder = "dv_tree_$stamp"
        downloadFolders += folder
        val seedValues = android.content.ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, "seed.txt")
            put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
            put(MediaStore.MediaColumns.RELATIVE_PATH, "Download/$folder/")
        }
        val seedUri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, seedValues)!!
        created += seedUri
        resolver.openOutputStream(seedUri)!!.use { it.write(1) }
        val a = libFile("one.txt", bytes(100, 8))
        val b = libFile("two.txt", bytes(200, 9))
        val p = save(listOf(item(a), item(b, name = "one.txt")), SaveOutDestinationMsg.FILES, launcher())
        Thread.sleep(1_500)
        // API 30+ opens the tree picker at the device root (Download is a folder there); API 29 at Downloads.
        if (SystemUi.waitAny(5_000, SystemUi.byText(Pattern.quote(folder))) == null) {
            val download = SystemUi.waitAny(5_000, SystemUi.byText("^Download$"))
            if (download != null) download.click() else SystemUi.openDownloadsIfNeeded(folder)
        }
        (SystemUi.waitAny(10_000, SystemUi.byText(Pattern.quote(folder))) ?: error("folder not listed:\n" + SystemUi.dump())).click()
        Thread.sleep(1_000)
        // "Use this folder" (API 30+) or "Allow access to <folder>" (API 29), then the confirmation.
        (SystemUi.waitAny(10_000, SystemUi.byText("(?i)^use this folder$"), SystemUi.byText("(?i)^allow access to.*"), SystemUi.byRes("android:id/button1"))
            ?: error("no Use this folder:\n" + SystemUi.dump())).click()
        Thread.sleep(1_000)
        (SystemUi.waitAny(10_000, SystemUi.byText("(?i)^allow$")) ?: error("no Allow:\n" + SystemUi.dump())).click()
        val r = p.await()
        r.savedUris.forEach { created += Uri.parse(it) }
        assertFalse(r.cancelled)
        assertEquals(0L, r.failedCount)
        assertEquals(2, r.savedUris.size)
        assertArrayEquals(a.readBytes(), read(r.savedUris[0]))
        assertArrayEquals(b.readBytes(), read(r.savedUris[1]))
        // Same display name twice: the folder made the second one unique.
        val names = r.savedUris.map { u -> column(u, android.provider.OpenableColumns.DISPLAY_NAME) }
        assertEquals("one.txt", names[0])
        assertNotEquals("one.txt", names[1])
    }

    @Test
    fun closingTheSaveDialogIsCancelled() {
        val f = libFile("c.txt", bytes(10, 10))
        val p = save(listOf(item(f)), SaveOutDestinationMsg.FILES, launcher())
        Thread.sleep(2_500)
        SystemUi.device.pressBack()
        assertEquals(SaveOutResultMsg(true, emptyList(), 0L), p.await())
    }

    // ---------------------------------------------------------------------------------------------
    // Share and open in

    @Test
    fun shareHandsReadOnlyCopiesToTheChosenApp() {
        val a = libFile("A.jpg", bytes(1000, 11))
        val b = libFile("B.pdf", bytes(1500, 12))
        val flow = ShareFlow(context, out, worker, post)
        val l = launcher()
        val p = onMain<ShareOutcome> { flow.share(listOf(item(a), item(b, mime = "application/pdf")), "Subject", l, { ms, block -> main.postDelayed(block, ms) }, it.callback) }
        val target = SystemUi.waitAny(15_000, SystemUi.byText("^DV Test Receiver$")) ?: run {
            // Some choosers list direct targets first: expand to the full app list.
            SystemUi.device.swipe(SystemUi.device.displayWidth / 2, SystemUi.device.displayHeight - 200, SystemUi.device.displayWidth / 2, 300, 20)
            SystemUi.waitAny(10_000, SystemUi.byText("^DV Test Receiver$"))
        } ?: error("test receiver not in the chooser:\n" + SystemUi.dump())
        target.click()
        val got = ShareTargetActivity.received.poll(20, TimeUnit.SECONDS) ?: error("receiver not started")
        assertEquals(Intent.ACTION_SEND_MULTIPLE, got.action)
        assertEquals("*/*", got.type)
        assertEquals("Subject", got.subject)
        assertEquals(2, got.uris.size)
        assertTrue(got.uris.all { it.authority == context.packageName + AndroidFileOut.AUTHORITY_SUFFIX })
        assertArrayEquals(a.readBytes(), got.bytes[0])
        assertArrayEquals(b.readBytes(), got.bytes[1])
        assertEquals("the receiver can't write the copies", listOf(false, false), got.writable)
        assertEquals(0, got.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        val outcome = p.await()
        assertTrue(outcome.completed)
        assertEquals(context.packageName, outcome.activityType)
        // The copies: one batch in danaview-out, read-only, the library files unchanged.
        val batches = out.store.batches()
        assertEquals(1, batches.size)
        val copies = batches[0].listFiles()!!.sortedBy { it.name }
        assertEquals(listOf("A.jpg", "B.pdf"), copies.map { it.name })
        assertTrue(copies.none { it.canWrite() })
        assertTrue(a.canWrite())
        assertArrayEquals(bytes(1000, 11), a.readBytes())
    }

    @Test
    fun closingTheShareSheetIsNotCompleted() {
        val a = libFile("one.txt", bytes(10, 13))
        val flow = ShareFlow(context, out, worker, post)
        val l = launcher()
        val p = onMain<ShareOutcome> { flow.share(listOf(item(a)), null, l, { ms, block -> main.postDelayed(block, ms) }, it.callback) }
        Thread.sleep(3_000)
        SystemUi.device.pressBack()
        val outcome = p.await()
        assertFalse(outcome.completed)
        assertNull(outcome.activityType)
    }

    @Test
    fun shareIntentGrantsReadOnly() {
        val batch = out.store.makeBatch(listOf(item(libFile("g.png", bytes(64, 14))), item(libFile("h.png", bytes(64, 15)))))
        val i = out.shareIntent(batch, listOf("image/png", "image/png"), null)
        assertEquals(Intent.ACTION_SEND_MULTIPLE, i.action)
        assertEquals("image/png", i.type)
        assertEquals(Intent.FLAG_GRANT_READ_URI_PERMISSION, i.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION))
        assertEquals(2, i.clipData!!.itemCount)
        val single = out.viewIntent(out.store.makeBatch(listOf(item(libFile("v.pdf", bytes(10, 16))))), "application/pdf")
        assertEquals(Intent.FLAG_GRANT_READ_URI_PERMISSION, single.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION))
        assertEquals("application/pdf", single.type)
    }

    @Test
    fun theFileProviderNeverServesTheLibrary() {
        val libraryFile = libFile("secret.jpg", bytes(10, 17))
        try {
            out.uriFor(libraryFile)
            fail("a library file got a content URI")
        } catch (e: IllegalArgumentException) {
            // expected: only danaview-out/ is configured
        }
    }

    @Test
    fun openInStartsTheViewerWithAReadGrant() {
        val f = libFile("doc.dvt", bytes(321, 18))
        val flow = OpenInFlow(out, worker, post)
        val activity = { relay?.activity }
        launcher()
        val p = onMain<Boolean> { flow.openIn(item(f, mime = ShareTargetActivity.VIEW_TYPE), activity, it.callback) }
        assertTrue(p.await())
        val got = ShareTargetActivity.received.poll(20, TimeUnit.SECONDS) ?: error("viewer not started")
        assertEquals(Intent.ACTION_VIEW, got.action)
        assertEquals(ShareTargetActivity.VIEW_TYPE, got.type)
        assertArrayEquals(f.readBytes(), got.bytes[0])
        assertEquals(listOf(false), got.writable)
        // A type no installed app opens: false, and its copy is removed again.
        val before = out.store.batches().size
        val none = onMain<Boolean> { OpenInFlow(out, worker, post).openIn(item(f, mime = "application/x-danaview-nobody-$stamp"), activity, it.callback) }
        assertFalse(none.await())
        assertEquals(before, out.store.batches().size)
        assertNotNull(relay)
    }
}
