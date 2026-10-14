// OWNER: AND-12
//
// ExportService on the emulator (BUILD_PLAN AND-12; ARCH §14.3, D-22, D-39), through AND-11's
// production coordinator (ExportHarness) registered with the service:
// - foregroundTypeProgressAndStop: the service enters the foreground with mediaProcessing on API 35+
//   and dataSync on API 29-34 (run on Pixel_9_Pro_XL_API_35, Pixel_API_34, Pixel_API_29), shows a
//   determinate progress notification with Cancel, posts at most once per second, and stops and
//   removes the notification when the export ends.
// - exportContinuesWithActivityDestroyed: the activity finishes mid-export; the export completes.
// - notificationCancelWorksWithActivityDestroyed: Cancel tapped in the notification shade
//   (UiAutomator) with the activity destroyed cancels the job and deletes the partial output.
// - swipeFromRecentsSavesToGalleryAndOffersTheRecordOnce (D-39): the app's task is swiped away in
//   Recents mid-export (UiAutomator); the activity is destroyed and the event sink detaches as the
//   Flutter engine does; the export finishes in the service, lands in MediaStore under
//   Movies/Danaview (IS_PENDING cleared, verified with a MediaStore query), a completedWhileDetached
//   record is written, the output is exempt from the work/ wipe, "Saved to Gallery" is posted; after
//   a relaunch (new activity, new sink) activeJobs offers the record once, then never again.
// - detachedKeepForLaterKeepsTheFile: whenDetached keepForLater keeps the file, no gallery insert.
// - onTimeoutInterruptsJobsAndExpiresLeases: the API 35 onTimeout handler interrupts the job (one-shot
//   interrupted record), expires the lease (leaseExpiring) and stops the service.

package com.vecvel.danaview.editor.engine.service

import android.app.Notification
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import com.vecvel.danaview.editor.engine.export.ActiveExportStore
import com.vecvel.danaview.editor.engine.export.ExportHarness
import com.vecvel.danaview.editor.engine.export.ExportNotification
import com.vecvel.danaview.editor.engine.export.ExportService
import com.vecvel.danaview.editor.engine.export.settings
import com.vecvel.danaview.editor.engine.media.WorkExemptions
import com.vecvel.danaview.editor.engine.pigeon.DetachedHandoffMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.ExportJobStateKindMsg
import com.vecvel.danaview.editor.engine.platform.FragmentRequests
import com.vecvel.danaview.editor.engine.platform.SystemUi
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.regex.Pattern

@RunWith(AndroidJUnit4::class)
class ExportServiceTest {
    private val harnesses = ArrayList<ExportHarness>()
    private val relays = ArrayList<FragmentRequests>()
    private val galleryUris = ArrayList<android.net.Uri>()
    private val device: UiDevice get() = SystemUi.device

    @Before
    fun setUp() {
        ServiceTest.grantNotifications()
        device.pressHome()
    }

    @After
    fun tearDown() {
        for (h in harnesses) {
            for (job in h.coordinator.runningJobs()) h.cancel(job.jobId)
            ExportService.unregister(h.ctx)
            h.close()
        }
        for (r in relays) {
            try {
                if (!r.activity.isDestroyed) r.finish()
            } catch (e: RuntimeException) {
                Log.w(SERVICE_TEST_TAG, "relay finish: $e")
            }
        }
        galleryUris.forEach(ServiceTest::deleteGallery)
        ServiceTest.awaitStopped()
        device.pressHome()
    }

    private fun harness(name: String): ExportHarness = ExportHarness("and12-$name").also {
        harnesses += it
        ExportService.register(it.ctx)
    }

    private fun activity(): FragmentRequests = FragmentRequests.launch().also { relays += it }

    private fun finishAndWait(relay: FragmentRequests) {
        relay.finish()
        assertTrue("activity destroyed", ServiceTest.waitFor(10_000) { relay.activity.isDestroyed })
    }

    @Test
    fun foregroundTypeProgressAndStop() {
        val relay = activity()
        val h = harness("fgs")
        val id = h.start(ServiceTest.counterPlan(150), settings(), h.output("fgs"))
        val svc = ServiceTest.awaitForeground()
        val expected = ExportService.foregroundServiceTypeFor(Build.VERSION.SDK_INT)
        assertEquals("requested type on API ${Build.VERSION.SDK_INT}", expected, svc.requestedForegroundType)
        if (Build.VERSION.SDK_INT >= 29) assertEquals("platform type on API ${Build.VERSION.SDK_INT}", expected, svc.foregroundServiceType)
        val dump = ServiceTest.dumpServices()
        Log.i(SERVICE_TEST_TAG, "API ${Build.VERSION.SDK_INT} dumpsys services:\n" + dump.lines().filter { it.contains("ExportService") || it.contains("isForeground") || it.contains("oregroundServiceType") || it.contains("types=") }.joinToString("\n"))
        assertTrue("dumpsys shows the service in the foreground", dump.contains("isForeground=true"))
        assertTrue("dumpsys shows the type 0x%x".format(expected), dump.contains("%08x".format(expected), ignoreCase = true))

        assertTrue("ongoing notification posted", ServiceTest.waitFor(5_000) { ServiceTest.foregroundNotification() != null })
        val n = ServiceTest.foregroundNotification()!!.notification
        assertEquals("Export test", n.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
        assertEquals(100, n.extras.getInt(Notification.EXTRA_PROGRESS_MAX))
        assertFalse("determinate", n.extras.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE))
        assertEquals(ExportNotification.CANCEL_LABEL, n.actions.single().title.toString())
        assertTrue("ongoing", n.flags and Notification.FLAG_FOREGROUND_SERVICE != 0)
        assertEquals(listOf(id), ExportService.activeJobIds())

        // Progress reaches the notification while rendering.
        assertTrue(
            "progress shown",
            ServiceTest.waitFor(60_000) { (ServiceTest.foregroundNotification()?.notification?.extras?.getInt(Notification.EXTRA_PROGRESS) ?: 0) > 0 || ServiceTest.ended(h, id) },
        )
        val outcome = h.await(id)
        outcome.requireResult()
        val posts = svc.notificationPostTimes()
        val gaps = posts.zipWithNext { a, b -> b - a }
        Log.i(SERVICE_TEST_TAG, "notification posts: ${posts.size} over ${outcome.wallMs} ms (emulator), min gap ${gaps.minOrNull()} ms")
        assertTrue("several progress updates (${posts.size})", posts.size >= 2)
        assertTrue("<= 1 Hz: gaps $gaps", gaps.all { it >= 1_000 })
        assertTrue("service stopped after the export", ServiceTest.awaitStopped())
        assertNull("notification removed", ServiceTest.foregroundNotification())
        relay.finish()
    }

    @Test
    fun exportContinuesWithActivityDestroyed() {
        val relay = activity()
        val h = harness("destroyed")
        val out = h.output("destroyed")
        val id = h.start(ServiceTest.counterPlan(120), settings(), out)
        ServiceTest.awaitForeground()
        finishAndWait(relay)
        assertTrue("still in the foreground with the activity destroyed", ServiceTest.service()?.isForeground == true || ServiceTest.ended(h, id))
        val outcome = h.await(id)
        val result = outcome.requireResult()
        assertTrue("output written", out.isFile && out.length() == result.bytes)
        Log.i(SERVICE_TEST_TAG, "export with the activity destroyed finished in ${outcome.wallMs} ms (emulator)")
        assertTrue(ServiceTest.awaitStopped())
    }

    @Test
    fun notificationCancelWorksWithActivityDestroyed() {
        val relay = activity()
        val h = harness("cancel")
        val out = h.output("cancel")
        val id = h.start(ServiceTest.counterPlan(240, 1920, 1080), settings(w = 1920, h = 1080), out)
        ServiceTest.awaitForeground()
        assertTrue(ServiceTest.waitFor(5_000) { ServiceTest.foregroundNotification() != null })
        finishAndWait(relay)
        assertTrue("open the shade", device.openNotification())
        // Progress updates re-inflate the row, so the found button can go stale: re-find and retry.
        var clicked = false
        for (i in 0 until 5) {
            val cancel = findCancelInShade() ?: continue
            try {
                cancel.click()
                clicked = true
                break
            } catch (e: androidx.test.uiautomator.StaleObjectException) {
                Thread.sleep(200)
            }
        }
        assertTrue("Cancel action of our notification clicked in the shade: " + SystemUi.dump(), clicked)
        val outcome = h.await(id, timeoutSec = 60)
        device.pressBack()
        assertNull("no result", outcome.result)
        assertEquals("cancelled", outcome.failure?.code)
        assertFalse("partial output deleted", out.exists())
        assertTrue(ServiceTest.awaitStopped())
        assertNull(ServiceTest.foregroundNotification())
        Log.i(SERVICE_TEST_TAG, "notification Cancel with the activity destroyed: job cancelled after ${outcome.progress.lastOrNull()?.fraction} progress")
    }

    @Test
    fun swipeFromRecentsSavesToGalleryAndOffersTheRecordOnce() {
        val relay = activity()
        val h = harness("swipe")
        val detach = DetachOnDestroy(h).apply { install() }
        try {
            val out = h.output("swipe")
            val id = h.start(ServiceTest.counterPlan(240, 1920, 1080), settings(w = 1920, h = 1080), out, DetachedHandoffMsg.SAVE_TO_GALLERY)
            ServiceTest.awaitForeground()
            swipeAppFromRecents()
            assertTrue("the activity is destroyed by the swipe:\n" + SystemUi.dump(), detach.awaitDestroyed(15_000))
            assertTrue("the activity is gone", relay.activity.isDestroyed)
            device.pressHome()
            val store = ActiveExportStore.of(h.paths)
            assertTrue(
                "completedWhileDetached recorded",
                ServiceTest.waitFor(300_000) { store.record(id)?.state == ActiveExportStore.State.COMPLETED_WHILE_DETACHED },
            )
            val record = store.record(id)!!
            assertTrue(record.savedToGallery)
            val saved = android.net.Uri.parse(assertNotNullValue(record.savedUri))
            galleryUris += saved
            assertEquals("result kept for Share / Save to Files", out.absolutePath, record.result?.path)
            assertTrue("output kept", out.isFile)
            val rel = out.relativeTo(h.paths.work).invariantSeparatorsPath
            assertTrue("exempt from the work/ wipe", WorkExemptions.load(h.paths).containsKey(rel))

            val row = ServiceTest.galleryRow(saved)
            assertNotNull("MediaStore row", row)
            Log.i(SERVICE_TEST_TAG, "gallery row: $row")
            assertEquals("Movies/Danaview/", row!!.relativePath)
            assertEquals("published (IS_PENDING cleared)", 0, row.pending)
            assertEquals(out.length(), row.size)
            assertEquals("video/mp4", row.mime)
            assertTrue("listed in the Movies/Danaview collection", ServiceTest.galleryIds().contains(row.id))

            assertTrue("'Saved to Gallery' posted", ServiceTest.waitFor(5_000) { ServiceTest.notification(ExportNotification.completionId(id)) != null })
            val done = ServiceTest.notification(ExportNotification.completionId(id))
            assertEquals(ExportNotification.SAVED_TITLE, done!!.notification.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
            assertTrue("service stopped", ServiceTest.awaitStopped())

            // Relaunch: a new activity and a new Dart listener.
            activity()
            h.attach()
            val offered = h.activeJobs().filter { it.jobId == id }
            assertEquals(1, offered.size)
            assertEquals(ExportJobStateKindMsg.COMPLETED_WHILE_DETACHED, offered[0].state)
            assertTrue(offered[0].savedToGallery)
            assertEquals(saved.toString(), offered[0].savedUri)
            assertEquals(out.absolutePath, offered[0].result?.path)
            h.consume(id)
            assertTrue("offered once", h.activeJobs().none { it.jobId == id })
            assertFalse("exemption ends with the record", WorkExemptions.load(h.paths).containsKey(rel))
            ExportNotification(ServiceTest.app).cancelCompleted(id)
        } finally {
            detach.uninstall()
        }
    }

    @Test
    fun detachedKeepForLaterKeepsTheFile() {
        activity()
        val h = harness("keep")
        val out = h.output("keep")
        val before = ServiceTest.galleryIds().toSet()
        val id = h.start(ServiceTest.counterPlan(45), settings(), out, DetachedHandoffMsg.KEEP_FOR_LATER)
        h.detach()
        val store = ActiveExportStore.of(h.paths)
        assertTrue(ServiceTest.waitFor(180_000) { store.record(id)?.state == ActiveExportStore.State.COMPLETED_WHILE_DETACHED })
        val record = store.record(id)!!
        assertFalse(record.savedToGallery)
        assertNull(record.savedUri)
        assertTrue(out.isFile)
        assertEquals("no gallery insert", before, ServiceTest.galleryIds().toSet())
        assertTrue("'Export finished' posted", ServiceTest.waitFor(5_000) { ServiceTest.notification(ExportNotification.completionId(id)) != null })
        val done = ServiceTest.notification(ExportNotification.completionId(id))
        assertEquals(ExportNotification.FINISHED_TITLE, done?.notification?.extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString())
        h.attach()
        h.consume(id)
        ExportNotification(ServiceTest.app).cancelCompleted(id)
        assertTrue(ServiceTest.awaitStopped())
    }

    @Test
    fun onTimeoutInterruptsJobsAndExpiresLeases() {
        activity()
        val h = harness("timeout")
        val out = h.output("timeout")
        val id = h.start(ServiceTest.counterPlan(240, 1920, 1080), settings(w = 1920, h = 1080), out)
        val svc = ServiceTest.awaitForeground()
        val lease = ServiceTest.onMain {
            var leaseId: String? = null
            h.ctx.backgroundGuard.acquire("Captions") { leaseId = it.getOrThrow() }
            leaseId
        }
        assertNotNull(lease)
        // What the platform calls on API 35 when the mediaProcessing / dataSync time limit is reached.
        ServiceTest.onMain { svc.onTimeout(1, svc.requestedForegroundType) }
        val outcome = h.await(id, timeoutSec = 60)
        assertEquals("interrupted", outcome.failure?.code)
        assertFalse("partial output deleted", out.exists())
        assertTrue(
            "leaseExpiring emitted",
            ServiceTest.waitFor(5_000) { h.events.any { it.kind == EngineEventKindMsg.LEASE_EXPIRING && it.jobId == lease } },
        )
        assertTrue("lease dropped", ServiceTest.onMain { h.ctx.backgroundGuard.activeLeases().isEmpty() })
        assertTrue("service stopped", ServiceTest.awaitStopped())
        val records = h.activeJobs().filter { it.jobId == id }
        assertEquals(listOf(ExportJobStateKindMsg.INTERRUPTED), records.map { it.state })
        h.consume(id)
        assertTrue("one-shot", h.activeJobs().none { it.jobId == id })
    }

    private fun <T : Any> assertNotNullValue(value: T?): T {
        assertNotNull(value)
        return value!!
    }

    /** Our notification's Cancel button in the open shade (scrolls, expands the row if collapsed). */
    private fun findCancelInShade(): androidx.test.uiautomator.UiObject2? {
        val cancelText = By.text(Pattern.compile("(?i)^cancel$"))
        var title: androidx.test.uiautomator.UiObject2? = null
        for (i in 0 until 6) {
            title = device.wait(Until.findObject(By.text("Export test")), 2_000)
            if (title != null) break
            device.findObject(By.res(Pattern.compile(".*:id/notification_stack_scroller")))?.scroll(androidx.test.uiautomator.Direction.DOWN, 0.6f)
        }
        var row = title ?: return null
        while (row.resourceName?.endsWith("expandableNotificationRow") != true) row = row.parent ?: return null
        row.findObject(cancelText)?.let { return it }
        row.findObject(By.res(Pattern.compile(".*:id/expand_button")))?.click() ?: row.click()
        Thread.sleep(1_000)
        for (i in 0 until 10) {
            device.findObject(By.text("Export test"))?.let { t ->
                var r: androidx.test.uiautomator.UiObject2? = t
                while (r != null && r.resourceName?.endsWith("expandableNotificationRow") != true) r = r.parent
                r?.findObject(cancelText)?.let { return it }
            }
            Thread.sleep(300)
        }
        return null
    }

    /** Opens Recents and swipes this app's task card away (checked with dumpsys recents). */
    private fun swipeAppFromRecents() {
        val pkg = ServiceTest.app.packageName
        for (attempt in 0 until 5) {
            if (attempt > 0) {
                // A retry: bring our task back on top first (Recents may still be showing).
                device.pressHome()
                Thread.sleep(1_000)
                ServiceTest.app.startActivity(
                    Intent(Intent.ACTION_MAIN).setClassName(pkg, FragmentRequests.EMPTY_ACTIVITY)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
                )
                Thread.sleep(2_000)
            }
            assertTrue("recents", device.pressRecentApps())
            Thread.sleep(3_000)
            device.takeScreenshot(File(ServiceTest.app.filesDir, "and12_recents_$attempt.png"))
            val w = device.displayWidth
            val hgt = device.displayHeight
            // The current task's card is centred; a 400 ms swipe up dismisses it (Launcher3 quickstep).
            // `input swipe` (as a person's finger through the shell): UiDevice.swipe's injected
            // gesture did not dismiss the card on the API 35 launcher.
            ServiceTest.shell("input swipe ${w / 2} ${hgt * 3 / 5} ${w / 2} ${hgt / 20} 400")
            Thread.sleep(2_000)
            val recents = ServiceTest.shell("dumpsys activity recents")
            if (recents.lines().none { it.contains("Recent #") && it.contains(":$pkg}") }) {
                Log.i(SERVICE_TEST_TAG, "swiped the task away in Recents (attempt ${attempt + 1})")
                return
            }
        }
        error("the task is still in Recents")
    }
}
