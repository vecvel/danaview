// OWNER: AND-14
//
// Notification permission request on the emulator: it always completes, exactly once (owner rules
// 2026-10-16; platform/Permissions.kt header; the decision logic is JVM-tested in
// test/.../NotificationPermissionFlowTest.kt). Here: below API 33 -> true without a prompt (runs on
// Pixel_API_29); already granted -> true without an activity; no activity -> false; a paused
// (backgrounded) activity -> false without a request; a pending request -> false while the first
// still completes; the activity destroyed, or recreated, while the request is up -> false at once
// and the late callback ignored; permanently denied -> false without a request; the system's answer.
//
// realDialogDestroyedThenDenyThenAllow drives the real system dialog and needs POST_NOTIFICATIONS
// revoked first, so it runs only with `-e danaviewNotificationDialog true` after
// `adb shell pm revoke <test pkg> android.permission.POST_NOTIFICATIONS` and
// `adb shell pm clear-permission-flags <test pkg> android.permission.POST_NOTIFICATIONS user-set user-fixed`;
// in a normal connected run it is skipped.

package com.vecvel.danaview.editor.engine.platform

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import com.vecvel.danaview.editor.engine.core.EngineContext
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PermissionsTest {
    companion object {
        private lateinit var ctx: EngineContext

        @BeforeClass
        @JvmStatic
        fun setUp() {
            ctx = PlatformTestEngine.create()
            // Registers the process-wide lifecycle tracker before any test activity starts.
            InstrumentationRegistry.getInstrumentation().runOnMainSync { Permissions(ctx) }
        }

        @AfterClass
        @JvmStatic
        fun tearDown() {
            ctx.threads.shutdown()
        }
    }

    @Before
    fun clearPermissionState() {
        ctx.appContext.getSharedPreferences("danaview_editor_permissions", Context.MODE_PRIVATE).edit().clear().commit()
    }

    /** Requests over [activity] (null = none); the system dialog is never shown, the test answers. */
    private class CapturingRequests(override val activity: Activity?, private val start: Boolean = true) : ActivityRequests {
        var asked = 0
        var callback: ((Array<out String>, IntArray) -> Unit)? = null

        override fun startForResult(intent: Intent, onResult: (Int, Intent?) -> Unit) = false

        override fun requestPermissions(permissions: Array<String>, onResult: (Array<out String>, IntArray) -> Unit): Boolean {
            asked++
            if (activity == null || !start) return false
            callback = onResult
            return true
        }

        fun answer(result: Int) = InstrumentationRegistry.getInstrumentation().runOnMainSync {
            callback!!(arrayOf(Manifest.permission.POST_NOTIFICATIONS), intArrayOf(result))
        }
    }

    private fun permissions(requests: ActivityRequests, granted: Boolean = false, rationale: Boolean = false) =
        onMainValue {
            Permissions(ctx).apply {
                this.requests = requests
                notificationsGranted = { granted }
                showRationale = { rationale }
            }
        }

    private fun start(p: Permissions) = startOnMain<Boolean> { p.requestNotificationPermission(it) }

    private fun request(p: Permissions) = start(p).await(5_000).getOrThrow()

    private fun api33() = assumeTrue("API 33+ path", Build.VERSION.SDK_INT >= 33)

    @Test
    fun belowApi33AnswersTrueWithoutPrompt() {
        assumeTrue("API < 33 path (run on Pixel_API_29)", Build.VERSION.SDK_INT < 33)
        val none = CapturingRequests(null)
        assertTrue(request(permissions(none, granted = false)))
        val relay = FragmentRequests.launch()
        try {
            val fake = CapturingRequests(relay.activity)
            assertTrue(request(permissions(fake, granted = false)))
            assertEquals("no runtime prompt before API 33", 0, fake.asked + none.asked)
        } finally {
            relay.finish()
        }
        Log.i("DanaviewPermissionsTest", "API ${Build.VERSION.SDK_INT}: notification request -> true without prompt")
    }

    @Test
    fun alreadyGrantedIsTrueWithoutAnActivity() {
        api33()
        val fake = CapturingRequests(null)
        assertTrue(request(permissions(fake, granted = true)))
        assertEquals(0, fake.asked)
        if (ctx.appContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            val real = onMainValue { Permissions(ctx).apply { requests = fake } } // the real granted check
            assertTrue(request(real))
            assertEquals(0, fake.asked)
        }
    }

    @Test
    fun noActivityIsFalse() {
        api33()
        val fake = CapturingRequests(null)
        assertFalse(request(permissions(fake)))
        assertEquals(0, fake.asked)
    }

    @Test
    fun backgroundedActivityIsFalseWithoutRequest() {
        api33()
        val relay = FragmentRequests.launch()
        try {
            SystemUi.device.pressHome()
            val stopped = waitFor(10_000) { onMainValue { stageOf(relay.activity) } in setOf(Stage.PAUSED, Stage.STOPPED) }
            assertTrue("activity paused after Home", stopped)
            val fake = CapturingRequests(relay.activity)
            assertFalse(request(permissions(fake)))
            assertEquals("no request from a paused activity", 0, fake.asked)
        } finally {
            relay.finish()
        }
    }

    @Test
    fun pendingRequestIsFalseAndTheFirstStillCompletes() {
        api33()
        val relay = FragmentRequests.launch()
        try {
            val fake = CapturingRequests(relay.activity)
            val p = permissions(fake)
            val first = start(p)
            assertFalse(first.isDone)
            assertTrue(onMainValue { p.notificationRequestPending })
            assertFalse("second request while pending", request(p))
            assertEquals(1, fake.asked)
            fake.answer(PackageManager.PERMISSION_GRANTED)
            assertTrue(first.await(5_000).getOrThrow())
            assertFalse(onMainValue { p.notificationRequestPending })
        } finally {
            relay.finish()
        }
    }

    @Test
    fun activityDestroyedWhileAskingIsFalseOnce() {
        api33()
        val relay = FragmentRequests.launch()
        val fake = CapturingRequests(relay.activity)
        val p = permissions(fake)
        val answers = ArrayList<Boolean>()
        val first = startOnMain<Boolean> { done -> p.requestNotificationPermission { r -> answers.add(r.getOrThrow()); done(r) } }
        relay.finish()
        assertFalse("destroyed while asking", first.await(10_000).getOrThrow())
        fake.answer(PackageManager.PERMISSION_GRANTED) // the late platform callback
        onMain { }
        assertEquals("completed exactly once", listOf(false), answers)
        assertFalse(onMainValue { p.notificationRequestPending })
    }

    @Test
    fun activityRecreatedWhileAskingIsFalseOnce() {
        api33()
        val relay = FragmentRequests.launch()
        try {
            val fake = CapturingRequests(relay.activity)
            val p = permissions(fake)
            val answers = ArrayList<Boolean>()
            val first = startOnMain<Boolean> { done -> p.requestNotificationPermission { r -> answers.add(r.getOrThrow()); done(r) } }
            onMain { relay.activity.recreate() }
            assertFalse("recreated while asking", first.await(10_000).getOrThrow())
            fake.answer(PackageManager.PERMISSION_GRANTED) // the recreated activity delivers the old result
            onMain { }
            assertEquals("completed exactly once", listOf(false), answers)
        } finally {
            finishAllTestActivities()
        }
    }

    @Test
    fun requestThatCannotStartIsFalse() {
        api33()
        val relay = FragmentRequests.launch()
        try {
            val fake = CapturingRequests(relay.activity, start = false)
            val p = permissions(fake)
            assertFalse(request(p))
            assertEquals(1, fake.asked)
            assertFalse(onMainValue { p.notificationRequestPending })
        } finally {
            relay.finish()
        }
    }

    @Test
    fun permanentlyDeniedIsFalseWithoutRequest() {
        api33()
        val relay = FragmentRequests.launch()
        try {
            // first denial: rationale false -> true; second denial: true -> false = permanent
            var rationale = false
            val fake = CapturingRequests(relay.activity)
            val p = onMainValue {
                Permissions(ctx).apply {
                    requests = fake
                    notificationsGranted = { false }
                    showRationale = { rationale }
                }
            }
            val first = start(p)
            rationale = true
            fake.answer(PackageManager.PERMISSION_DENIED)
            assertFalse(first.await(5_000).getOrThrow())
            val second = start(p)
            rationale = false
            fake.answer(PackageManager.PERMISSION_DENIED)
            assertFalse(second.await(5_000).getOrThrow())
            assertEquals(2, fake.asked)
            assertFalse("permanently denied", request(p))
            assertEquals("no request once permanently denied", 2, fake.asked)
            // the flag is persisted: a new instance answers at once too
            val again = CapturingRequests(relay.activity)
            assertFalse(request(permissions(again, rationale = false)))
            assertEquals(0, again.asked)
            // enabled again in Settings: granted answers true and clears the flag
            assertTrue(request(permissions(again, granted = true)))
            val after = CapturingRequests(relay.activity)
            val asked = start(permissions(after))
            assertEquals("asked again after the flag cleared", 1, after.asked)
            after.answer(PackageManager.PERMISSION_GRANTED)
            assertTrue(asked.await(5_000).getOrThrow())
        } finally {
            relay.finish()
        }
    }

    @Test
    fun realDialogDestroyedThenDenyThenAllow() {
        api33()
        assumeTrue(
            "run with -e danaviewNotificationDialog true after revoking POST_NOTIFICATIONS",
            InstrumentationRegistry.getArguments().getString("danaviewNotificationDialog") == "true",
        )
        assertEquals(PackageManager.PERMISSION_DENIED, ctx.appContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS))
        val deny = arrayOf(SystemUi.byRes(".*permissioncontroller:id/permission_deny_button"), SystemUi.byText("(?i)don.t allow"))
        val allow = arrayOf(SystemUi.byRes(".*permissioncontroller:id/permission_allow_button"), SystemUi.byText("(?i)^allow$"))

        // 1. the activity is destroyed while the real dialog is up -> false at once
        val gone = FragmentRequests.launch()
        val p0 = onMainValue { Permissions(ctx).apply { requests = gone } }
        val answers = ArrayList<Boolean>()
        val destroyed = startOnMain<Boolean> { done -> p0.requestNotificationPermission { r -> answers.add(r.getOrThrow()); done(r) } }
        SystemUi.waitAny(15_000, *deny) ?: error("no dialog:\n" + SystemUi.dump())
        gone.finish()
        assertFalse("destroyed while the dialog is up", destroyed.await(15_000).getOrThrow())
        if (SystemUi.waitAny(2_000, *deny) != null) SystemUi.device.pressBack()
        Thread.sleep(1_000)
        assertEquals("completed exactly once", listOf(false), answers)

        // 2. deny -> false, 3. allow -> true
        val relay = FragmentRequests.launch()
        try {
            val p = onMainValue { Permissions(ctx).apply { requests = relay } }
            val first = start(p)
            (SystemUi.waitAny(15_000, *deny) ?: error("no dialog:\n" + SystemUi.dump())).click()
            assertFalse("denied in the dialog", first.await().getOrThrow())
            assertEquals(PackageManager.PERMISSION_DENIED, ctx.appContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS))
            val second = start(p)
            (SystemUi.waitAny(15_000, *allow) ?: error("no dialog:\n" + SystemUi.dump())).click()
            assertTrue("allowed in the dialog", second.await().getOrThrow())
            assertEquals(PackageManager.PERMISSION_GRANTED, ctx.appContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS))
            Log.i(
                "DanaviewPermissionsTest",
                "AND-14 real notification dialog on API ${Build.VERSION.SDK_INT}: destroyed -> false, deny -> false, allow -> true",
            )
        } finally {
            relay.finish()
        }
    }

    // ---- helpers ----

    private fun onMain(block: () -> Unit) = InstrumentationRegistry.getInstrumentation().runOnMainSync(block)

    private fun <T> onMainValue(block: () -> T): T {
        var value: T? = null
        onMain { value = block() }
        @Suppress("UNCHECKED_CAST")
        return value as T
    }

    private fun stageOf(activity: Activity): Stage? =
        Stage.values().firstOrNull { ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(it).contains(activity) }

    private fun waitFor(timeoutMs: Long, condition: () -> Boolean): Boolean {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            if (condition()) return true
            Thread.sleep(100)
        }
        return condition()
    }

    private fun finishAllTestActivities() = onMain {
        val monitor = ActivityLifecycleMonitorRegistry.getInstance()
        for (stage in listOf(Stage.RESUMED, Stage.STARTED, Stage.PAUSED, Stage.STOPPED, Stage.CREATED)) {
            monitor.getActivitiesInStage(stage).forEach { it.finish() }
        }
    }
}
