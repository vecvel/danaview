// OWNER: HOM-22A
//
// Placeholder created by HOM-02A: OpenInHostApi on Android (ACTION_VIEW with a read grant through
// the plugin's FileProvider). Until HOM-22A lands it answers `notSupportedOnDevice`.

package com.vecvel.danaview.library.openin

import com.vecvel.danaview.library.glue.LibraryErrors
import com.vecvel.danaview.library.glue.LibraryPluginContext
import com.vecvel.danaview.library.pigeon.OpenInHostApi
import com.vecvel.danaview.library.pigeon.OpenInRequestMsg

@Suppress("unused") // the context is HOM-22A's
class OpenInHostApiImpl(private val context: LibraryPluginContext) : OpenInHostApi {
    override fun openIn(request: OpenInRequestMsg, callback: (Result<Boolean>) -> Unit) =
        callback(Result.failure(LibraryErrors.notSupported("HOM-22A")))
}
