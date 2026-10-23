// OWNER: HOM-02A
//
// What every Android class of danaview_library_native shares: the application context, the
// current Activity (ActivityAware), runtime permission requests routed through the activity
// binding, the main-thread handler replies hop to, and the library event hub. Later tickets
// (pickers HOM-20A, save out / share / open in HOM-22A, incoming HOM-21A) register their
// activity-result listeners here too.

package com.vecvel.danaview.library.glue

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.PluginRegistry

class LibraryPluginContext(
    val appContext: Context,
    val messenger: BinaryMessenger,
    val events: LibraryEventHub,
) : PluginRegistry.RequestPermissionsResultListener, PluginRegistry.ActivityResultListener {
    val main: Handler = Handler(Looper.getMainLooper())

    // Main thread only below.
    private var binding: ActivityPluginBinding? = null
    private val permissionCallbacks = HashMap<Int, (Map<String, Boolean>) -> Unit>()
    private val activityResultCallbacks = HashMap<Int, (Int, Intent?) -> Unit>()
    private val activityListeners = ArrayList<(Activity?) -> Unit>()
    private val bindingListeners = ArrayList<(ActivityPluginBinding?) -> Unit>()

    /** The current Activity, or null while the plugin has none (background engine, rotation). */
    val activity: Activity? get() = binding?.activity

    fun attach(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addRequestPermissionsResultListener(this)
        binding.addActivityResultListener(this)
        activityListeners.toList().forEach { it(binding.activity) }
        bindingListeners.toList().forEach { it(binding) }
    }

    fun detach() {
        binding?.removeRequestPermissionsResultListener(this)
        binding?.removeActivityResultListener(this)
        binding = null
        // A request whose activity went away answers "nothing granted"; the caller re-reads state.
        val pending = permissionCallbacks.values.toList()
        permissionCallbacks.clear()
        pending.forEach { it(emptyMap()) }
        val results = activityResultCallbacks.values.toList()
        activityResultCallbacks.clear()
        results.forEach { it(Activity.RESULT_CANCELED, null) }
        activityListeners.toList().forEach { it(null) }
        bindingListeners.toList().forEach { it(null) }
    }

    /** Called with the new Activity (or null) whenever it changes. Main thread. */
    fun addActivityListener(listener: (Activity?) -> Unit) {
        activityListeners.add(listener)
    }

    /**
     * Called with the new activity binding (or null) whenever it changes, synchronously inside
     * onAttachedToActivity: incoming intents (HOM-21A) add their new-intent and saved-state
     * listeners there, before MainActivity reads its intent. Main thread.
     */
    fun addBindingListener(listener: (ActivityPluginBinding?) -> Unit) {
        bindingListeners.add(listener)
    }

    /**
     * Requests [permissions] from the current Activity; [done] gets permission → granted (empty
     * when there was no Activity or it went away). False when a request with [requestCode] is
     * already running or there is no Activity. Main thread.
     */
    fun requestPermissions(requestCode: Int, permissions: Array<String>, done: (Map<String, Boolean>) -> Unit): Boolean {
        val activity = activity ?: return false
        if (permissionCallbacks.containsKey(requestCode)) return false
        permissionCallbacks[requestCode] = done
        activity.requestPermissions(permissions, requestCode)
        return true
    }

    /** Starts [intent] for a result; [done] gets (resultCode, data). False without an Activity. Main thread. */
    fun startActivityForResult(requestCode: Int, intent: Intent, done: (Int, Intent?) -> Unit): Boolean {
        val activity = activity ?: return false
        if (activityResultCallbacks.containsKey(requestCode)) return false
        activityResultCallbacks[requestCode] = done
        try {
            activity.startActivityForResult(intent, requestCode)
        } catch (e: RuntimeException) {
            activityResultCallbacks.remove(requestCode)
            throw e
        }
        return true
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        val done = permissionCallbacks.remove(requestCode) ?: return false
        val result = HashMap<String, Boolean>()
        for (i in permissions.indices) {
            result[permissions[i]] = grantResults.getOrNull(i) == android.content.pm.PackageManager.PERMISSION_GRANTED
        }
        done(result)
        return true
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val done = activityResultCallbacks.remove(requestCode) ?: return false
        done(resultCode, data)
        return true
    }

    companion object {
        /** Request codes of this plugin (distinct from the editor engine's and Flutter's). */
        const val REQUEST_PHOTO_PERMISSIONS = 0x4C10
    }
}
