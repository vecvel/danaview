// OWNER: AND-14
//
// Runtime permissions other than the microphone (ARCH §12.4, §15; BUILD_PLAN AND-14), plus the
// activity seam AND-14's services share (MediaPicker, Permissions).
//
// requestNotificationPermission: POST_NOTIFICATIONS exists from API 33; there it is requested in
// context through the plugin's permission-result routing (EngineContext.activityHost) and the
// answer is whether it is granted afterwards. Before API 33 there is no runtime prompt: the answer is
// NotificationManagerCompat.areNotificationsEnabled() (the user may have switched the app's
// notifications off in settings). Without an attached activity on API 33+ the current grant state
// is returned (no prompt is possible).

package com.vecvel.danaview.editor.engine.platform

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationManagerCompat
import com.vecvel.danaview.editor.engine.core.ActivityHost
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.succeed

/**
 * How AND-14's services reach the activity: activity results (pickers) and runtime permission
 * requests. Production routes through [ActivityHost] (the plugin's ActivityResult wiring);
 * instrumented tests substitute a relay that lets the real system UI answer. Main thread only.
 */
internal interface ActivityRequests {
    /** The current activity, or null. */
    val activity: Activity?

    /** Starts [intent] for a result; false (and [onResult] never called) without an activity. */
    fun startForResult(intent: Intent, onResult: (resultCode: Int, data: Intent?) -> Unit): Boolean

    /** Requests runtime [permissions]; false without an activity. Empty results mean cancelled. */
    fun requestPermissions(permissions: Array<String>, onResult: (Array<out String>, IntArray) -> Unit): Boolean
}

/** [ActivityRequests] over the plugin's [ActivityHost]. */
internal class HostActivityRequests(private val host: ActivityHost) : ActivityRequests {
    override val activity: Activity? get() = host.activity

    override fun startForResult(intent: Intent, onResult: (Int, Intent?) -> Unit): Boolean =
        host.startActivityForResult(intent, onResult)

    override fun requestPermissions(permissions: Array<String>, onResult: (Array<out String>, IntArray) -> Unit): Boolean =
        host.requestPermissions(permissions, onResult)
}

/** Runtime permissions other than the microphone (ARCH §15; AND-14). Called on main. */
class Permissions(private val ctx: EngineContext) {
    /** Activity seam (tests substitute it). */
    internal var requests: ActivityRequests = HostActivityRequests(ctx.activityHost)

    /** Requests POST_NOTIFICATIONS in context (API 33+); true when granted. */
    fun requestNotificationPermission(done: Completion<Boolean>) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return done.succeed(NotificationManagerCompat.from(ctx.appContext).areNotificationsEnabled())
        }
        if (notificationsGranted()) return done.succeed(true)
        val started = requests.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS)) { _, results ->
            done.succeed(results.firstOrNull() == PackageManager.PERMISSION_GRANTED || notificationsGranted())
        }
        if (!started) done.succeed(false)
    }

    /** Whether POST_NOTIFICATIONS is granted (API 33+; a seam for tests). */
    @SuppressLint("InlinedApi") // only called on API 33+
    internal var notificationsGranted: () -> Boolean = {
        ctx.appContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    }
}
