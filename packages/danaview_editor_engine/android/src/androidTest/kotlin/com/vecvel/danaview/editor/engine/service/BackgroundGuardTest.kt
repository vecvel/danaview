// OWNER: AND-12
//
// Background-work lease lifecycle (BUILD_PLAN AND-12 "lease lifecycle"; ARCH §12.4, §15): acquire
// starts ExportService in the foreground (same FGS type rule as exports) with the lease's title and
// progress and no Cancel action; update moves the progress (<= 1 Hz); a second lease is counted;
// releasing the last lease stops the service and removes the notification; release is idempotent
// and updates of unknown leases are ignored; a refused service start answers null.

package com.vecvel.danaview.editor.engine.service

import android.app.Notification
import android.os.Build
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.export.ExportService
import com.vecvel.danaview.editor.engine.platform.FragmentRequests
import com.vecvel.danaview.editor.engine.platform.PlatformTestEngine
import com.vecvel.danaview.editor.engine.harness.PerfGate
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BackgroundGuardTest {
    private lateinit var ctx: EngineContext
    private var relay: FragmentRequests? = null

    @Before
    fun setUp() {
        ServiceTest.grantNotifications()
        ctx = PlatformTestEngine.create()
        relay = FragmentRequests.launch()
    }

    @After
    fun tearDown() {
        ServiceTest.onMain { ctx.backgroundGuard.activeLeases().forEach { l -> ctx.backgroundGuard.release(l.id) {} } }
        ExportService.unregister(ctx)
        relay?.finish()
        ServiceTest.awaitStopped()
        ctx.threads.shutdown()
    }

    private fun acquire(title: String): String? = ServiceTest.onMain {
        var id: Result<String?>? = null
        ctx.backgroundGuard.acquire(title) { id = it }
        id!!
    }.getOrThrow()

    private fun call(block: ((Result<Unit>) -> Unit) -> Unit) = ServiceTest.onMain {
        var r: Result<Unit>? = null
        block { r = it }
        r!!
    }.getOrThrow()

    private fun shownProgress(): Int? = ServiceTest.foregroundNotification()?.notification?.extras?.getInt(Notification.EXTRA_PROGRESS)

    private fun shownTitle(): String? = ServiceTest.foregroundNotification()?.notification?.extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString()

    @Test
    fun leaseLifecycle() {
        val first = acquire("Auto captions")
        assertNotNull(first)
        val svc = ServiceTest.awaitForeground()
        assertEquals(ExportService.foregroundServiceTypeFor(Build.VERSION.SDK_INT), svc.requestedForegroundType)
        if (Build.VERSION.SDK_INT >= 29) assertEquals(svc.requestedForegroundType, svc.foregroundServiceType)
        // Waits: as written with DV_PERF_STRICT=1, 4x on a loaded emulator (harness/PerfGate.kt).
        assertTrue(ServiceTest.waitFor(PerfGate.boundMs(5_000)) { shownTitle() == "Auto captions" })
        assertNull("no Cancel for a lease", ServiceTest.foregroundNotification()!!.notification.actions)

        call { ctx.backgroundGuard.update(first!!, 0.5, it) }
        assertTrue("progress 50% shown within the 1 s throttle", ServiceTest.waitFor(PerfGate.boundMs(3_000)) { shownProgress() == 50 })

        val second = acquire("Second job")
        assertNotNull(second)
        assertTrue(first != second)
        assertTrue(
            "the second lease is counted",
            ServiceTest.waitFor(PerfGate.boundMs(3_000)) { ServiceTest.foregroundNotification()?.notification?.extras?.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString() == "+1 more" },
        )

        call { ctx.backgroundGuard.release(first!!, it) }
        assertTrue(ServiceTest.waitFor(PerfGate.boundMs(3_000)) { shownTitle() == "Second job" })
        assertTrue("still in the foreground with one lease", ServiceTest.service()?.isForeground == true)

        call { ctx.backgroundGuard.release(second!!, it) }
        assertTrue("service stops with no lease left", ServiceTest.awaitStopped())
        assertNull("notification removed", ServiceTest.foregroundNotification())

        call { ctx.backgroundGuard.release(second!!, it) } // idempotent
        call { ctx.backgroundGuard.update("bg_unknown", 0.3, it) } // ignored
        assertTrue(ServiceTest.onMain { ctx.backgroundGuard.activeLeases().isEmpty() })
    }

    @Test
    fun refusedStartAnswersNull() {
        ServiceTest.onMain { ctx.backgroundGuard.startService = { false } }
        assertNull(acquire("Refused"))
        assertTrue(ServiceTest.onMain { ctx.backgroundGuard.activeLeases().isEmpty() })
    }
}
