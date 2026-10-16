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
//   path is copied the same way. `file://` URIs are percent-decoded like Dart's Uri.toFilePath
//   (M-20, Paths.normalizeFileUriOrPath); plain paths are never decoded.
// - Other schemes: `notSupportedOnDevice`.
// - The copy runs on PickCopier's own thread, never on danaview-io, with a stall timeout and
//   cancellation ([cancelAll], called when the Flutter engine that asked detaches) (M-16).
// - Failures (M-18): an unreadable source (revoked grant, EACCES) `permissionDenied`, a missing item
//   `mediaOffline`, a full disk or a known source size that does not fit `diskFull`, a stall and
//   other I/O `io`, a cancel `cancelled` (PickCopier).
// Called on danaview-io by the glue (which checked that intoDir lies inside work/); it only
// normalizes the URI and hands off. Nothing here logs URIs, names or paths.

package com.vecvel.danaview.editor.engine.platform

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import com.vecvel.danaview.editor.engine.core.Cancellable
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
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Copies picks into the engine's work directory (file header). */
class PickMaterializer(
    private val paths: () -> Paths?,
    private val resolver: () -> ContentResolver,
    private val copier: PickCopier = PickCopier(),
    private val openFile: (File) -> InputStream = { it.inputStream() },
) {
    /** The production materializer over the process context. */
    constructor(ctx: EngineContext, copier: PickCopier = PickCopier()) :
        this({ ctx.pathsOrNull }, { ctx.appContext.contentResolver }, copier)

    private val inFlight: MutableSet<Cancellable> = ConcurrentHashMap.newKeySet()

    /** Copies [uri] into a new directory under [intoDir] and completes with the copy's path. */
    fun materialize(uri: String, intoDir: File, done: Completion<String>) {
        try {
            val prepare = sourceOf(uri) { done.succeed(it) } ?: return
            val handle = AtomicReference<Cancellable?>(null)
            val finished = AtomicBoolean(false)
            val c = copier.start(intoDir, prepare) { result ->
                finished.set(true)
                handle.getAndSet(null)?.let { inFlight.remove(it) }
                done(result)
            }
            if (!finished.get()) {
                inFlight.add(c)
                handle.set(c)
                if (finished.get()) handle.getAndSet(null)?.let { inFlight.remove(it) }
            }
        } catch (t: Throwable) {
            done.fail(EngineErrors.from(t))
        }
    }

    /** Cancels every copy this materializer started that has not completed (each fails `cancelled`). */
    fun cancelAll() {
        for (c in inFlight.toList()) c.cancel()
    }

    /** Copies still running (tests). */
    val running: Int get() = inFlight.size

    /**
     * The copy source of [uri], or null after answering [asIs] with an app-owned temporary copy.
     * Only cheap checks run here (danaview-io); the provider query and open run on the copy thread.
     */
    private fun sourceOf(uri: String, asIs: (String) -> Unit): (() -> PickSource)? {
        val roots = paths() ?: throw EngineErrors.notInitialized()
        if (uri.startsWith("/") || uri.startsWith("file:")) {
            val file = Paths.normalizeFileUriOrPath(uri) ?: throw EngineErrors.invalidArgument("uri", "not an absolute path")
            if (Paths.isInside(file, roots.work)) {
                if (!file.isFile) throw EngineException(EngineErrorCode.mediaOffline, "the picked copy is gone")
                asIs(file.absolutePath)
                return null
            }
            return {
                if (!file.isFile) throw EngineException(EngineErrorCode.mediaOffline, "the picked file is gone")
                PickSource(sanitizedName(file.name, null), file.length()) { openFile(file) }
            }
        }
        val parsed = Uri.parse(uri)
        if (parsed.scheme != "content") throw EngineErrors.notSupported("materializing this URI scheme")
        return { contentSource(parsed) }
    }

    private fun contentSource(parsed: Uri): PickSource {
        val resolver = resolver()
        var name: String? = null
        var size: Long? = null
        try {
            resolver.query(parsed, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (n >= 0 && !c.isNull(n)) name = c.getString(n)
                    val s = c.getColumnIndex(OpenableColumns.SIZE)
                    if (s >= 0 && !c.isNull(s)) size = c.getLong(s).takeIf { it >= 0 }
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
        return PickSource(sanitizedName(base, mime), size) {
            resolver.openInputStream(parsed) ?: throw FileNotFoundException("no stream")
        }
    }

    companion object {
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
