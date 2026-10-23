// OWNER: HOM-20A
//
// The Flutter-free Android import pickers (ARCH v1.2 §5.6, V2-116, rule 27; BUILD_PLAN HOM-20A),
// driven by PickerHostApiImpl and directly by the instrumented tests:
//
// * Photos: the system Photo Picker through androidx.activity's PickVisualMedia /
//   PickMultipleVisualMedia contracts (MediaStore.ACTION_PICK_IMAGES on Android 13+ and on 11-12
//   with the SDK extension, the Google Play services back-port where installed, otherwise the
//   contracts' own ACTION_OPEN_DOCUMENT image/video fallback). No library permission is used.
// * Files: SAF ACTION_OPEN_DOCUMENT (CATEGORY_OPENABLE, EXTRA_MIME_TYPES, EXTRA_ALLOW_MULTIPLE).
// * Both answer content:// items with needsCopy = true and no staging copy: unlike PHPicker's
//   temporary files, the URIs stay readable for the app's process (the Activity holds the
//   picker's temporary read grant), so HOM-20's import copies each item once, straight into its
//   imports/<job>.part, with progress, cancel and resume. No persisted grant is taken (imports
//   copy), so release() has nothing to give up.
// * copy: the source is opened with openFileDescriptor(uri, "r") (openAssetFileDescriptor "r" for
//   providers that only serve asset descriptors), or a read-only FileInputStream for a file path;
//   it is never opened for writing. The destination is the one part file named by the request.
// * Names (OBS-S2A-1): the provider's DISPLAY_NAME, unless it is the Photo Picker's media id
//   ("1000000428.mp4"); then IMG_yyyyMMdd_HHmmss.<ext> from DATE_TAKEN, else DATE_ADDED. Clashes
//   inside one pick become "Name (2).ext", as on Apple.
//
// The Activity is reached through [ResultLauncher] so tests can supply their own. Nothing is
// logged (rule 30).

package com.vecvel.danaview.library.pickers

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.res.AssetFileDescriptor
import android.net.Uri
import android.os.Build
import android.os.ext.SdkExtensions
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import com.vecvel.danaview.library.pigeon.PickedItemMsg
import com.vecvel.danaview.library.pigeon.PickedSourceMsg
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream

/** Starts an Intent for a result on the current Activity; false when there is none (or one runs). */
fun interface ResultLauncher {
    fun start(intent: Intent, done: (resultCode: Int, data: Intent?) -> Unit): Boolean
}

class AndroidPickers(context: Context) {
    private val app = context.applicationContext
    private val resolver: ContentResolver = app.contentResolver

    // ---------------------------------------------------------------------------------------------
    // Intents

    /** True when the system Photo Picker (not a fallback) answers ACTION_PICK_IMAGES here. */
    @SuppressLint("NewApi")
    fun systemPhotoPickerAvailable(): Boolean =
        Build.VERSION.SDK_INT >= 33 || (Build.VERSION.SDK_INT >= 30 && SdkExtensions.getExtensionVersion(Build.VERSION_CODES.R) >= 2)

    /** True when some photo picker (system or Play services back-port) is available. */
    fun photoPickerAvailable(): Boolean = ActivityResultContracts.PickVisualMedia.isPhotoPickerAvailable(app)

    @SuppressLint("NewApi")
    private fun systemMax(): Int? = if (systemPhotoPickerAvailable()) MediaStore.getPickImagesMaxLimit() else null

    private fun visualType(kind: VisualKind): ActivityResultContracts.PickVisualMedia.VisualMediaType = when (kind) {
        VisualKind.IMAGE_AND_VIDEO -> ActivityResultContracts.PickVisualMedia.ImageAndVideo
        VisualKind.IMAGE_ONLY -> ActivityResultContracts.PickVisualMedia.ImageOnly
        VisualKind.VIDEO_ONLY -> ActivityResultContracts.PickVisualMedia.VideoOnly
    }

    /** The photo picker intent for [kind] and [maxItems] (1: single selection). */
    fun photoIntent(kind: VisualKind, maxItems: Int): Intent {
        val request = PickVisualMediaRequest.Builder().setMediaType(visualType(kind)).build()
        return if (maxItems <= 1) {
            ActivityResultContracts.PickVisualMedia().createIntent(app, request)
        } else {
            ActivityResultContracts.PickMultipleVisualMedia(maxItems).createIntent(app, request)
        }
    }

    /** The picked URIs of a photo picker result. */
    fun photoResult(maxItems: Int, resultCode: Int, data: Intent?): List<Uri> =
        if (maxItems <= 1) {
            listOfNotNull(ActivityResultContracts.PickVisualMedia().parseResult(resultCode, data))
        } else {
            ActivityResultContracts.PickMultipleVisualMedia(maxItems).parseResult(resultCode, data)
        }

    /** The SAF document picker intent (import mode: read-only, openable, no persisted grant). */
    fun documentIntent(allowMultiple: Boolean, mimeTypes: List<String>): Intent {
        val (type, extra) = PickerRequests.documentTypes(mimeTypes)
        return Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            this.type = type
            if (extra != null) putExtra(Intent.EXTRA_MIME_TYPES, extra)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, allowMultiple)
        }
    }

    /** The URIs of an ACTION_OPEN_DOCUMENT result (ClipData for several, data for one). */
    fun documentResult(resultCode: Int, data: Intent?): List<Uri> {
        if (resultCode != android.app.Activity.RESULT_OK || data == null) return emptyList()
        val out = LinkedHashSet<Uri>()
        val clip: ClipData? = data.clipData
        if (clip != null) for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(out::add)
        data.data?.let(out::add)
        return out.toList()
    }

    /** Shows the photo picker; [done] gets the picked URIs (empty on cancel) or a failure. */
    fun pickPhotos(launcher: ResultLauncher, filter: VisualKind, limit: Long, done: (Result<List<Uri>>) -> Unit) {
        val max = PickerRequests.maxItems(limit, systemMax())
        val intent = photoIntent(filter, max)
        val started = launcher.start(intent) { code, data ->
            done(runCatching { PickerRequests.limited(photoResult(max, code, data), limit) })
        }
        if (!started) done(Result.failure(PickerFailure.busy("no Activity, or a picker is already open")))
    }

    /** Shows the SAF document picker; [done] gets the picked URIs (empty on cancel) or a failure. */
    fun pickDocuments(launcher: ResultLauncher, allowMultiple: Boolean, mimeTypes: List<String>, done: (Result<List<Uri>>) -> Unit) {
        val started = launcher.start(documentIntent(allowMultiple, mimeTypes)) { code, data ->
            done(runCatching { documentResult(code, data).let { if (allowMultiple) it else it.take(1) } })
        }
        if (!started) done(Result.failure(PickerFailure.busy("no Activity, or a picker is already open")))
    }

    // ---------------------------------------------------------------------------------------------
    // Item metadata (no permission needed: the picker's grant covers these queries)

    /** The PickedItemMsg of a picked [uri]: name, MIME type, size and modification time when the provider says. */
    fun describe(uri: Uri, source: PickedSourceMsg): PickedItemMsg {
        var name: String? = null
        var size: Long? = null
        try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val si = c.getColumnIndex(OpenableColumns.SIZE)
                    if (ni >= 0 && !c.isNull(ni)) name = c.getString(ni)
                    if (si >= 0 && !c.isNull(si)) size = c.getLong(si).takeIf { it >= 0 }
                }
            }
        } catch (e: RuntimeException) {
            // Some providers reject projections; the name falls back to the URI.
        }
        val modified = lastModified(uri)
        val mime = runCatching { resolver.getType(uri) }.getOrNull()
            ?: name?.substringAfterLast('.', "")?.lowercase()?.takeIf { it.isNotEmpty() }?.let { MimeTypeMap.getSingleton().getMimeTypeFromExtension(it) }
        val ext = mime?.let { MimeTypeMap.getSingleton().getExtensionFromMimeType(it) }
        return PickedItemMsg(
            uri = uri.toString(),
            path = null,
            displayName = PickerRequests.importName(name, uri.lastPathSegment, ext, source == PickedSourceMsg.PHOTO_LIBRARY) { captureDates(uri) },
            uti = null,
            mimeType = mime,
            sizeBytes = size,
            modifiedTimeMs = modified,
            assetIdentifier = null,
            source = source,
            needsCopy = true,
        )
    }

    /**
     * Describes every picked URI (in order) and numbers name clashes inside the pick ("Name (2).ext",
     * OBS-S2A-1), as Apple's staging does.
     */
    fun describeAll(uris: List<Uri>, source: PickedSourceMsg): List<PickedItemMsg> {
        val items = uris.map { describe(it, source) }
        val names = PickerRequests.uniqueNames(items.map { it.displayName })
        return items.mapIndexed { i, item -> if (item.displayName == names[i]) item else item.copy(displayName = names[i]) }
    }

    /**
     * (DATE_TAKEN, DATE_ADDED) of a picked item in ms, each null when the provider has none. The
     * Photo Picker's URIs answer DATE_TAKEN (PickerMediaColumns); MediaStore rows both. Each column
     * is asked on its own: providers reject projections they don't know.
     */
    private fun captureDates(uri: Uri): Pair<Long?, Long?> {
        fun column(name: String): Long? = try {
            resolver.query(uri, arrayOf(name), null, null, null)?.use { c ->
                if (c.moveToFirst() && c.columnCount > 0 && !c.isNull(0)) c.getLong(0) else null
            }?.takeIf { it > 0 }
        } catch (e: RuntimeException) {
            null
        }
        val taken = column(MediaStore.Images.ImageColumns.DATE_TAKEN) // "datetaken" (API 16 name of the 29+ column)
        // DATE_ADDED is in seconds.
        val added = if (taken == null) column(MediaStore.MediaColumns.DATE_ADDED)?.let { it * 1000 } else null
        return taken to added
    }

    private fun lastModified(uri: Uri): Long? {
        val column = if (DocumentsContract.isDocumentUri(app, uri)) DocumentsContract.Document.COLUMN_LAST_MODIFIED else MediaStore.MediaColumns.DATE_MODIFIED
        return try {
            resolver.query(uri, arrayOf(column), null, null, null)?.use { c ->
                if (c.moveToFirst() && !c.isNull(0)) {
                    val v = c.getLong(0)
                    // MediaStore's DATE_MODIFIED is in seconds, DocumentsContract's in ms.
                    if (column == MediaStore.MediaColumns.DATE_MODIFIED) v * 1000 else v
                } else {
                    null
                }
            }?.takeIf { it > 0 }
        } catch (e: RuntimeException) {
            null
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Streamed copy

    /** A read-only source stream and its size when known. */
    class Source(val input: InputStream, val total: Long?, private val closer: () -> Unit) : AutoCloseable {
        override fun close() = closer()
    }

    /** Opens [uri] (`content://`, `file://` or an absolute path) read-only (rule 27). */
    fun openSource(uri: String): Source {
        if (uri.startsWith("/") || uri.startsWith("file://")) {
            val path = if (uri.startsWith("/")) uri else Uri.parse(uri).path ?: throw PickerFailure.invalid("bad file URL")
            val file = File(path)
            if (!file.isFile) throw PickerFailure.notFound("source not found")
            val input = try {
                FileInputStream(file)
            } catch (e: FileNotFoundException) {
                throw PickerFailure.permission("source not readable")
            }
            return Source(input, file.length()) { input.close() }
        }
        if (!uri.startsWith("content://")) throw PickerFailure.invalid("unknown source")
        val parsed = Uri.parse(uri)
        val afd: AssetFileDescriptor = try {
            resolver.openFileDescriptor(parsed, "r")?.let { AssetFileDescriptor(it, 0, AssetFileDescriptor.UNKNOWN_LENGTH) }
                ?: throw PickerFailure.notFound("source not found")
        } catch (e: FileNotFoundException) {
            // Providers that only hand out asset descriptors (a range of a file, a pipe).
            try {
                resolver.openAssetFileDescriptor(parsed, "r") ?: throw PickerFailure.notFound("source not found")
            } catch (e2: FileNotFoundException) {
                throw PickerFailure.notFound("source not found")
            }
        } catch (e: SecurityException) {
            throw PickerFailure.permission("no read grant for the source")
        } catch (e: IllegalArgumentException) {
            throw PickerFailure.notFound("source not found")
        }
        val total = afd.length.takeIf { it >= 0 } ?: afd.parcelFileDescriptor.statSize.takeIf { it >= 0 } ?: querySize(parsed)
        val input = try {
            afd.createInputStream()
        } catch (e: IOException) {
            afd.close()
            throw PickerFailure.io("source can't be read")
        }
        return Source(input, total) {
            runCatching { input.close() }
            runCatching { afd.close() }
        }
    }

    private fun querySize(uri: Uri): Long? = try {
        resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) c.getLong(0).takeIf { it >= 0 } else null
        }
    } catch (e: RuntimeException) {
        null
    }

    /**
     * Copies [sourceUri] into [destinationPath] from [resumeFrom] (StreamCopy); blocks the calling
     * background thread. Returns (bytes in the destination, source size or that).
     */
    fun copy(sourceUri: String, destinationPath: String, resumeFrom: Long, isCancelled: () -> Boolean, progress: (Long, Long?) -> Unit): Pair<Long, Long> {
        if (destinationPath.isEmpty() || !destinationPath.startsWith("/")) throw PickerFailure.invalid("destination is not an absolute path")
        if (resumeFrom < 0) throw PickerFailure.invalid("negative offset")
        return openSource(sourceUri).use { src ->
            StreamCopy.copy(src.input, File(destinationPath), resumeFrom, src.total, isCancelled, progress)
        }
    }
}
