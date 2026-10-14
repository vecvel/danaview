// OWNER: AND-12
//
// FileHandoff with the real system UI (BUILD_PLAN AND-12; ARCH §14.3), through AND-14's activity
// relay (the library test APK has no Flutter activity) and UiAutomator:
// - saveToFilesThroughDocumentsUi: ACTION_CREATE_DOCUMENT → DocumentsUI → Downloads → Save; the
//   document holds the same bytes; Back answers cancelled.
// - shareGrantsReadOnlyToTheChosenTarget: ACTION_SEND through the chooser with the engine
//   FileProvider URI. Before a choice no share-target app holds a grant; after "Messages" is chosen
//   the chooser callback reports it, Messages' uid holds READ (never WRITE) on the URI and every
//   other share-target app still holds nothing.
// - shareStagesFilesOutsideWork: a file outside the provider's work/ tree is staged into
//   work/handoff/ and shared from there; closing the chooser answers cancelled.
// - noActivityFails: without an activity both calls fail with `internal`.

package com.vecvel.danaview.editor.engine.service

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Process
import android.provider.DocumentsContract
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.harness.FixtureTree
import com.vecvel.danaview.editor.engine.harness.TestFixtures
import com.vecvel.danaview.editor.engine.pigeon.FileHandoffOutcomeMsg
import com.vecvel.danaview.editor.engine.pigeon.FileHandoffResultMsg
import com.vecvel.danaview.editor.engine.platform.ActivityRequests
import com.vecvel.danaview.editor.engine.platform.FileHandoff
import com.vecvel.danaview.editor.engine.platform.FragmentRequests
import com.vecvel.danaview.editor.engine.platform.PlatformTestEngine
import com.vecvel.danaview.editor.engine.platform.SystemUi
import com.vecvel.danaview.editor.engine.platform.startOnMain
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.regex.Pattern

@RunWith(AndroidJUnit4::class)
class FileHandoffTest {
    private lateinit var ctx: EngineContext
    private val relays = ArrayList<FragmentRequests>()
    private val documents = ArrayList<Uri>()

    @Before
    fun setUp() {
        ctx = PlatformTestEngine.create()
        SystemUi.device.pressHome()
    }

    @After
    fun tearDown() {
        for (d in documents) {
            try {
                DocumentsContract.deleteDocument(ServiceTest.app.contentResolver, d)
            } catch (e: Exception) {
                Log.w(SERVICE_TEST_TAG, "document cleanup: $e")
            }
        }
        // Close whatever system UI the test left on top of the relay's task (DocumentsUI, chooser, target).
        repeat(3) { SystemUi.device.pressBack() }
        relays.forEach { if (!it.activity.isDestroyed) it.finish() }
        SystemUi.device.pressHome()
        ctx.threads.shutdown()
    }

    private fun handoff(): FileHandoff {
        val relay = FragmentRequests.launch().also { relays += it }
        return FileHandoff(ctx).apply { requests = relay }
    }

    private fun workFile(name: String): File {
        val dir = File(ctx.requirePaths().work, "and12-handoff").apply { mkdirs() }
        return File(dir, name).also { TestFixtures.copyToCache(FixtureTree.ENGINE, "media/frame_counter_720p24.mp4").copyTo(it, overwrite = true) }
    }

    @Test
    fun saveToFilesThroughDocumentsUi() {
        val f = handoff()
        val file = workFile("source.mp4")
        val name = "danaview_and12_${System.currentTimeMillis()}.mp4"
        val pending = startOnMain<FileHandoffResultMsg> { f.saveToFiles(file.absolutePath, name, it) }
        clickSave()
        val r = pending.await(30_000).getOrThrow()
        assertEquals(FileHandoffOutcomeMsg.DONE, r.outcome)
        val uri = Uri.parse(r.savedUri!!)
        documents += uri
        val bytes = ServiceTest.app.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
        assertArrayEquals("the document holds the export", file.readBytes(), bytes)
        Log.i(SERVICE_TEST_TAG, "save to files: ${bytes.size} bytes written through DocumentsUI")

        val cancelled = startOnMain<FileHandoffResultMsg> { f.saveToFiles(file.absolutePath, "cancelled.mp4", it) }
        findSaveButton()
        SystemUi.device.pressBack()
        assertEquals(FileHandoffOutcomeMsg.CANCELLED, cancelled.await(30_000).getOrThrow().outcome)
    }

    /** Clicks Save on DocumentsUI's save screen (re-found after each UI refresh). */
    private fun clickSave() {
        for (attempt in 0 until 3) {
            try {
                findSaveButton().click()
                return
            } catch (e: androidx.test.uiautomator.StaleObjectException) {
                Thread.sleep(500)
            }
        }
        error("Save kept going stale: " + SystemUi.dump())
    }

    /** DocumentsUI's save screen on a writable root (Downloads), returning its Save button. */
    private fun findSaveButton(): androidx.test.uiautomator.UiObject2 {
        val save = { SystemUi.device.findObject(androidx.test.uiautomator.By.res(Pattern.compile(".*documentsui:id/container_save.*")))?.findObject(androidx.test.uiautomator.By.clickable(true).text(Pattern.compile("(?i)^save$"))) }
        val byText = SystemUi.byText("(?i)^save$")
        SystemUi.waitAny(15_000, save, byText) ?: error("no DocumentsUI save screen:\n" + SystemUi.dump())
        // Make sure the current root is writable (Downloads); open the roots drawer only when needed.
        // The toolbar / breadcrumb names the current root ("Downloads" on API 29 and 35 by default).
        val inDownloads = SystemUi.waitAny(2_000, SystemUi.byText("(?i)^downloads$")) != null
        if (!inDownloads) {
            SystemUi.waitAny(3_000, SystemUi.byDesc("(?i)show roots"))?.click()
            SystemUi.waitAny(5_000, SystemUi.byText("(?i)^downloads?$"))?.click()
            Thread.sleep(1_500)
        }
        return SystemUi.waitAny(10_000, save, byText) ?: error("no Save button:\n" + SystemUi.dump())
    }

    @Test
    fun shareGrantsReadOnlyToTheChosenTarget() {
        val f = handoff()
        val file = workFile("share.mp4")
        val uri = f.providerUri(file)
        assertNotNull("served by the engine FileProvider", uri)
        val targets = ServiceTest.sendTargets("video/mp4")
        Log.i(SERVICE_TEST_TAG, "share targets for video/mp4: $targets")
        val chosenPkg = "com.google.android.apps.messaging"
        val chosenLabel = "(?i)^messages$"
        assertTrue("Messages is a share target on this image ($targets)", chosenPkg in targets)

        val pending = startOnMain<FileHandoffResultMsg> { f.share(file.absolutePath, it) }
        val target = SystemUi.waitAny(20_000, SystemUi.byText(chosenLabel)) ?: error("no Messages target in the chooser:\n" + SystemUi.dump())
        for (p in targets) assertEquals("$p holds no grant before the choice", PackageManager.PERMISSION_DENIED, read(uri!!, p))
        val share = f.lastShareIntent!!
        assertEquals(Intent.FLAG_GRANT_READ_URI_PERMISSION, share.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION))
        target.click()
        val r = pending.await(30_000).getOrThrow()
        assertEquals(FileHandoffOutcomeMsg.DONE, r.outcome)
        assertEquals(chosenPkg, f.lastChosenPackage)
        assertTrue(
            "the chosen target holds READ",
            ServiceTest.waitFor(5_000) { read(uri!!, chosenPkg) == PackageManager.PERMISSION_GRANTED },
        )
        assertEquals("never WRITE", PackageManager.PERMISSION_DENIED, check(uri!!, chosenPkg, Intent.FLAG_GRANT_WRITE_URI_PERMISSION))
        for (p in targets - chosenPkg) assertEquals("$p (not chosen) holds no grant", PackageManager.PERMISSION_DENIED, read(uri, p))
        Log.i(SERVICE_TEST_TAG, "share: READ granted to the chosen target only (${targets.size - 1} other targets checked)")
        repeat(3) { SystemUi.device.pressBack() }
    }

    @Test
    fun shareStagesFilesOutsideWork() {
        val f = handoff()
        val outside = File(ctx.requirePaths().supportRoot, "and12-outside/clip.mp4").apply { parentFile!!.mkdirs() }
        TestFixtures.copyToCache(FixtureTree.ENGINE, "media/frame_counter_720p24.mp4").copyTo(outside, overwrite = true)
        assertNull("not served directly", f.providerUri(outside))
        val pending = startOnMain<FileHandoffResultMsg> { f.share(outside.absolutePath, it) }
        assertTrue("chooser shown", ServiceTest.waitFor(20_000) { f.lastShareIntent != null })
        Thread.sleep(2_000)
        val shared = androidx.core.content.IntentCompat.getParcelableExtra(f.lastShareIntent!!, Intent.EXTRA_STREAM, Uri::class.java)!!
        assertEquals("content", shared.scheme)
        assertTrue("staged under work/handoff", shared.path!!.contains("/handoff/"))
        SystemUi.device.pressBack()
        assertEquals(FileHandoffOutcomeMsg.CANCELLED, pending.await(30_000).getOrThrow().outcome)
        outside.parentFile!!.deleteRecursively()
    }

    @Test
    fun noActivityFails() {
        val f = FileHandoff(ctx).apply {
            requests = object : ActivityRequests {
                override val activity = null
                override fun startForResult(intent: Intent, onResult: (Int, Intent?) -> Unit) = false
                override fun requestPermissions(permissions: Array<String>, onResult: (Array<out String>, IntArray) -> Unit) = false
            }
        }
        val file = workFile("noactivity.mp4")
        val save = startOnMain<FileHandoffResultMsg> { f.saveToFiles(file.absolutePath, "x.mp4", it) }.await()
        assertEquals("internal", (save.exceptionOrNull() as EngineException).code.name)
        val share = startOnMain<FileHandoffResultMsg> { f.share(file.absolutePath, it) }.await()
        assertEquals("internal", (share.exceptionOrNull() as EngineException).code.name)
        val missing = startOnMain<FileHandoffResultMsg> { f.share(File(file.parentFile, "missing.mp4").absolutePath, it) }.await()
        assertEquals("mediaOffline", (missing.exceptionOrNull() as EngineException).code.name)
    }

    private fun read(uri: Uri, pkg: String): Int = check(uri, pkg, Intent.FLAG_GRANT_READ_URI_PERMISSION)

    private fun check(uri: Uri, pkg: String, mode: Int): Int {
        val uid = ServiceTest.uidOf(pkg)
        return ServiceTest.app.checkUriPermission(uri, Process.myPid(), uid, mode)
    }
}
