// OWNER: AI-06
//
// Listens to `PowerManager` thermal status (API 29+; below that it never emits) and reports the
// mapped level through [onEvent]. The mapping itself is [ThermalMapper] (unit-tested).

package com.vecvel.danaview.whisper

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager

class ThermalMonitor(private val context: Context, private val onEvent: (Map<String, Any>) -> Unit) {
    private var listener: PowerManager.OnThermalStatusChangedListener? = null

    fun start() {
        if (Build.VERSION.SDK_INT < 29 || listener != null) return
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val main = Handler(Looper.getMainLooper())
        val l = PowerManager.OnThermalStatusChangedListener { status -> DeviceEvents.thermal(status)?.let(onEvent) }
        listener = l
        pm.addThermalStatusListener({ r -> main.post(r) }, l)
    }

    fun stop() {
        val l = listener ?: return
        listener = null
        if (Build.VERSION.SDK_INT >= 29) {
            (context.getSystemService(Context.POWER_SERVICE) as PowerManager).removeThermalStatusListener(l)
        }
    }
}
