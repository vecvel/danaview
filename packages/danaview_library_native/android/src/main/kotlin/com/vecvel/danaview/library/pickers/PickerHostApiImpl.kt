// OWNER: HOM-20A
//
// Placeholder created by HOM-02A: PickerHostApi on Android (system photo picker, SAF document
// picker, streamed resumable copies). Until HOM-20A lands every call answers
// `notSupportedOnDevice`.

package com.vecvel.danaview.library.pickers

import com.vecvel.danaview.library.glue.LibraryErrors
import com.vecvel.danaview.library.glue.LibraryPluginContext
import com.vecvel.danaview.library.pigeon.CopyRequestMsg
import com.vecvel.danaview.library.pigeon.CopyResultMsg
import com.vecvel.danaview.library.pigeon.DocumentPickRequestMsg
import com.vecvel.danaview.library.pigeon.PhotoPickRequestMsg
import com.vecvel.danaview.library.pigeon.PickedItemMsg
import com.vecvel.danaview.library.pigeon.PickerHostApi

@Suppress("unused") // the context is HOM-20A's
class PickerHostApiImpl(private val context: LibraryPluginContext) : PickerHostApi {
    override fun pickPhotos(request: PhotoPickRequestMsg, callback: (Result<List<PickedItemMsg>>) -> Unit) =
        callback(Result.failure(LibraryErrors.notSupported(OWNER)))

    override fun pickDocuments(request: DocumentPickRequestMsg, callback: (Result<List<PickedItemMsg>>) -> Unit) =
        callback(Result.failure(LibraryErrors.notSupported(OWNER)))

    override fun copyToFile(request: CopyRequestMsg, callback: (Result<CopyResultMsg>) -> Unit) =
        callback(Result.failure(LibraryErrors.notSupported(OWNER)))

    override fun cancelCopy(requestId: String): Unit = throw LibraryErrors.notSupported(OWNER)

    override fun release(uri: String): Unit = throw LibraryErrors.notSupported(OWNER)

    private companion object {
        const val OWNER = "HOM-20A"
    }
}
