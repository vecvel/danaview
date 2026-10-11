// OWNER: AND-14
//
// Pickers (ARCH §9.1, §12.4, §15 Pickers; BUILD_PLAN AND-14). Shown through the plugin's
// ActivityResult wiring (EngineContext.activityHost; the androidx.activity contracts only build the
// intents and parse the results, no ActivityResultRegistry is needed).
//
// - source photos with only visual kinds (video, image): the Photo Picker,
//   PickMultipleVisualMedia / PickVisualMedia (ImageAndVideo, ImageOnly or VideoOnly).
//   Fallback for devices without it (documented, AND-14): androidx.activity picks the best one
//   available itself: the platform picker (API 33+, or API 30+ with the SDK extension), else the
//   Google Play services backport (the manifest's ModuleDependencies entry asks Play to install
//   it), else ACTION_OPEN_DOCUMENT with the same MIME types. Every result is a content:// URI that
//   Dart persists with persistUriGrant (or copies, ARCH §9.1).
// - source files, or any audio / LUT / subtitle kind: SAF ACTION_OPEN_DOCUMENT
//   (OpenMultipleDocuments semantics; CATEGORY_OPENABLE, EXTRA_MIME_TYPES, EXTRA_ALLOW_MULTIPLE).
//   `.cube` files have no registered MIME type, so the LUT kind adds application/octet-stream (and
//   text/plain) and results are filtered by extension; subtitles are application/x-subrip, text/vtt,
//   text/plain or octet-stream with an .srt/.vtt name.
// - Results: items whose type matches none of the requested kinds are dropped; display name and
//   size come from OpenableColumns (queried on danaview-io). Originals are never touched (read-only
//   access). An empty list means cancelled.

package com.vecvel.danaview.editor.engine.platform

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.fail
import com.vecvel.danaview.editor.engine.core.succeed
import com.vecvel.danaview.editor.engine.pigeon.MediaPickKindMsg
import com.vecvel.danaview.editor.engine.pigeon.MediaPickRequestMsg
import com.vecvel.danaview.editor.engine.pigeon.MediaPickSourceMsg
import com.vecvel.danaview.editor.engine.pigeon.PickOriginMsg
import com.vecvel.danaview.editor.engine.pigeon.PickedMediaMsg

/** Photo Picker and SAF pickers (ARCH §15 Pickers; AND-14). Called on main. */
class MediaPicker(private val ctx: EngineContext) {
    /** Activity seam (tests substitute a relay that lets the real picker answer). */
    internal var requests: ActivityRequests = HostActivityRequests(ctx.activityHost)

    /** Shows the picker; an empty list means cancelled. */
    fun pick(request: MediaPickRequestMsg, done: Completion<List<PickedMediaMsg>>) {
        val plan = PickPlan.of(request)
        val intent = plan.intent(ctx.appContext)
        val started = requests.startForResult(intent) { resultCode, data ->
            val uris = plan.parse(resultCode, data)
            if (uris.isEmpty()) return@startForResult done.succeed(emptyList())
            ctx.threads.io.execute {
                try {
                    val items = uris.mapNotNull { describe(it, plan) }
                    if (items.size < uris.size) Log.i(TAG, "picker: ${uris.size - items.size} item(s) of an unrequested type dropped")
                    done.succeed(items)
                } catch (e: Throwable) {
                    done.fail(e)
                }
            }
        }
        if (!started) done.fail(EngineException(EngineErrorCode.internal, "no activity attached"))
    }

    /** The picked item [uri] as a message, or null when it matches none of the requested kinds. */
    internal fun describe(uri: Uri, plan: PickPlan): PickedMediaMsg? {
        val resolver = ctx.appContext.contentResolver
        var name: String? = null
        var size: Long? = null
        try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val s = c.getColumnIndex(OpenableColumns.SIZE)
                    if (n >= 0 && !c.isNull(n)) name = c.getString(n)
                    if (s >= 0 && !c.isNull(s)) size = c.getLong(s).takeIf { it >= 0 }
                }
            }
        } catch (e: RuntimeException) {
            Log.w(TAG, "picker: metadata query failed (${e.javaClass.simpleName})")
        }
        val displayName = name ?: uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotEmpty() } ?: "media"
        val mime = try {
            resolver.getType(uri)
        } catch (e: RuntimeException) {
            null
        }
        if (!plan.accepts(mime, displayName)) return null
        return PickedMediaMsg(
            uri = uri.toString(),
            displayName = displayName,
            origin = plan.origin,
            isTemporaryCopy = false,
            bookmark = null,
            sizeBytes = size,
        )
    }

    companion object {
        private const val TAG = EngineContext.TAG
    }
}

/** How one pick request is shown and filtered. */
internal class PickPlan private constructor(
    val kinds: Set<MediaPickKindMsg>,
    val multiple: Boolean,
    /** Photo Picker (visual media) rather than SAF. */
    val photoPicker: Boolean,
) {
    val origin: PickOriginMsg get() = if (photoPicker) PickOriginMsg.PHOTOS else PickOriginMsg.FILES

    /** The visual media type of the Photo Picker. */
    val visualType: ActivityResultContracts.PickVisualMedia.VisualMediaType
        get() = when {
            MediaPickKindMsg.VIDEO in kinds && MediaPickKindMsg.IMAGE in kinds -> ActivityResultContracts.PickVisualMedia.ImageAndVideo
            MediaPickKindMsg.VIDEO in kinds -> ActivityResultContracts.PickVisualMedia.VideoOnly
            else -> ActivityResultContracts.PickVisualMedia.ImageOnly
        }

    /** MIME types offered to SAF. */
    val documentMimeTypes: Array<String>
        get() = kinds.flatMap { MIME_TYPES.getValue(it) }.distinct().toTypedArray()

    fun intent(context: Context): Intent = if (photoPicker) {
        val request = PickVisualMediaRequest(visualType)
        if (multiple) ActivityResultContracts.PickMultipleVisualMedia().createIntent(context, request)
        else ActivityResultContracts.PickVisualMedia().createIntent(context, request)
    } else {
        Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(if (documentMimeTypes.size == 1) documentMimeTypes[0] else "*/*")
            .putExtra(Intent.EXTRA_MIME_TYPES, documentMimeTypes)
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
    }

    /** The URIs of a picker result (empty when cancelled). */
    fun parse(resultCode: Int, data: Intent?): List<Uri> {
        if (resultCode != Activity.RESULT_OK || data == null) return emptyList()
        if (photoPicker) {
            return if (multiple) ActivityResultContracts.PickMultipleVisualMedia().parseResult(resultCode, data)
            else listOfNotNull(ActivityResultContracts.PickVisualMedia().parseResult(resultCode, data))
        }
        val out = LinkedHashSet<Uri>()
        data.data?.let(out::add)
        data.clipData?.let { clip -> for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(out::add) }
        return out.toList()
    }

    /** Whether an item of [mime] named [name] matches a requested kind. */
    fun accepts(mime: String?, name: String): Boolean = kinds.any { kindOf(it, mime, name) }

    companion object {
        private val MIME_TYPES = mapOf(
            MediaPickKindMsg.VIDEO to listOf("video/*"),
            MediaPickKindMsg.AUDIO to listOf("audio/*"),
            MediaPickKindMsg.IMAGE to listOf("image/*"),
            MediaPickKindMsg.LUT to listOf("application/octet-stream", "text/plain", "application/x-cube"),
            MediaPickKindMsg.SUBTITLE to listOf("application/x-subrip", "text/vtt", "text/plain", "application/octet-stream"),
        )

        fun of(request: MediaPickRequestMsg): PickPlan {
            val kinds = request.kinds.toSet()
            val visualOnly = kinds.isNotEmpty() && kinds.all { it == MediaPickKindMsg.VIDEO || it == MediaPickKindMsg.IMAGE }
            return PickPlan(kinds, request.multiple, photoPicker = request.source == MediaPickSourceMsg.PHOTOS && visualOnly)
        }

        /** Whether [mime] / [name] is of [kind]. */
        fun kindOf(kind: MediaPickKindMsg, mime: String?, name: String): Boolean {
            val type = (mime ?: guessMime(name))?.lowercase()
            val ext = name.substringAfterLast('.', "").lowercase()
            return when (kind) {
                MediaPickKindMsg.VIDEO -> type?.startsWith("video/") == true
                MediaPickKindMsg.AUDIO -> type?.startsWith("audio/") == true
                MediaPickKindMsg.IMAGE -> type?.startsWith("image/") == true
                MediaPickKindMsg.LUT -> ext == "cube"
                MediaPickKindMsg.SUBTITLE -> ext == "srt" || ext == "vtt" || type == "application/x-subrip" || type == "text/vtt"
            }
        }

        private fun guessMime(name: String): String? {
            val ext = name.substringAfterLast('.', "").lowercase()
            if (ext.isEmpty()) return null
            return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
        }
    }
}
