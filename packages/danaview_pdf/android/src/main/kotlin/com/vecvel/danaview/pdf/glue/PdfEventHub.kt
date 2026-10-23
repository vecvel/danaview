// OWNER: HOM-25
//
// The one native end of `PdfEventsApi.pdfEvents` on Android: tool jobs (HOM-28A onwards) emit
// through it; events are delivered on the main thread and dropped while Dart isn't listening.
// Texture views emit nothing here: their Dart controller owns page and zoom state
// (lib/src/pdf_view.dart `_TextureController.states`).

package com.vecvel.danaview.pdf.glue

import android.os.Handler
import android.os.Looper
import com.vecvel.danaview.pdf.pigeon.PdfEventMsg
import com.vecvel.danaview.pdf.pigeon.PdfEventsStreamHandler
import com.vecvel.danaview.pdf.pigeon.PigeonEventSink

class PdfEventHub(private val main: Handler = Handler(Looper.getMainLooper())) : PdfEventsStreamHandler() {
    // Touched on the main thread only.
    private var sink: PigeonEventSink<PdfEventMsg>? = null

    override fun onListen(p0: Any?, sink: PigeonEventSink<PdfEventMsg>) {
        this.sink = sink
    }

    override fun onCancel(p0: Any?) {
        sink = null
    }

    /** Sends [event] to Dart from any thread. */
    fun emit(event: PdfEventMsg) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            sink?.success(event)
        } else {
            main.post { sink?.success(event) }
        }
    }
}
