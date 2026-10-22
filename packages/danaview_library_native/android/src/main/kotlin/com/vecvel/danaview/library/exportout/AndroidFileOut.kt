// OWNER: HOM-22A
//
// The Android side of getting files out (ARCH v1.2 §8, rule 26, V2-117, V2-118; BUILD_PLAN
// HOM-22A; a5c4c4d answers 9-11), Flutter-free so the instrumented tests drive it directly. No
// storage permission is used anywhere:
//
// * MediaStore saves (API 29+, the editor floor): a new row in Downloads (`Download/<sub>/`), or
//   Images / Video for Save to Photos (`Pictures/Danaview/`, `Movies/Danaview/`), inserted with
//   IS_PENDING = 1, filled, then published; MediaStore picks a free name, so nothing is ever
//   overwritten; a row whose copy failed is deleted.
// * System "save as" (Save to Files everywhere; Downloads and Photos on API 24-28, answer 9):
//   ACTION_CREATE_DOCUMENT for one file, ACTION_OPEN_DOCUMENT_TREE once for several, then
//   DocumentsContract.createDocument for each inside the chosen folder (the provider makes the name
//   unique, answer 10). Only documents the system just created for us are written.
// * Share / Open in: FileProvider content URIs (authority `${applicationId}.danaview.library.files`)
//   of TempCopyStore copies, with FLAG_GRANT_READ_URI_PERMISSION only and ClipData listing every
//   URI (answer 11).
//
// Library files are only read. Nothing is logged (rule 30).

package com.vecvel.danaview.library.exportout

import android.content.ClipData
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException

/** The plugin's FileProvider: a subclass so the manifest merge never clashes with another library's entry. */
class LibraryFileProvider : FileProvider()

class AndroidFileOut(context: Context) {
    private val app = context.applicationContext
    private val resolver: ContentResolver = app.contentResolver
    val store = TempCopyStore(app.cacheDir)
    val authority: String = "${app.packageName}$AUTHORITY_SUFFIX"

    // ---------------------------------------------------------------------------------------------
    // MediaStore (API 29+)

    /** Where a MediaStore save of [file] goes, or null when it can't go to [photos] (not a photo or video). */
    @RequiresApi(29)
    private fun collectionFor(file: OutFile, photos: Boolean): Uri? {
        if (!photos) return MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        return when (FileOut.mediaKind(file)) {
            OutMediaKind.PHOTO -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            OutMediaKind.VIDEO -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            OutMediaKind.OTHER -> null
        }
    }

    /**
     * Saves [file] as a new MediaStore item: Downloads under [subdirectory], or Pictures/Movies when
     * [photos]. Returns its content URI.
     */
    @RequiresApi(29)
    fun saveToMediaStore(file: OutFile, photos: Boolean, subdirectory: String?): Uri {
        val collection = collectionFor(file, photos) ?: throw OutFailure.invalid("not a photo or video")
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, FileOut.safeName(file.displayName))
            put(MediaStore.MediaColumns.MIME_TYPE, FileOut.mimeType(file.mimeType, file.displayName))
            put(MediaStore.MediaColumns.RELATIVE_PATH, if (photos) FileOut.photosPath(FileOut.mediaKind(file)) else FileOut.downloadsPath(subdirectory))
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values) ?: throw OutFailure.io("MediaStore refused the new item")
        try {
            resolver.openOutputStream(uri, "w")?.use { FileOut.copyInto(File(file.path), it) } ?: throw OutFailure.io("no output stream")
            resolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
            return uri
        } catch (t: Throwable) {
            runCatching { resolver.delete(uri, null, null) }
            throw mapped(t)
        }
    }

    // ---------------------------------------------------------------------------------------------
    // System "save as"

    /** ACTION_CREATE_DOCUMENT for [file] (the user picks folder and name). */
    fun createDocumentIntent(file: OutFile): Intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
        addCategory(Intent.CATEGORY_OPENABLE)
        type = FileOut.mimeType(file.mimeType, file.displayName)
        putExtra(Intent.EXTRA_TITLE, FileOut.safeName(file.displayName))
    }

    /** ACTION_OPEN_DOCUMENT_TREE: the user picks one folder for several files. */
    fun openTreeIntent(): Intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)

    /** Writes [file] into the empty document [uri] the system just created for us. */
    fun writeDocument(uri: Uri, file: OutFile) {
        try {
            resolver.openOutputStream(uri, "w")?.use { FileOut.copyInto(File(file.path), it) } ?: throw OutFailure.io("no output stream")
        } catch (t: Throwable) {
            throw mapped(t)
        }
    }

    /** Deletes a document the save dialog created when its copy failed (best effort). */
    fun deleteDocument(uri: Uri) {
        runCatching { DocumentsContract.deleteDocument(resolver, uri) }
    }

    /** Creates each of [files] as a new document in the chosen [tree]; returns the created URIs and the failures. */
    fun saveIntoTree(tree: Uri, files: List<OutFile>): Pair<List<String>, Int> {
        val parent = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val saved = ArrayList<String>()
        var failed = 0
        for (f in files) {
            var created: Uri? = null
            try {
                created = DocumentsContract.createDocument(resolver, parent, FileOut.mimeType(f.mimeType, f.displayName), FileOut.safeName(f.displayName))
                    ?: throw OutFailure.io("the folder refused the new file")
                writeDocument(created, f)
                saved += created.toString()
            } catch (t: Throwable) {
                created?.let { runCatching { DocumentsContract.deleteDocument(resolver, it) } }
                failed++
            }
        }
        return saved to failed
    }

    // ---------------------------------------------------------------------------------------------
    // Share and open in

    /** The FileProvider URI of a temporary copy (throws for any file outside `danaview-out/`). */
    fun uriFor(copy: File): Uri = FileProvider.getUriForFile(app, authority, copy)

    /** ACTION_SEND / ACTION_SEND_MULTIPLE of [batch] (read grants only, ClipData of every URI). */
    fun shareIntent(batch: TempBatch, mimeTypes: List<String>, subject: String?): Intent {
        val uris = batch.files.map(::uriFor)
        val intent = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris[0])
        } else {
            Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
        }
        intent.type = FileOut.commonType(mimeTypes)
        if (!subject.isNullOrEmpty()) intent.putExtra(Intent.EXTRA_SUBJECT, subject)
        intent.clipData = clip(uris)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return intent
    }

    /** ACTION_VIEW of the one copy of [batch] with [mimeType] (read grant only). */
    fun viewIntent(batch: TempBatch, mimeType: String): Intent {
        val uri = uriFor(batch.files.single())
        return Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mimeType)
            clipData = clip(listOf(uri))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    private fun clip(uris: List<Uri>): ClipData {
        val clip = ClipData.newRawUri("", uris[0])
        for (u in uris.drop(1)) clip.addItem(ClipData.Item(u))
        return clip
    }

    private fun mapped(t: Throwable): OutFailure = when (t) {
        is OutFailure -> t
        is FileNotFoundException -> OutFailure.notFound("file not found")
        is SecurityException -> OutFailure.denied("access denied")
        is IOException -> OutFailure.io("copy failed")
        else -> OutFailure.io("copy failed (${t.javaClass.simpleName})")
    }

    companion object {
        /** Appended to the application id: `${applicationId}.danaview.library.files` (manifest). */
        const val AUTHORITY_SUFFIX = ".danaview.library.files"
    }
}
