// OWNER: HOM-02A
//
// The host APIs Android has no counterpart for (ARCH v1.2 §8): Quick Look (HOM-26, Apple), the
// Share Extension inbox (App Group, HOM-21) and the backup flag (Android's backup rules are XML in
// the app, D-3 / CORE-28). They answer `notSupportedOnDevice` permanently.

package com.vecvel.danaview.library.glue

import com.vecvel.danaview.library.pigeon.BackupFlagHostApi
import com.vecvel.danaview.library.pigeon.FileItemMsg
import com.vecvel.danaview.library.pigeon.InboxBatchMsg
import com.vecvel.danaview.library.pigeon.InboxHostApi
import com.vecvel.danaview.library.pigeon.QuickLookHostApi
import com.vecvel.danaview.library.pigeon.QuickLookRequestMsg

class QuickLookHostApiImpl : QuickLookHostApi {
    override fun canPreview(item: FileItemMsg, callback: (Result<Boolean>) -> Unit) =
        callback(Result.failure(LibraryErrors.notSupported("no Quick Look on Android")))

    override fun present(request: QuickLookRequestMsg, callback: (Result<Unit>) -> Unit) =
        callback(Result.failure(LibraryErrors.notSupported("no Quick Look on Android")))
}

class InboxHostApiImpl : InboxHostApi {
    /** No App Group container on Android. */
    override fun isAvailable(): Boolean = false

    override fun listBatches(callback: (Result<List<InboxBatchMsg>>) -> Unit) = callback(Result.failure(unsupported()))

    override fun takeFile(batchId: String, relativePath: String, destinationPath: String, callback: (Result<Unit>) -> Unit) =
        callback(Result.failure(unsupported()))

    override fun deleteBatch(batchId: String, callback: (Result<Unit>) -> Unit) = callback(Result.failure(unsupported()))

    override fun deleteStaleBatches(olderThanMs: Long, callback: (Result<Long>) -> Unit) = callback(Result.failure(unsupported()))

    override fun writeFolderSnapshot(json: ByteArray, callback: (Result<Unit>) -> Unit) = callback(Result.failure(unsupported()))

    private fun unsupported() = LibraryErrors.notSupported("no Share Extension inbox on Android")
}

class BackupFlagHostApiImpl : BackupFlagHostApi {
    override fun setExcludedFromBackup(path: String, excluded: Boolean, callback: (Result<Unit>) -> Unit) =
        callback(Result.failure(LibraryErrors.notSupported("Android backup rules are XML (D-3)")))

    override fun isExcludedFromBackup(path: String, callback: (Result<Boolean>) -> Unit) =
        callback(Result.failure(LibraryErrors.notSupported("Android backup rules are XML (D-3)")))
}
