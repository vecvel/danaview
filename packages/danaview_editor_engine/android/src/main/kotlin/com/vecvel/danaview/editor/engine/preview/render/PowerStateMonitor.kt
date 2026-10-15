// OWNER: AND-18
//
// The power/idle signal of the render-preview cache (ARCH §12.4 `PlatformServices.powerState`,
// D-45; INT-06 glue → RenderPreviewServices.power, called on main). UX-44 combines it with its own
// editor-idle timer for the automatic default on the minimal and low tiers.
//
// - charging: the sticky ACTION_BATTERY_CHANGED broadcast (EXTRA_STATUS charging or full, or
//   EXTRA_PLUGGED non-zero), updated by ACTION_POWER_CONNECTED / ACTION_POWER_DISCONNECTED and
//   ACTION_BATTERY_CHANGED.
// - lowPowerMode: PowerManager.isPowerSaveMode, updated by ACTION_POWER_SAVE_MODE_CHANGED.
// - The first [powerState] call starts watching (receivers registered on the application context,
//   delivered on main); every change of either value emits `signal(powerStateChanged, powerState)`
//   through the EventHub, once per change. [stop] unregisters (tests).
// Nothing user-related is logged.

package com.vecvel.danaview.editor.engine.preview.render

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.util.Log
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.fail
import com.vecvel.danaview.editor.engine.core.succeed
import com.vecvel.danaview.editor.engine.pigeon.PowerStateMsg
import com.vecvel.danaview.editor.engine.pigeon.SignalKindMsg
import com.vecvel.danaview.editor.engine.pigeon.SignalMsg

/** Charging and battery-saver state (file header). */
class PowerStateMonitor(private val ctx: EngineContext) {
    private val lock = Any()
    private var receiver: BroadcastReceiver? = null
    private var last: PowerStateMsg? = null

    /** The current charging and battery-saver state; starts watching for changes. */
    fun powerState(done: Completion<PowerStateMsg>) {
        try {
            start()
            done.succeed(read(null))
        } catch (t: Throwable) {
            done.fail(EngineErrors.from(t))
        }
    }

    /** Starts watching (idempotent); the current state becomes the baseline of change signals. */
    fun start() {
        synchronized(lock) {
            if (receiver != null) return
            last = read(null)
            val r = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) = onChanged(intent)
            }
            val filter = IntentFilter().apply {
                addAction(Intent.ACTION_POWER_CONNECTED)
                addAction(Intent.ACTION_POWER_DISCONNECTED)
                addAction(Intent.ACTION_BATTERY_CHANGED)
                addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
            }
            register(r, filter)
            receiver = r
        }
    }

    /** Stops watching (tests and teardown). */
    fun stop() {
        val r = synchronized(lock) {
            val r = receiver ?: return
            receiver = null
            r
        }
        try {
            ctx.appContext.unregisterReceiver(r)
        } catch (e: IllegalArgumentException) {
            Log.w(EngineContext.TAG, "power state receiver was not registered")
        }
    }

    /** Whether the monitor watches for changes. */
    val isWatching: Boolean get() = synchronized(lock) { receiver != null }

    /** A broadcast arrived (or a test injects one): emits a signal when the state changed. */
    internal fun onChanged(intent: Intent?) {
        val battery = intent?.takeIf { it.action == Intent.ACTION_BATTERY_CHANGED }
        val now = when (intent?.action) {
            // The connect broadcasts precede the sticky battery update; trust them.
            Intent.ACTION_POWER_CONNECTED -> read(null).copy(charging = true)
            Intent.ACTION_POWER_DISCONNECTED -> read(null).copy(charging = false)
            else -> read(battery)
        }
        emitIfChanged(now)
    }

    /** Emits `signal(powerStateChanged)` when [now] differs from the last state (tests call it). */
    internal fun emitIfChanged(now: PowerStateMsg) {
        synchronized(lock) {
            if (now == last) return
            last = now
            ctx.events.signal(SignalMsg(kind = SignalKindMsg.POWER_STATE_CHANGED, powerState = now))
        }
    }

    private fun read(battery: Intent?): PowerStateMsg {
        val app = ctx.appContext
        val sticky = battery ?: try {
            app.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        } catch (e: RuntimeException) {
            null
        }
        val pm = app.getSystemService(Context.POWER_SERVICE) as? PowerManager
        return PowerStateMsg(charging = PowerStates.charging(sticky), lowPowerMode = pm?.isPowerSaveMode == true)
    }

    private fun register(r: BroadcastReceiver, filter: IntentFilter) {
        val app = ctx.appContext
        // System broadcasts only; RECEIVER_EXPORTED is required to receive them on API 33+.
        if (Build.VERSION.SDK_INT >= 33) {
            app.registerReceiver(r, filter, Context.RECEIVER_EXPORTED)
        } else {
            app.registerReceiver(r, filter)
        }
    }
}

/** Battery broadcast → charging (pure; JVM-tested with values). */
object PowerStates {
    /** Whether the battery status or plug type of [battery] (ACTION_BATTERY_CHANGED) says charging. */
    fun charging(battery: Intent?): Boolean {
        if (battery == null) return false
        return charging(
            status = battery.getIntExtra(BatteryManager.EXTRA_STATUS, -1),
            plugged = battery.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0),
        )
    }

    /** Charging when [status] is CHARGING or FULL, or [plugged] names any power source. */
    fun charging(status: Int, plugged: Int): Boolean =
        status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL || plugged != 0
}
