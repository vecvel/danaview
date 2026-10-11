// OWNER: AND-14
//
// Notification permission flows (BUILD_PLAN AND-14: permission flows on API 33+; the API < 33 path
// runs on Pixel_API_29). Before API 33 there is no prompt: the answer is whether the app's
// notifications are enabled, and no request is made. On API 33+ a granted permission answers at
// once; otherwise the request goes through the activity seam, and the answer follows the system's
// result; no activity → false. realDialogDenyThenAllow drives the real system dialog and needs
// POST_NOTIFICATIONS revoked first, so it runs only with `-e danaviewNotificationDialog true`
// after `adb shell pm revoke <test pkg> android.permission.POST_NOTIFICATIONS` (and clearing its
// user-set/user-fixed flags); in a normal connected run it is skipped.

package com.vecvel.danaview.editor.engine.platform

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.vecvel.danaview.editor.engine.core.EngineContext
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
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
        }

        @AfterClass
        @JvmStatic
        fun tearDown() {
            ctx.threads.shutdown()
        }
    }

    private class FakeRequests(private val answer: Int?) : ActivityRequests {
        var asked = 0
        override val activity: Activity? = null
        override fun startForResult(intent: Intent, onResult: (Int, Intent?) -> Unit) = false
        override fun requestPermissions(permissions: Array<String>, onResult: (Array<out String>, IntArray) -> Unit): Boolean {
            asked++
            val a = answer ?: return false
            onResult(permissions, intArrayOf(a))
            return true
        }
    }

    private fun request(p: Permissions) = startOnMain<Boolean> { p.requestNotificationPermission(it) }.await().getOrThrow()

    @Test
    fun belowApi33AnswersWithoutPrompt() {
        assumeTrue("API < 33 path (run on Pixel_API_29)", Build.VERSION.SDK_INT < 33)
        val p = Permissions(ctx)
        val fake = FakeRequests(PackageManager.PERMISSION_DENIED)
        p.requests = fake
        assertEquals(NotificationManagerCompat.from(ctx.appContext).areNotificationsEnabled(), request(p))
        assertEquals("no runtime prompt before API 33", 0, fake.asked)
        Log.i("DanaviewPermissionsTest", "API ${Build.VERSION.SDK_INT}: notifications without prompt = ${request(p)}")
    }

    @Test
    fun api33PlusFollowsTheSystemAnswer() {
        assumeTrue("API 33+ path", Build.VERSION.SDK_INT >= 33)
        val granted = Permissions(ctx).apply { requests = FakeRequests(null); notificationsGranted = { true } }
        assertTrue(request(granted))

        val deniedFake = FakeRequests(PackageManager.PERMISSION_DENIED)
        val denied = Permissions(ctx).apply { requests = deniedFake; notificationsGranted = { false } }
        assertFalse(request(denied))
        assertEquals(1, deniedFake.asked)

        val allowed = Permissions(ctx).apply { requests = FakeRequests(PackageManager.PERMISSION_GRANTED); notificationsGranted = { false } }
        assertTrue(request(allowed))

        val noActivity = Permissions(ctx).apply { requests = FakeRequests(null); notificationsGranted = { false } }
        assertFalse(request(noActivity))
    }

    @Test
    fun realDialogDenyThenAllow() {
        assumeTrue(Build.VERSION.SDK_INT >= 33)
        assumeTrue(
            "run with -e danaviewNotificationDialog true after revoking POST_NOTIFICATIONS",
            InstrumentationRegistry.getArguments().getString("danaviewNotificationDialog") == "true",
        )
        assertEquals(PackageManager.PERMISSION_DENIED, ctx.appContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS))
        val relay = FragmentRequests.launch()
        try {
            val p = Permissions(ctx).apply { requests = relay }
            val first = startOnMain<Boolean> { p.requestNotificationPermission(it) }
            (SystemUi.waitAny(15_000, SystemUi.byText("(?i)don.t allow")) ?: error("no dialog:\n" + SystemUi.dump())).click()
            assertFalse(first.await().getOrThrow())
            val second = startOnMain<Boolean> { p.requestNotificationPermission(it) }
            (SystemUi.waitAny(15_000, SystemUi.byText("(?i)^allow$")) ?: error("no dialog:\n" + SystemUi.dump())).click()
            assertTrue(second.await().getOrThrow())
            assertEquals(PackageManager.PERMISSION_GRANTED, ctx.appContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS))
            Log.i("DanaviewPermissionsTest", "AND-14 real notification dialog on API ${Build.VERSION.SDK_INT}: deny -> false, allow -> true")
        } finally {
            relay.finish()
        }
    }
}
