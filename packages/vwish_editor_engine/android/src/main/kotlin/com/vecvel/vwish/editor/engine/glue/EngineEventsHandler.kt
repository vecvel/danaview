// OWNER: ENG-08 (frozen by ENG-06, D-42)
//
// `EngineEventsApi` (@EventChannelApi, ARCH §12.6): one stream handler per Flutter engine. Dart's
// `engineEvents()` subscription (EngineEventRouter.start after initialize) attaches the engine's
// sink to the process EventHub; cancel detaches it. Flutter calls both on the main thread, where the
// hub also delivers.

package com.vecvel.vwish.editor.engine.glue

import com.vecvel.vwish.editor.engine.core.EngineEventSink
import com.vecvel.vwish.editor.engine.core.EventHub
import com.vecvel.vwish.editor.engine.pigeon.EngineEventMsg
import com.vecvel.vwish.editor.engine.pigeon.EngineEventsStreamHandler
import com.vecvel.vwish.editor.engine.pigeon.PigeonEventSink

/** Bridges the Pigeon event channel of one Flutter engine to the [EventHub]. */
class EngineEventsHandler(private val hub: EventHub) : EngineEventsStreamHandler() {
    private var sink: EngineEventSink? = null

    override fun onListen(p0: Any?, sink: PigeonEventSink<EngineEventMsg>) {
        this.sink?.let { hub.detach(it) }
        val bridge = EngineEventSink { event -> sink.success(event) }
        this.sink = bridge
        hub.attach(bridge)
        GlueLog.info("engine event stream: listener attached")
    }

    override fun onCancel(p0: Any?) {
        detach()
        GlueLog.info("engine event stream: listener cancelled")
    }

    /** Detaches from the hub (Flutter engine detached). */
    fun detach() {
        sink?.let { hub.detach(it) }
        sink = null
    }
}
