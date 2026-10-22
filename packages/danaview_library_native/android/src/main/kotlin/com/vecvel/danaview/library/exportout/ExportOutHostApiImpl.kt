// OWNER: HOM-22A
//
// Placeholder created by HOM-02A: ExportOutHostApi on Android (MediaStore Downloads / Pictures /
// Movies, ACTION_CREATE_DOCUMENT, ACTION_OPEN_DOCUMENT_TREE; create-new only). Until HOM-22A lands
// it answers `notSupportedOnDevice`.

package com.vecvel.danaview.library.exportout

import com.vecvel.danaview.library.glue.LibraryErrors
import com.vecvel.danaview.library.glue.LibraryPluginContext
import com.vecvel.danaview.library.pigeon.ExportOutHostApi
import com.vecvel.danaview.library.pigeon.SaveOutRequestMsg
import com.vecvel.danaview.library.pigeon.SaveOutResultMsg

@Suppress("unused") // the context is HOM-22A's
class ExportOutHostApiImpl(private val context: LibraryPluginContext) : ExportOutHostApi {
    override fun saveOut(request: SaveOutRequestMsg, callback: (Result<SaveOutResultMsg>) -> Unit) =
        callback(Result.failure(LibraryErrors.notSupported("HOM-22A")))
}
