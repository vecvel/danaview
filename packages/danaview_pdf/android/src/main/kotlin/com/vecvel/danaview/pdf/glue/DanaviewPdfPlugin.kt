// OWNER: HOM-25
// EXTENDED: HOM-28A (PdfOrganiseHostApi; tool jobs emit progress through the event hub).
//
// The Android glue of danaview_pdf (ARCH v1.2 V2-25, §8): registers every host API of the frozen
// Pigeon surface (pigeons/pdf_api.dart) and the PDF event stream, routing each API to one class:
//
//   PdfDocumentHostApi → glue/PdfDocumentHostApiImpl  (over viewer/PdfDocumentStore; HOM-25)
//   PdfViewHostApi     → viewer/PdfViewHostApiImpl    (texture views; HOM-25)
//   PdfTextHostApi     → text/PdfTextHostApiImpl      (PdfBox text; HOM-25)
//   PdfToolsHostApi    → glue/PdfToolsHostApiImpl     (tools/ HOM-28A, annotate/ HOM-29A,
//                                                      sign/ HOM-30A, compress/ HOM-31A)
//   PdfOrganiseHostApi → glue/PdfToolsHostApiImpl     (tools/ HOM-28A; same jobs and cancel)
//   PdfEventsApi       → glue/PdfEventHub
//
// PdfBox-Android's resources are loaded once at attach (2-4 ms, HOM-27); a few seconds later a
// one-off background warm-up (viewer/PdfWarmUp.kt) runs the PDF code paths on a built-in tiny PDF.
// Detach disposes every texture view, closes every document and stops the plugin's threads.

package com.vecvel.danaview.pdf.glue

import android.os.Process
import com.vecvel.danaview.pdf.pigeon.PdfDocumentHostApi
import com.vecvel.danaview.pdf.pigeon.PdfEventsStreamHandler
import com.vecvel.danaview.pdf.pigeon.PdfOrganiseHostApi
import com.vecvel.danaview.pdf.pigeon.PdfTextHostApi
import com.vecvel.danaview.pdf.pigeon.PdfToolsHostApi
import com.vecvel.danaview.pdf.pigeon.PdfViewHostApi
import com.vecvel.danaview.pdf.text.PdfBoxSupport
import com.vecvel.danaview.pdf.text.PdfTextHostApiImpl
import com.vecvel.danaview.pdf.viewer.PdfDocumentStore
import com.vecvel.danaview.pdf.viewer.PdfViewHostApiImpl
import com.vecvel.danaview.pdf.viewer.PdfWarmUp
import io.flutter.embedding.engine.plugins.FlutterPlugin
import java.util.concurrent.RejectedExecutionException

/** The danaview_pdf plugin entry point. */
class DanaviewPdfPlugin : FlutterPlugin {
    private var threads: PdfThreads? = null
    private var store: PdfDocumentStore? = null
    private var views: PdfViewHostApiImpl? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        PdfBoxSupport.init(binding.applicationContext)
        val t = PdfThreads()
        val s = PdfDocumentStore()
        val v = PdfViewHostApiImpl(s, binding.textureRegistry, t)
        threads = t
        store = s
        views = v
        val messenger = binding.binaryMessenger
        PdfDocumentHostApi.setUp(messenger, PdfDocumentHostApiImpl(s, t))
        PdfViewHostApi.setUp(messenger, v)
        PdfTextHostApi.setUp(messenger, PdfTextHostApiImpl(t))
        val events = PdfEventHub()
        val tools = PdfToolsHostApiImpl(t, events::emit)
        PdfToolsHostApi.setUp(messenger, tools)
        PdfOrganiseHostApi.setUp(messenger, tools)
        PdfEventsStreamHandler.register(messenger, events)
        // Warm PdfBox's parser and the platform renderer once, after app start has settled.
        val cacheDir = binding.applicationContext.cacheDir
        t.main.postDelayed({
            try {
                t.documents.execute {
                    Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
                    try {
                        PdfWarmUp.run(cacheDir)
                    } finally {
                        Process.setThreadPriority(Process.THREAD_PRIORITY_DEFAULT)
                    }
                }
            } catch (_: RejectedExecutionException) {
                // Detached meanwhile.
            }
        }, WARM_UP_DELAY_MS)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val messenger = binding.binaryMessenger
        PdfDocumentHostApi.setUp(messenger, null)
        PdfViewHostApi.setUp(messenger, null)
        PdfTextHostApi.setUp(messenger, null)
        PdfToolsHostApi.setUp(messenger, null)
        PdfOrganiseHostApi.setUp(messenger, null)
        views?.disposeAll()
        val t = threads
        val docs = store?.removeAll().orEmpty()
        if (t != null) {
            t.render.post {
                docs.forEach { it.release() }
                t.shutdown()
            }
        }
        threads = null
        store = null
        views = null
    }

    private companion object {
        /** Delay of the warm-up after attach (viewer/PdfWarmUp.kt). */
        const val WARM_UP_DELAY_MS = 3000L
    }
}
