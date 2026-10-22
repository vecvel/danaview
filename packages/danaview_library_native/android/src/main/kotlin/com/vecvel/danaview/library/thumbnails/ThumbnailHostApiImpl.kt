// OWNER: HOM-04A
//
// Placeholder created by HOM-02A: ThumbnailHostApi on Android (MediaStore loadThumbnail,
// ThumbnailUtils, PdfRenderer; WebP output). Until HOM-04A lands every call answers
// `notSupportedOnDevice`.

package com.vecvel.danaview.library.thumbnails

import com.vecvel.danaview.library.glue.LibraryErrors
import com.vecvel.danaview.library.glue.LibraryPluginContext
import com.vecvel.danaview.library.pigeon.DocumentThumbnailRequestMsg
import com.vecvel.danaview.library.pigeon.MediaThumbnailRequestMsg
import com.vecvel.danaview.library.pigeon.ThumbnailCachingMsg
import com.vecvel.danaview.library.pigeon.ThumbnailHostApi
import com.vecvel.danaview.library.pigeon.ThumbnailResultMsg

@Suppress("unused") // the context is HOM-04A's
class ThumbnailHostApiImpl(private val context: LibraryPluginContext) : ThumbnailHostApi {
    override fun mediaThumbnail(request: MediaThumbnailRequestMsg, callback: (Result<ThumbnailResultMsg>) -> Unit) =
        callback(Result.failure(LibraryErrors.notSupported(OWNER)))

    override fun documentThumbnail(request: DocumentThumbnailRequestMsg, callback: (Result<ThumbnailResultMsg?>) -> Unit) =
        callback(Result.failure(LibraryErrors.notSupported(OWNER)))

    override fun cancel(requestId: String): Unit = throw LibraryErrors.notSupported(OWNER)

    override fun updateCaching(window: ThumbnailCachingMsg): Unit = throw LibraryErrors.notSupported(OWNER)

    private companion object {
        const val OWNER = "HOM-04A"
    }
}
