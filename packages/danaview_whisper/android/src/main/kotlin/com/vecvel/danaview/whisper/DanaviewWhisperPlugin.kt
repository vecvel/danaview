// OWNER: AI-06
//
// Method channel `danaview_whisper/device` and event channel `danaview_whisper/device/events`
// (ai.md §4.8; names mirrored in lib/src/device/device_channel.dart and checked by a Dart test).
// Methods: deviceProfile, availableMemory, freeDiskBytes, isNetworkMetered, excludeFromBackup (a
// no-op that reports true: Android excludes the speech tree through the manifest backup rules,
// ARCH §8.1), beginBackgroundTask (n/a on Android: the engine's foreground service covers it,
// returns 0), endBackgroundTask. Events: thermal, memoryWarning, lowPower, lifecycle.
// Events are only wired while Dart listens.

package com.vecvel.danaview.whisper

import android.app.Activity
import android.app.Application
import android.content.BroadcastReceiver
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class DanaviewWhisperPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ComponentCallbacks2,
    Application.ActivityLifecycleCallbacks {

    private var context: Context? = null
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var profiler: DeviceProfiler? = null
    private var thermal: ThermalMonitor? = null
    private var sink: EventChannel.EventSink? = null
    private var powerReceiver: BroadcastReceiver? = null
    private var startedActivities = 0
    private val main = Handler(Looper.getMainLooper())
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ctx = binding.applicationContext
        context = ctx
        profiler = DeviceProfiler(ctx)
        thermal = ThermalMonitor(ctx, ::emit)
        methods = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).also { it.setStreamHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        onCancel(null)
        methods?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        methods = null
        events = null
        profiler = null
        thermal = null
        context = null
        worker.shutdown()
    }

    // ---- method channel -------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val p = profiler
        if (p == null) {
            result.error("unavailable", "plugin detached", null)
            return
        }
        when (call.method) {
            "deviceProfile" -> offload(result) { p.profile() }
            "availableMemory" -> offload(result) { p.availableMemory() }
            "freeDiskBytes" -> {
                val path = call.arguments as? String
                if (path == null) result.error("bad_args", "path required", null) else offload(result) { p.freeDiskBytes(path) }
            }
            "isNetworkMetered" -> offload(result) { p.isNetworkMetered() }
            "excludeFromBackup" -> result.success(true)
            "beginBackgroundTask" -> result.success(0)
            "endBackgroundTask" -> result.success(null)
            else -> result.notImplemented()
        }
    }

    private fun offload(result: MethodChannel.Result, block: () -> Any?) {
        try {
            worker.execute {
                val value = try {
                    block()
                } catch (e: Exception) {
                    main.post { result.error("failed", e.javaClass.simpleName, null) }
                    return@execute
                }
                main.post { result.success(value) }
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            result.error("unavailable", "plugin detached", null)
        }
    }

    // ---- event channel --------------------------------------------------------------------

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val ctx = context ?: return
        sink = events
        thermal?.start()
        ctx.registerComponentCallbacks(this)
        (ctx.applicationContext as? Application)?.registerActivityLifecycleCallbacks(this)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                val pm = c.getSystemService(Context.POWER_SERVICE) as PowerManager
                emit(DeviceEvents.lowPower(pm.isPowerSaveMode))
            }
        }
        powerReceiver = receiver
        ctx.registerReceiver(receiver, IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED))
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        thermal?.stop()
        val ctx = context ?: return
        ctx.unregisterComponentCallbacks(this)
        (ctx.applicationContext as? Application)?.unregisterActivityLifecycleCallbacks(this)
        powerReceiver?.let {
            try {
                ctx.unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {
            }
        }
        powerReceiver = null
        startedActivities = 0
    }

    private fun emit(event: Map<String, Any>) {
        if (Looper.myLooper() == Looper.getMainLooper()) sink?.success(event) else main.post { sink?.success(event) }
    }

    // ---- ComponentCallbacks2 --------------------------------------------------------------

    override fun onTrimMemory(level: Int) {
        if (TrimLevels.isMemoryWarning(level)) emit(DeviceEvents.memoryWarning())
    }

    override fun onConfigurationChanged(newConfig: Configuration) {}

    @Deprecated("Deprecated in ComponentCallbacks")
    override fun onLowMemory() {
        emit(DeviceEvents.memoryWarning())
    }

    // ---- app visibility: background when the last started Activity stops ------------------

    override fun onActivityStarted(activity: Activity) {
        startedActivities += 1
        if (startedActivities == 1) emit(DeviceEvents.lifecycle(background = false))
    }

    override fun onActivityStopped(activity: Activity) {
        startedActivities = maxOf(0, startedActivities - 1)
        if (startedActivities == 0) emit(DeviceEvents.lifecycle(background = true))
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
    override fun onActivityResumed(activity: Activity) {}
    override fun onActivityPaused(activity: Activity) {}
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
    override fun onActivityDestroyed(activity: Activity) {}

    companion object {
        const val CHANNEL = "danaview_whisper/device"
        const val EVENT_CHANNEL = "danaview_whisper/device/events"
    }
}
