// OWNER: AND-12
//
// Device-independent rules of AND-12 (run on the emulator because the ticket owns no JVM test
// directory): the notification throttle keeps updates at <= 1 Hz with a trailing update, the
// foreground service type per API level (mediaProcessing 35+, dataSync 29-34), the notification
// content (percent, Cancel only for exports), and the handoff MIME types.

package com.vecvel.danaview.editor.engine.service

import android.app.Notification
import android.content.pm.ServiceInfo
import androidx.core.app.NotificationCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.Cancellable
import com.vecvel.danaview.editor.engine.export.ExportNotification
import com.vecvel.danaview.editor.engine.export.ExportService
import com.vecvel.danaview.editor.engine.export.ForegroundContent
import com.vecvel.danaview.editor.engine.export.NotificationThrottle
import com.vecvel.danaview.editor.engine.platform.FileHandoff
import com.vecvel.danaview.editor.engine.platform.MediaStoreSaver
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ServiceLogicTest {
    private class FakeTimer {
        var now = 0L
        val tasks = ArrayList<Pair<Long, Runnable>>()

        fun schedule(task: Runnable, delay: Long): Cancellable {
            val entry = (now + delay) to task
            tasks += entry
            return Cancellable { tasks.remove(entry) }
        }

        fun advance(ms: Long) {
            val target = now + ms
            while (true) {
                val next = tasks.minByOrNull { it.first } ?: break
                if (next.first > target) break
                tasks.remove(next)
                now = next.first
                next.second.run()
            }
            now = target
        }
    }

    @Test
    fun throttleRunsAtMostOncePerSecondWithTrailingUpdate() {
        val t = FakeTimer()
        val throttle = NotificationThrottle(1_000, { t.now }) { r, d -> t.schedule(r, d) }
        val shown = ArrayList<Pair<Long, Int>>()
        // 4 Hz progress for 5 s (as the coordinator reports), value = sample index.
        for (i in 0 until 20) {
            throttle.submit { shown += t.now to i }
            t.advance(250)
        }
        t.advance(2_000)
        val times = shown.map { it.first }
        for (k in 1 until times.size) assertTrue("updates ${times[k - 1]} -> ${times[k]} closer than 1 s", times[k] - times[k - 1] >= 1_000)
        assertEquals("first sample at once", 0L to 0, shown.first())
        assertEquals("the trailing update shows the last sample", 19, shown.last().second)
        assertTrue("about 1 Hz (${shown.size} updates in 5 s)", shown.size in 5..7)
        assertEquals(shown.size, throttle.runs)
    }

    @Test
    fun throttleFlushAndClear() {
        val t = FakeTimer()
        val throttle = NotificationThrottle(1_000, { t.now }) { r, d -> t.schedule(r, d) }
        var value = -1
        throttle.submit { value = 0 }
        t.advance(100)
        throttle.submit { value = 1 }
        assertEquals(0, value)
        throttle.flush()
        assertEquals(1, value)
        t.advance(100)
        throttle.submit { value = 2 }
        throttle.clear()
        t.advance(5_000)
        assertEquals("a cleared update never runs", 1, value)
        assertTrue(t.tasks.isEmpty())
    }

    @Test
    fun foregroundTypePerApiLevel() {
        assertEquals(0, ExportService.foregroundServiceTypeFor(28))
        for (api in 29..34) assertEquals("API $api", ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC, ExportService.foregroundServiceTypeFor(api))
        assertEquals(0x2000, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING)
        for (api in 35..37) assertEquals("API $api", ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING, ExportService.foregroundServiceTypeFor(api))
    }

    @Test
    fun foregroundNotificationContent() {
        val n = ExportNotification(ServiceTest.app)
        val export = n.foreground(ForegroundContent("My trip", 0.426, "ex_1"))
        assertEquals("My trip", export.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
        assertEquals(100, export.extras.getInt(Notification.EXTRA_PROGRESS_MAX))
        assertEquals(43, export.extras.getInt(Notification.EXTRA_PROGRESS))
        assertFalse(export.extras.getBoolean(Notification.EXTRA_PROGRESS_INDETERMINATE))
        assertTrue("ongoing", export.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertEquals(1, export.actions.size)
        assertEquals(ExportNotification.CANCEL_LABEL, export.actions[0].title.toString())
        assertEquals(ExportNotification.CHANNEL_PROGRESS, NotificationCompat.getChannelId(export))

        val lease = n.foreground(ForegroundContent("", 0.5, null, isExport = false))
        assertEquals(ExportNotification.DEFAULT_WORK_TITLE, lease.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
        assertNull("no Cancel for a lease", lease.actions)

        assertEquals(0, ForegroundContent("x", -1.0, null).percent)
        assertEquals(100, ForegroundContent("x", 2.0, null).percent)
        assertNull(ForegroundContent("x", null, null).percent)
    }

    @Test
    fun mimeTypes() {
        assertEquals("video/mp4", MediaStoreSaver.mimeTypeOf("a.mp4"))
        assertEquals("video/quicktime", MediaStoreSaver.mimeTypeOf("a.MOV"))
        assertEquals("video/mp4", FileHandoff.mimeTypeOf("Export (2).mp4"))
        assertEquals("application/x-subrip", FileHandoff.mimeTypeOf("captions.srt"))
        assertEquals("text/vtt", FileHandoff.mimeTypeOf("captions.vtt"))
        assertEquals("application/octet-stream", FileHandoff.mimeTypeOf("noext"))
        assertEquals("Movies/Danaview", MediaStoreSaver.RELATIVE_PATH)
    }
}
