// OWNER: INT-07
//
// `PlatformHostApi.materializePick` on Android (INT-07, ARCH §9.1, §12.4): copies a pick that Dart
// cannot keep by reference (a `content://` URI without a persistable grant, e.g. when the grant
// budget is exhausted or the provider refuses persistence) into `<intoDir>/<uuid>/<name>` and
// returns the copy's absolute path. The copy logic follows AND-15's DropTarget.copyOne: the display
// name from OpenableColumns (sanitized like drops), an extension from the provider MIME type when the
// name has none, a streamed copy, and the directory deleted when the copy fails half-way.
// - A `file://` URI or absolute path already under `<cache>/danaview/editor/work/` (an app-owned
//   temporary copy, ARCH §9.1) is returned as is (`mediaOffline` when it is gone); any other file
//   path is copied the same way.
// - Other schemes: `notSupportedOnDevice`.
// - Failures: a missing item `mediaOffline`, a revoked grant `permissionDenied`, a full disk
//   `diskFull`, other I/O `io` (EngineErrors.from).
// Called on danaview-io by the glue (which checked that intoDir lies inside work/). Nothing here
// logs URIs, names or paths.

package com.vecvel.danaview.editor.engine.platform

import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.Paths
import com.vecvel.danaview.editor.engine.core.fail
import com.vecvel.danaview.editor.engine.core.succeed
import java.io.File
import java.io.FileNotFoundException
import java.io.InputStream
import java.util.UUID

/** Copies picks into the engine's work directory (file header). */
class PickMaterializer(private val ctx: EngineContext) {
    /** Copies [uri] into a new directory under [intoDir] and completes with the copy's path. */
    fun materialize(uri: String, intoDir: File, done: Completion<String>) {
        try {
            done.succeed(copy(uri, intoDir))
        } catch (t: Throwable) {
            done.fail(EngineErrors.from(t))
        }
    }

    private fun copy(uri: String, intoDir: File): String {
        val paths = ctx.pathsOrNull ?: throw EngineErrors.notInitialized()
        if (uri.startsWith("/") || uri.startsWith("file://")) {
            val file = Paths.normalize(uri) ?: throw EngineErrors.invalidArgument("uri", "not an absolute path")
            if (Paths.isInside(file, paths.work)) {
                if (!file.isFile) throw EngineException(EngineErrorCode.mediaOffline, "the picked copy is gone")
                return file.absolutePath
            }
            if (!file.isFile) throw EngineException(EngineErrorCode.mediaOffline, "the picked file is gone")
            return copyStream(intoDir, sanitizedName(file.name, null)) { file.inputStream() }
        }
        val parsed = Uri.parse(uri)
        if (parsed.scheme != "content") throw EngineErrors.notSupported("materializing this URI scheme")
        val resolver = ctx.appContext.contentResolver
        var name: String? = null
        try {
            resolver.query(parsed, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (i >= 0 && !c.isNull(i)) name = c.getString(i)
                }
            }
        } catch (e: RuntimeException) {
            if (e is SecurityException) throw e
        }
        val mime = try {
            resolver.getType(parsed)
        } catch (e: RuntimeException) {
            if (e is SecurityException) throw e
            null
        }
        val base = name ?: parsed.lastPathSegment?.substringAfterLast('/') ?: "pick"
        return copyStream(intoDir, sanitizedName(base, mime)) {
            resolver.openInputStream(parsed) ?: throw FileNotFoundException("no stream")
        }
    }

    private fun copyStream(intoDir: File, fileName: String, open: () -> InputStream): String {
        val dir = File(intoDir, UUID.randomUUID().toString())
        if (!dir.mkdirs()) throw EngineException(EngineErrorCode.io, "cannot create the pick directory")
        val out = File(dir, fileName)
        try {
            open().use { input -> out.outputStream().use { o -> input.copyTo(o, BUFFER) } }
        } catch (t: Throwable) {
            dir.deleteRecursively()
            throw t
        }
        return out.absolutePath
    }

    companion object {
        private const val BUFFER = 256 * 1024

        /** A safe file name for [name] (as for drops), with an extension from [mime] when it has none. */
        fun sanitizedName(name: String, mime: String?): String {
            val safe = DropTarget.sanitize(name).let { if (it == "drop") "pick" else it }
            if (safe.contains('.') || mime == null) return safe
            val ext = try {
                MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
            } catch (e: RuntimeException) {
                null
            } ?: return safe
            return "$safe.$ext"
        }
    }
}
