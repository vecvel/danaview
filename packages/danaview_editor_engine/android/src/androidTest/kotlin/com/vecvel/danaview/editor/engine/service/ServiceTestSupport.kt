// OWNER: AND-12
//
// Test support of the AND-12 instrumented tests: grants POST_NOTIFICATIONS to the test app (API 33+)
// so the export notifications can be inspected, an activity in the test app (androidx.test's
// EmptyActivity through AND-14's FragmentRequests relay; the library test APK declares no activity of
// its own) so the app is in the foreground when an export starts and has a task in Recents, an
// engine harness per test (AND-11's ExportHarness: own roots, production coordinator) registered
// with ExportService, the "Flutter engine goes away with the activity" rule (the sink detaches when
// the activity is destroyed, as the plugin's FlutterActivity engine does), plan builders over ENG-05's
// frame_counter_1080p30.mp4 fixture, and MediaStore / notification / service readers.

package com.vecvel.danaview.editor.engine.service

import android.Manifest
import android.app.Activity
import android.app.Application
import android.app.NotificationManager
import android.content.ContentUris
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.service.notification.StatusBarNotification
import android.util.Log
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.export.ExportHarness
import com.vecvel.danaview.editor.engine.export.ExportNotification
import com.vecvel.danaview.editor.engine.export.ExportPlans
import com.vecvel.danaview.editor.engine.export.ExportService
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.plan.FrameGrid
import com.vecvel.danaview.editor.engine.plan.PlanAsset
import com.vecvel.danaview.editor.engine.plan.PlanAssetKind
import com.vecvel.danaview.editor.engine.plan.PlanCanvas
import com.vecvel.danaview.editor.engine.plan.PlanSize
import com.vecvel.danaview.editor.engine.plan.PlanTarget
import com.vecvel.danaview.editor.engine.plan.RenderPlan
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

const val SERVICE_TEST_TAG = "DanaviewServiceTest"

object ServiceTest {
    val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    val app get() = instrumentation.targetContext.applicationContext

    /** Grants POST_NOTIFICATIONS (API 33+) so notifications are posted and readable. */
    fun grantNotifications() {
        if (Build.VERSION.SDK_INT >= 33) instrumentation.uiAutomation.grantRuntimePermission(app.packageName, Manifest.permission.POST_NOTIFICATIONS)
    }

    /** Runs [block] on main and returns its value. */
    fun <T> onMain(block: () -> T): T {
        var out: Result<T>? = null
        instrumentation.runOnMainSync { out = runCatching(block) }
        return out!!.getOrThrow()
    }

    /** Polls [condition] every 50 ms until true or [timeoutMs]; returns the final value. */
    fun waitFor(timeoutMs: Long, condition: () -> Boolean): Boolean {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            if (condition()) return true
            Thread.sleep(50)
        }
        return condition()
    }

    /** The running service, or null. */
    fun service(): ExportService? = ExportService.current()

    /** Waits until the service is in the foreground. */
    fun awaitForeground(timeoutMs: Long = 15_000): ExportService {
        check(waitFor(timeoutMs) { service()?.isForeground == true }) { "ExportService did not enter the foreground" }
        return service()!!
    }

    /** Waits until the service has stopped. */
    fun awaitStopped(timeoutMs: Long = 15_000): Boolean = waitFor(timeoutMs) { service() == null }

    /** Our app's posted notification [id], or null. */
    fun notification(id: Int): StatusBarNotification? =
        app.getSystemService(NotificationManager::class.java).activeNotifications.firstOrNull { it.id == id }

    fun foregroundNotification(): StatusBarNotification? = notification(ExportNotification.FOREGROUND_ID)

    /** `dumpsys activity services <pkg>` of the test app (evidence of the FGS state and type). */
    fun dumpServices(): String = shell("dumpsys activity services ${app.packageName}")

    fun shell(command: String): String {
        val pfd = instrumentation.uiAutomation.executeShellCommand(command)
        val out = ByteArrayOutputStream()
        android.os.ParcelFileDescriptor.AutoCloseInputStream(pfd).use { it.copyTo(out) }
        return out.toString("UTF-8")
    }

    /** frame_counter_1080p30 at [w]x[h] for [frames] frames at 30 fps (no audio): a long enough export. */
    fun counterPlan(frames: Long, w: Int = 1280, h: Int = 720): RenderPlan {
        val g = FrameGrid.of(30)
        return RenderPlan(
            rev = 1, target = PlanTarget.EXPORT, canvas = PlanCanvas(w, h, 30), durUs = g.timeOfFrame(frames),
            assets = mapOf("md_src" to PlanAsset(PlanAssetKind.VIDEO, ExportPlans.media("frame_counter_1080p30.mp4"), fp = "fc1080", w = 1920, h = 1080, durUs = 8_000_000)),
            layers = listOf(ExportPlans.mediaLayer("it_v#v", 10, 0, FrameGrid.of(30), 0, frames, 0, 30, base = PlanSize(w.toDouble(), h.toDouble()))),
            audio = emptyList(),
        )
    }

    /** Whether [h] received a terminal event for [jobId]. */
    fun ended(h: ExportHarness, jobId: String): Boolean =
        h.events.any { it.jobId == jobId && (it.kind == EngineEventKindMsg.JOB_DONE || it.kind == EngineEventKindMsg.FAILURE) }

    /** A MediaStore row of our gallery insert. */
    data class GalleryRow(val id: Long, val name: String, val relativePath: String?, val pending: Int, val size: Long, val mime: String?)

    fun galleryRow(uri: Uri): GalleryRow? {
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.RELATIVE_PATH,
            MediaStore.MediaColumns.IS_PENDING,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.MIME_TYPE,
        )
        app.contentResolver.query(uri, projection, null, null, null)?.use { c ->
            if (!c.moveToFirst()) return null
            return GalleryRow(c.getLong(0), c.getString(1), c.getString(2), c.getInt(3), c.getLong(4), c.getString(5))
        }
        return null
    }

    /** Our rows under Movies/Danaview on the primary volume (a collection query, as a gallery does). */
    fun galleryIds(): List<Long> {
        val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val out = ArrayList<Long>()
        app.contentResolver.query(
            collection, arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?", arrayOf("Movies/Danaview%"), null,
        )?.use { c -> while (c.moveToNext()) out += c.getLong(0) }
        return out
    }

    fun galleryUri(id: Long): Uri = ContentUris.withAppendedId(MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), id)

    fun deleteGallery(uri: Uri) {
        try {
            app.contentResolver.delete(uri, null, null)
        } catch (e: RuntimeException) {
            Log.w(SERVICE_TEST_TAG, "gallery cleanup failed: $e")
        }
    }
}

/**
 * Detaches [h]'s event sink when an activity of this app is destroyed, as the plugin's Flutter
 * engine does when FlutterActivity goes away (no Dart listener → detached completion, D-39).
 */
class DetachOnDestroy(private val h: ExportHarness) : Application.ActivityLifecycleCallbacks {
    val destroyed = CountDownLatch(1)

    fun install() = ServiceTest.onMain { (ServiceTest.app as Application).registerActivityLifecycleCallbacks(this) }

    fun uninstall() = ServiceTest.onMain { (ServiceTest.app as Application).unregisterActivityLifecycleCallbacks(this) }

    fun awaitDestroyed(timeoutMs: Long): Boolean = destroyed.await(timeoutMs, TimeUnit.MILLISECONDS)

    override fun onActivityDestroyed(activity: Activity) {
        // ExportHarness.detach uses runOnMainSync, which must not run on main.
        Thread {
            h.detach()
            destroyed.countDown()
        }.start()
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}

    override fun onActivityStarted(activity: Activity) {}

    override fun onActivityResumed(activity: Activity) {}

    override fun onActivityPaused(activity: Activity) {}

    override fun onActivityStopped(activity: Activity) {}

    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
}
