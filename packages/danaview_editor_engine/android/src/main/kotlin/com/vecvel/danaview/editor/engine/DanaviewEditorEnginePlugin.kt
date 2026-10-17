// OWNER: ENG-08 (then ENG-06 [INTEGRATION], frozen; D-42)
//
// The editor engine plugin (ARCH §4.4, §12.6). On attach it installs the Pigeon host APIs and the
// event stream (glue/GlueRegistrar) over the process-scoped EngineContext; as an ActivityAware
// plugin it hands the activity and Flutter's activity-result and permission-result callbacks to
// EngineContext.activityHost (pickers, SAF, share, runtime permissions: AND-12..AND-15).
// Service classes are D-33 placeholders until their tickets land: capabilities() reports
// `engine_not_available` (supported = false) and other calls fail with `notSupportedOnDevice`.

package com.vecvel.danaview.editor.engine

import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.glue.GlueRegistrar
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding

/** Flutter plugin entry point of the editor engine. */
class DanaviewEditorEnginePlugin : FlutterPlugin, ActivityAware {
    private var ctx: EngineContext? = null
    private var glue: GlueRegistrar? = null
    private var activityBinding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = EngineContext.obtain(binding.applicationContext)
        ctx = context
        glue = GlueRegistrar.attach(context, binding.binaryMessenger, binding.textureRegistry)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        glue?.detach()
        glue = null
        ctx = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) = attachActivity(binding)

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = attachActivity(binding)

    /** A configuration change keeps pending activity requests; the new activity delivers their results. */
    override fun onDetachedFromActivityForConfigChanges() = detachActivity(cancelPending = false)

    override fun onDetachedFromActivity() = detachActivity(cancelPending = true)

    private fun attachActivity(binding: ActivityPluginBinding) {
        val host = ctx?.activityHost ?: return
        activityBinding = binding
        host.attach(binding)
        binding.addActivityResultListener(host.resultListener)
        binding.addRequestPermissionsResultListener(host.permissionListener)
    }

    private fun detachActivity(cancelPending: Boolean) {
        val host = ctx?.activityHost
        activityBinding?.let { binding ->
            if (host != null) {
                binding.removeActivityResultListener(host.resultListener)
                binding.removeRequestPermissionsResultListener(host.permissionListener)
            }
        }
        activityBinding = null
        host?.detach(cancelPending)
    }
}
