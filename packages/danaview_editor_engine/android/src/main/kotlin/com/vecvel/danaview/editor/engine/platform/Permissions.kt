// OWNER: AND-14
//
// Runtime permissions other than the microphone (ARCH §12.4, §15; BUILD_PLAN AND-14), plus the
// activity seam AND-14's services share (MediaPicker, Permissions).
//
// requestNotificationPermission always completes, exactly once (owner rules, 2026-10-16):
//   1. below API 33 (no runtime prompt exists)          -> true at once
//   2. POST_NOTIFICATIONS already granted                -> true at once
//   3. no activity attached, or it is finishing/destroyed -> false at once
//   4. the activity is not resumed (paused/stopped)      -> false at once
//   5. a notification request of ours is still pending   -> false at once
//   6. permanently denied (see below)                    -> false at once
//   7. otherwise the system dialog is shown; the answer is the system's result. If the activity
//      that showed it is destroyed or recreated before the answer, the request completes with false
//      then and the late platform callback is ignored. An empty (cancelled) result is false.
// Rules 1-2 need no UI, so they answer first even without a usable activity.
//
// Permanently denied: Android gives no direct query. After a denial in the dialog
// shouldShowRequestPermissionRationale turns true; after the second denial ("Don't allow" again,
// the permission becomes user-fixed) it turns false again and later requests are auto-denied. So
// when a request comes back denied and the rationale was true before it and is false after it, a
// "permanently denied" flag is persisted (AND-14's own prefs). Rule 6 applies while that flag is set
// and the rationale is still false; a rationale of true or a grant (both happen when the user changes
// the permission in Settings) clears it. A first request dismissed without an answer (rationale
// false before and after) is not treated as permanent, so the prompt is offered again.
//
// Activity state: a LifecycleOwner activity (FlutterActivity, ComponentActivity) reports its own
// lifecycle state; for any other activity a process-wide ActivityLifecycleCallbacks tracker (also
// the source of the destroyed-while-asking signal) supplies it, and an activity it has not seen yet
// counts as resumed unless it is finishing or destroyed. The recorder's RECORD_AUDIO flow
// (recording/VoiceRecorder) is separate and unchanged.

package com.vecvel.danaview.editor.engine.platform

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import com.vecvel.danaview.editor.engine.core.ActivityHost
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.succeed
import java.util.WeakHashMap

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

/** The state of the activity a permission request would use. */
internal enum class RequestActivityState { NONE, GONE, PAUSED, RESUMED }

/** What [NotificationPermissionRules.decide] concluded. */
internal enum class NotificationDecision {
    /** Complete with true now. */
    GRANTED,

    /** Complete with false now. */
    DENIED,

    /** Show the system dialog. */
    ASK,
}

/** The pure rules of the notification permission request (JVM-tested). */
internal object NotificationPermissionRules {
    const val TIRAMISU = 33

    /**
     * The decision before any request (rules 1-6 of the file header). [rationale] is only
     * meaningful with a resumed activity (pass false otherwise).
     */
    fun decide(
        sdkInt: Int,
        granted: Boolean,
        activity: RequestActivityState,
        pending: Boolean,
        rationale: Boolean,
        permanentlyDeniedFlag: Boolean,
    ): NotificationDecision = when {
        sdkInt < TIRAMISU -> NotificationDecision.GRANTED
        granted -> NotificationDecision.GRANTED
        activity != RequestActivityState.RESUMED -> NotificationDecision.DENIED
        pending -> NotificationDecision.DENIED
        permanentlyDeniedFlag && !rationale -> NotificationDecision.DENIED
        else -> NotificationDecision.ASK
    }

    /**
     * The persisted "permanently denied" flag after a request came back not granted, given the
     * rationale before and after it: set by a denial that turned the rationale from true to false,
     * cleared by a rationale of true, otherwise unchanged.
     */
    fun permanentAfterDenial(previousFlag: Boolean, rationaleBefore: Boolean, rationaleAfter: Boolean): Boolean = when {
        rationaleAfter -> false
        rationaleBefore -> true
        else -> previousFlag
    }

    /** Whether the flag still holds before a request ([granted] or a rationale of true clears it). */
    fun permanentStillHolds(flag: Boolean, granted: Boolean, rationale: Boolean): Boolean = flag && !granted && !rationale
}

/**
 * The platform facts and actions the request flow needs; [Permissions] binds them to Android, JVM
 * tests fake them. Main thread only.
 */
internal interface NotificationPermissionEnv {
    val sdkInt: Int

    fun granted(): Boolean

    /** The activity a request would use (opaque to the flow), or null. */
    fun activity(): Any?

    fun activityState(activity: Any?): RequestActivityState

    fun rationale(activity: Any): Boolean

    var permanentlyDeniedFlag: Boolean

    /** Starts the system request; false when it could not be started. */
    fun request(onResult: (IntArray) -> Unit): Boolean

    /** Calls [onDestroyed] once if [activity] is destroyed (or recreated); returns the unregister action. */
    fun watchDestroyed(activity: Any, onDestroyed: () -> Unit): () -> Unit
}

/** The request flow: completes every request exactly once (file header rules). Main thread only. */
internal class NotificationPermissionFlow(private val env: NotificationPermissionEnv) {
    private var pending = false

    /** Whether a request of ours is waiting for the system's answer. */
    val isPending: Boolean get() = pending

    fun request(done: Completion<Boolean>) {
        if (env.sdkInt < NotificationPermissionRules.TIRAMISU) return done.succeed(true)
        val granted = env.granted()
        val activity = env.activity()
        val state = env.activityState(activity)
        val resumed = activity != null && state == RequestActivityState.RESUMED
        val rationaleBefore = resumed && env.rationale(activity!!)
        if (env.permanentlyDeniedFlag && (granted || resumed) &&
            !NotificationPermissionRules.permanentStillHolds(flag = true, granted = granted, rationale = rationaleBefore)
        ) {
            env.permanentlyDeniedFlag = false // changed in Settings since
        }
        when (
            NotificationPermissionRules.decide(
                sdkInt = env.sdkInt,
                granted = granted,
                activity = state,
                pending = pending,
                rationale = rationaleBefore,
                permanentlyDeniedFlag = env.permanentlyDeniedFlag,
            )
        ) {
            NotificationDecision.GRANTED -> return done.succeed(true)
            NotificationDecision.DENIED -> return done.succeed(false)
            NotificationDecision.ASK -> Unit
        }
        val owner = activity ?: return done.succeed(false)

        var completed = false
        var unwatch: () -> Unit = {}
        fun finish(value: Boolean) {
            if (completed) return // a late platform callback after destroy/recreate, or a second answer
            completed = true
            pending = false
            unwatch()
            done.succeed(value)
        }

        pending = true
        unwatch = env.watchDestroyed(owner) { finish(false) }
        val started = try {
            env.request { results ->
                if (completed) return@request
                if (results.isEmpty()) return@request finish(false)
                val ok = results[0] == PackageManager.PERMISSION_GRANTED || env.granted()
                if (!ok && env.activityState(owner) != RequestActivityState.GONE) {
                    val rationaleAfter = env.rationale(owner)
                    env.permanentlyDeniedFlag =
                        NotificationPermissionRules.permanentAfterDenial(env.permanentlyDeniedFlag, rationaleBefore, rationaleAfter)
                }
                if (ok) env.permanentlyDeniedFlag = false
                finish(ok)
            }
        } catch (e: RuntimeException) {
            Log.w(TAG, "notification permission request failed: ${e.javaClass.simpleName}")
            false
        }
        if (!started) finish(false)
    }

    private companion object {
        const val TAG = "DanaviewPermissions"
    }
}

/**
 * Lifecycle states of the process's activities, for activities that are not a [LifecycleOwner],
 * and destroyed notifications for the request flow. Registered once per process. Main thread only.
 */
internal object ActivityLifecycleTracker : Application.ActivityLifecycleCallbacks {
    private var registered = false
    private val states = WeakHashMap<Activity, RequestActivityState>()
    private val destroyedListeners = WeakHashMap<Activity, MutableList<() -> Unit>>()

    fun ensureRegistered(context: Context) {
        if (registered) return
        val app = context.applicationContext as? Application ?: return
        app.registerActivityLifecycleCallbacks(this)
        registered = true
    }

    /** The tracked state of [activity], or null when the tracker has not seen it. */
    fun stateOf(activity: Activity): RequestActivityState? = states[activity]

    fun onDestroyed(activity: Activity, listener: () -> Unit): () -> Unit {
        destroyedListeners.getOrPut(activity) { ArrayList() }.add(listener)
        return { destroyedListeners[activity]?.remove(listener) }
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
        states[activity] = RequestActivityState.PAUSED
    }

    override fun onActivityStarted(activity: Activity) {
        states[activity] = RequestActivityState.PAUSED
    }

    override fun onActivityResumed(activity: Activity) {
        states[activity] = RequestActivityState.RESUMED
    }

    override fun onActivityPaused(activity: Activity) {
        states[activity] = RequestActivityState.PAUSED
    }

    override fun onActivityStopped(activity: Activity) {
        states[activity] = RequestActivityState.PAUSED
    }

    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit

    override fun onActivityDestroyed(activity: Activity) {
        states[activity] = RequestActivityState.GONE
        destroyedListeners.remove(activity)?.toList()?.forEach { it() }
    }
}

/** Runtime permissions other than the microphone (ARCH §15; AND-14). Called on main. */
class Permissions(private val ctx: EngineContext) {
    init {
        ActivityLifecycleTracker.ensureRegistered(ctx.appContext)
    }

    /** Activity seam (tests substitute it). */
    internal var requests: ActivityRequests = HostActivityRequests(ctx.activityHost)

    /** The SDK level the rules see (a seam for tests). */
    internal var sdkInt: Int = Build.VERSION.SDK_INT

    /** Whether POST_NOTIFICATIONS is granted (API 33+; a seam for tests). */
    @SuppressLint("InlinedApi") // only called on API 33+
    internal var notificationsGranted: () -> Boolean = {
        ctx.appContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    }

    /** shouldShowRequestPermissionRationale(POST_NOTIFICATIONS) of [activity] (a seam for tests). */
    @SuppressLint("InlinedApi") // only called on API 33+
    internal var showRationale: (Activity) -> Boolean = { it.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS) }

    private val prefs: SharedPreferences by lazy { ctx.appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE) }

    private val env = object : NotificationPermissionEnv {
        override val sdkInt: Int get() = this@Permissions.sdkInt

        override fun granted() = notificationsGranted()

        override fun activity(): Any? = requests.activity

        override fun activityState(activity: Any?) = stateOf(activity as Activity?)

        override fun rationale(activity: Any) = showRationale(activity as Activity)

        override var permanentlyDeniedFlag: Boolean
            get() = prefs.getBoolean(KEY_PERMANENTLY_DENIED, false)
            set(value) {
                prefs.edit().putBoolean(KEY_PERMANENTLY_DENIED, value).apply()
            }

        @SuppressLint("InlinedApi") // only reached on API 33+
        override fun request(onResult: (IntArray) -> Unit): Boolean =
            requests.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS)) { _, results -> onResult(results) }

        override fun watchDestroyed(activity: Any, onDestroyed: () -> Unit) =
            ActivityLifecycleTracker.onDestroyed(activity as Activity, onDestroyed)
    }

    private val flow = NotificationPermissionFlow(env)

    /** Whether a notification request is waiting for the system's answer (tests). */
    internal val notificationRequestPending: Boolean get() = flow.isPending

    /** Requests POST_NOTIFICATIONS in context (API 33+); always completes once (file header rules). */
    fun requestNotificationPermission(done: Completion<Boolean>) = flow.request(done)

    private companion object {
        const val PREFS = "danaview_editor_permissions"
        const val KEY_PERMANENTLY_DENIED = "notifications_permanently_denied"

        fun stateOf(activity: Activity?): RequestActivityState {
            if (activity == null) return RequestActivityState.NONE
            if (activity.isFinishing || activity.isDestroyed) return RequestActivityState.GONE
            if (activity is LifecycleOwner) {
                val state = activity.lifecycle.currentState
                return when {
                    state == Lifecycle.State.DESTROYED -> RequestActivityState.GONE
                    state.isAtLeast(Lifecycle.State.RESUMED) -> RequestActivityState.RESUMED
                    else -> RequestActivityState.PAUSED
                }
            }
            return ActivityLifecycleTracker.stateOf(activity) ?: RequestActivityState.RESUMED
        }
    }
}
