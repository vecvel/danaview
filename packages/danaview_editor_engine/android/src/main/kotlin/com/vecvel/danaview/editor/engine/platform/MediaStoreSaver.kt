// OWNER: AND-12
//
// Gallery insert through MediaStore (ARCH §14.1 step 6, §14.3, D-39; BUILD_PLAN AND-12). API 29+ (the
// editor gate, D-43): a pending MediaStore.Video row with RELATIVE_PATH Movies/Danaview and
// IS_PENDING = 1 is inserted on the primary external volume, the file is copied into it (and synced),
// then IS_PENDING is cleared so the item appears in the Gallery / Photos at once and complete. No
// storage permission is needed for the app's own inserts on API 29+. On any failure the pending
// row is deleted, so no half-written item is ever visible. The display name is the source file's name
// (Dart names the export); MediaStore adds " (1)" on a clash. Below API 29 the call answers
// notSupportedOnDevice (the editor does not run there).
// Used by `PlatformHostApi.saveToPhotos` (danaview-io) and by ExportService's detached completion
// (danaview-export). Errors: SecurityException → permissionDenied (Dart: FileHandoffOutcome.denied),
// ENOSPC → diskFull, other I/O → io (EngineErrors.from). Nothing logs paths or URIs.

package com.vecvel.danaview.editor.engine.platform

import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.annotation.RequiresApi
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.fail
import com.vecvel.danaview.editor.engine.core.succeed
import com.vecvel.danaview.editor.engine.pigeon.FileHandoffOutcomeMsg
import com.vecvel.danaview.editor.engine.pigeon.FileHandoffResultMsg
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException

/** Gallery insert through MediaStore with IS_PENDING (ARCH §14.3; AND-12). Called on danaview-io. */
class MediaStoreSaver(private val ctx: EngineContext) {
    /** Inserts the video at [path] (inside the engine roots) into Movies/Danaview. */
    fun saveToPhotos(path: String, done: Completion<FileHandoffResultMsg>) {
        try {
            val uri = insert(File(path))
            done.succeed(FileHandoffResultMsg(FileHandoffOutcomeMsg.DONE, uri.toString()))
        } catch (t: Throwable) {
            done.fail(EngineErrors.from(t))
        }
    }

    /**
     * Copies [source] into a new MediaStore video (file header) and returns its content URI.
     * Blocking; throws EngineException / IOException / SecurityException.
     */
    fun insert(source: File, displayName: String = source.name): Uri {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) throw EngineErrors.notSupported("saving to the gallery before Android 10")
        if (!source.isFile) throw FileNotFoundException("export output missing")
        return insertQ(source, displayName)
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun insertQ(source: File, displayName: String): Uri {
        val resolver = ctx.appContext.contentResolver
        val now = System.currentTimeMillis()
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeTypeOf(source.name))
            put(MediaStore.MediaColumns.RELATIVE_PATH, RELATIVE_PATH)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
            put(MediaStore.MediaColumns.DATE_ADDED, now / 1000)
            put(MediaStore.MediaColumns.DATE_MODIFIED, now / 1000)
            put(MediaStore.Video.VideoColumns.DATE_TAKEN, now)
        }
        val collection = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values) ?: throw IOException("MediaStore refused the insert")
        try {
            val pfd = resolver.openFileDescriptor(uri, "w") ?: throw IOException("MediaStore item not writable")
            pfd.use {
                FileOutputStream(it.fileDescriptor).use { out ->
                    FileInputStream(source).use { input -> input.copyTo(out, BUFFER) }
                    out.flush()
                    out.fd.sync()
                }
            }
            val publish = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            if (resolver.update(uri, publish, null, null) < 1) throw IOException("MediaStore did not publish the item")
            Log.i(TAG, "gallery insert done (${source.length()} bytes)")
            return uri
        } catch (t: Throwable) {
            try {
                resolver.delete(uri, null, null)
            } catch (e: RuntimeException) {
                Log.w(TAG, "gallery insert: cleanup failed (${e.javaClass.simpleName})")
            }
            Log.w(TAG, "gallery insert failed (${t.javaClass.simpleName})")
            throw t
        }
    }

    companion object {
        private const val TAG = EngineContext.TAG
        private const val BUFFER = 1 shl 16

        /** MediaStore RELATIVE_PATH of the editor's exports. */
        val RELATIVE_PATH: String = Environment.DIRECTORY_MOVIES + "/Danaview"

        /** MIME type of a video file name (mp4 / mov; MimeTypeMap otherwise; video/mp4 by default). */
        fun mimeTypeOf(name: String): String {
            val ext = name.substringAfterLast('.', "").lowercase()
            return when (ext) {
                "mp4", "m4v" -> "video/mp4"
                "mov" -> "video/quicktime"
                else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "video/mp4"
            }
        }
    }
}
