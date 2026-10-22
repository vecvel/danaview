// OWNER: HOM-22A
//
// Placeholder created by HOM-02A: ShareHostApi on Android (ACTION_SEND / SEND_MULTIPLE through the
// plugin's FileProvider, read grants only). Until HOM-22A lands it answers `notSupportedOnDevice`.

package com.vecvel.danaview.library.share

import com.vecvel.danaview.library.glue.LibraryErrors
import com.vecvel.danaview.library.glue.LibraryPluginContext
import com.vecvel.danaview.library.pigeon.ShareHostApi
import com.vecvel.danaview.library.pigeon.ShareRequestMsg
import com.vecvel.danaview.library.pigeon.ShareResultMsg

@Suppress("unused") // the context is HOM-22A's
class ShareHostApiImpl(private val context: LibraryPluginContext) : ShareHostApi {
    override fun share(request: ShareRequestMsg, callback: (Result<ShareResultMsg>) -> Unit) =
        callback(Result.failure(LibraryErrors.notSupported("HOM-22A")))
}
