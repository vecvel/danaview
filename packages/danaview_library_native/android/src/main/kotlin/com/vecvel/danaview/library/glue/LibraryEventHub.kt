// OWNER: HOM-02A
//
// The one native end of `LibraryEventsApi.libraryEvents` on Android (ARCH v1.2 V2-111): every
// native class emits through it; events are delivered on the main thread and dropped while Dart
// isn't listening (Dart re-reads state when it subscribes).

package com.vecvel.danaview.library.glue

import android.os.Handler
import android.os.Looper
import com.vecvel.danaview.library.pigeon.LibraryEventMsg
import com.vecvel.danaview.library.pigeon.LibraryEventsStreamHandler
import com.vecvel.danaview.library.pigeon.PigeonEventSink

class LibraryEventHub(private val main: Handler = Handler(Looper.getMainLooper())) : LibraryEventsStreamHandler() {
    // Touched on the main thread only.
    private var sink: PigeonEventSink<LibraryEventMsg>? = null

    override fun onListen(p0: Any?, sink: PigeonEventSink<LibraryEventMsg>) {
        this.sink = sink
    }

    override fun onCancel(p0: Any?) {
        sink = null
    }

    /** Sends [event] to Dart from any thread. */
    fun emit(event: LibraryEventMsg) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            sink?.success(event)
        } else {
            main.post { sink?.success(event) }
        }
    }
}
