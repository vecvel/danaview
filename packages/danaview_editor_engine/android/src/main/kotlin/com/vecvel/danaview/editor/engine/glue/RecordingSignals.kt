// OWNER: INT-07
//
// The preview mutes while a voice recording captures (INT-07, ARCH §15): the recorder (AND-13)
// tells its listeners on main when capture starts (true) and ends (false); this bridge, installed
// once per process when the first Flutter engine attaches,
//  - emits the engine-wide `recordingChanged` event (Dart: `VoiceRecorder.recordingChanged`), once
//    per change, and
//  - mutes or unmutes every preview session (`PreviewSessionManager.setRecordingMuted`, which also
//    mutes sessions opened meanwhile; AND-16's audio decks set their player volume to 0).

package com.vecvel.danaview.editor.engine.glue

import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EventHub
import com.vecvel.danaview.editor.engine.pigeon.EngineEventKindMsg
import com.vecvel.danaview.editor.engine.pigeon.EngineEventMsg
import java.util.concurrent.atomic.AtomicBoolean

/** Recording state → `recordingChanged` events and the preview mute (file header). */
class RecordingSignals(private val hub: EventHub, private val mute: (Boolean) -> Unit) {
    private var last: Boolean? = null

    /** A capture started (true) or ended (false); duplicates are ignored. Called on main. */
    fun onRecording(active: Boolean) {
        synchronized(this) {
            if (last == active) return
            last = active
        }
        hub.emit(EngineEventMsg(kind = EngineEventKindMsg.RECORDING_CHANGED, recording = active))
        try {
            mute(active)
        } catch (t: Throwable) {
            GlueLog.warn("recording mute", t)
        }
    }

    companion object {
        private val installed = AtomicBoolean(false)

        /** Listens to the process recorder once per process. */
        fun installOnce(ctx: EngineContext) {
            if (!installed.compareAndSet(false, true)) return
            val signals = RecordingSignals(ctx.events) { muted -> ctx.previews.setRecordingMuted(muted) }
            ctx.recorder.addRecordingListener(signals::onRecording)
        }
    }
}
