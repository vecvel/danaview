// OWNER: HOM-21A
//
// Placeholder created by HOM-02A: IncomingHostApi on Android (VIEW / SEND / SEND_MULTIPLE intents
// held until Dart takes them). Until HOM-21A lands it answers `notSupportedOnDevice`.

package com.vecvel.danaview.library.incoming

import com.vecvel.danaview.library.glue.LibraryErrors
import com.vecvel.danaview.library.glue.LibraryPluginContext
import com.vecvel.danaview.library.pigeon.IncomingBatchMsg
import com.vecvel.danaview.library.pigeon.IncomingHostApi

@Suppress("unused") // the context is HOM-21A's
class IncomingHostApiImpl(private val context: LibraryPluginContext) : IncomingHostApi {
    override fun takePending(): List<IncomingBatchMsg> = throw LibraryErrors.notSupported(OWNER)

    override fun acknowledge(batchId: String): Unit = throw LibraryErrors.notSupported(OWNER)

    private companion object {
        const val OWNER = "HOM-21A"
    }
}
