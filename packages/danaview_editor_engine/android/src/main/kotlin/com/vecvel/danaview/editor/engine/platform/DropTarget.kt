// OWNER: AND-15
//
// External drop target (ARCH §9.1, §12.4, §15 External drop, D-18; BUILD_PLAN AND-15).
//
// - setEnabled(true) installs a View.OnDragListener on the activity's FlutterView (found by class
//   in the view tree; the content view when there is none); setEnabled(false) removes it. Dart
//   enables it only while the editor is shown, so drops are refused everywhere else. A recreated
//   activity (configuration change) gets the listener again on its first resume while enabled.
// - Accepted: video/*, audio/*, image/* and `.cube` LUTs (no registered MIME type: accepted by name,
//   or from application/octet-stream / text/plain descriptions). ACTION_DRAG_STARTED answers whether
//   the ClipDescription offers any of them, so the system shows a "no drop" state otherwise.
// - ACTION_DROP: Activity.requestDragAndDropPermissions(event) (needed for another app's
//   content:// URIs), then every acceptable URI is copied on danaview-io into
//   <cache>/danaview/editor/work/drops/<uuid>/<name> while the permissions are held; the
//   permissions are released right after the copies, and one `drop` event goes to Dart with the
//   copies (absolute paths, origin drop, isTemporaryCopy = true: Dart moves them into media/, ARCH
//   §9.1) and the drop position in logical pixels relative to the FlutterView (event x/y divided by
//   the display density). Unsupported or unreadable items are skipped; a drop with nothing usable
//   sends no event. Copies that fail half-way are deleted.
// - Nothing here logs URIs, names or paths.

package com.vecvel.danaview.editor.engine.platform

import android.app.Activity
import android.app.Application
import android.content.ClipData
import android.content.ClipDescription
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.util.Log
import android.view.DragAndDropPermissions
import android.view.DragEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.MimeTypeMap
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.succeed
import com.vecvel.danaview.editor.engine.pigeon.DropMsg
import com.vecvel.danaview.editor.engine.pigeon.PickOriginMsg
import com.vecvel.danaview.editor.engine.pigeon.PickedMediaMsg
import java.io.File
import java.io.IOException
import java.util.UUID

/** External drop target on the FlutterView (ARCH §15 External drop, D-18; AND-15). Called on main. */
class DropTarget(private val ctx: EngineContext) {
    @Volatile private var enabled = false
    private var target: View? = null
    private var lifecycleRegistered = false

    /** Whether the drop target is enabled. */
    val isEnabled: Boolean get() = enabled

    /** The view that carries the listener now (tests). */
    internal val attachedView: View? get() = target

    /** Called after each drop's copies finished and its permissions were released (tests). */
    internal var onDropHandled: ((DropMsg?) -> Unit)? = null

    private val listener = View.OnDragListener { view, event -> onDrag(view, event) }

    private val lifecycle = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityResumed(activity: Activity) {
            if (enabled && activity === ctx.activityHost.activity) attach(activity)
        }

        override fun onActivityDestroyed(activity: Activity) {
            if (target?.context === activity) detach()
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
        override fun onActivityStarted(activity: Activity) = Unit
        override fun onActivityPaused(activity: Activity) = Unit
        override fun onActivityStopped(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    }

    /** Enables or disables the drop target; drops arrive as ctx.events.drop. */
    fun setEnabled(enabled: Boolean, done: Completion<Unit>) {
        this.enabled = enabled
        if (enabled) {
            if (!lifecycleRegistered) {
                (ctx.appContext as? Application)?.registerActivityLifecycleCallbacks(lifecycle)
                lifecycleRegistered = true
            }
            ctx.activityHost.activity?.let(::attach)
        } else {
            detach()
        }
        done.succeed(Unit)
    }

    private fun attach(activity: Activity) {
        val view = findFlutterView(activity.window?.decorView) ?: activity.findViewById(android.R.id.content) ?: return
        if (target === view) return
        detach()
        view.setOnDragListener(listener)
        target = view
    }

    private fun detach() {
        target?.setOnDragListener(null)
        target = null
    }

    private fun onDrag(view: View, event: DragEvent): Boolean {
        if (!enabled) return false
        return when (event.action) {
            DragEvent.ACTION_DRAG_STARTED -> offersAcceptable(event.clipDescription)
            DragEvent.ACTION_DRAG_ENTERED, DragEvent.ACTION_DRAG_LOCATION, DragEvent.ACTION_DRAG_EXITED -> true
            DragEvent.ACTION_DROP -> {
                handleDrop(view, event)
                true
            }
            DragEvent.ACTION_DRAG_ENDED -> true
            else -> false
        }
    }

    private fun handleDrop(view: View, event: DragEvent) {
        val clip = event.clipData ?: return onDropHandled?.invoke(null) ?: Unit
        val description = event.clipDescription
        val activity = view.context as? Activity ?: ctx.activityHost.activity
        // Held until released below; dropped automatically when the activity is destroyed.
        val permissions: DragAndDropPermissions? = activity?.requestDragAndDropPermissions(event)
        val density = view.resources.displayMetrics.density.takeIf { it > 0f } ?: 1f
        val x = (event.x / density).toDouble()
        val y = (event.y / density).toDouble()
        val uris = urisOf(clip)
        ctx.threads.io.execute {
            val items = try {
                copyAll(uris, description)
            } finally {
                ctx.threads.main.execute { permissions?.release() }
            }
            val msg = if (items.isEmpty()) null else DropMsg(items = items, x = x, y = y)
            ctx.threads.main.execute {
                if (msg != null) ctx.events.drop(msg) else Log.i(TAG, "drop: nothing usable")
                onDropHandled?.invoke(msg)
            }
        }
    }

    private fun copyAll(uris: List<Uri>, description: ClipDescription?): List<PickedMediaMsg> {
        val paths = ctx.pathsOrNull ?: return emptyList<PickedMediaMsg>().also { Log.w(TAG, "drop before initialize") }
        val out = ArrayList<PickedMediaMsg>()
        for (uri in uris) {
            val item = try {
                copyOne(uri, description, paths.workDrops)
            } catch (e: IOException) {
                Log.w(TAG, "drop: copy failed (${e.javaClass.simpleName})")
                null
            } catch (e: SecurityException) {
                Log.w(TAG, "drop: no access to an item")
                null
            } catch (e: IllegalArgumentException) {
                Log.w(TAG, "drop: unreadable item")
                null
            }
            if (item != null) out += item
        }
        return out
    }

    private fun copyOne(uri: Uri, description: ClipDescription?, dropsRoot: File): PickedMediaMsg? {
        val resolver = ctx.appContext.contentResolver
        var name: String? = null
        if (uri.scheme == "content") {
            try {
                resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (i >= 0 && !c.isNull(i)) name = c.getString(i)
                    }
                }
            } catch (e: RuntimeException) {
                if (e is SecurityException) throw e
            }
        }
        val displayName = sanitize(name ?: uri.lastPathSegment?.substringAfterLast('/') ?: "drop")
        val mime = if (uri.scheme == "content") resolver.getType(uri) else null
        if (!acceptable(mime, displayName, description)) return null
        val dir = File(dropsRoot, UUID.randomUUID().toString())
        if (!dir.mkdirs()) throw IOException("cannot create the drop directory")
        val outFile = File(dir, withExtension(displayName, mime))
        try {
            val input = resolver.openInputStream(uri) ?: throw IOException("no stream")
            input.use { i -> outFile.outputStream().use { o -> i.copyTo(o, BUFFER) } }
        } catch (e: Throwable) {
            dir.deleteRecursively()
            throw e
        }
        return PickedMediaMsg(
            uri = outFile.absolutePath,
            displayName = displayName,
            origin = PickOriginMsg.DROP,
            isTemporaryCopy = true,
            bookmark = null,
            sizeBytes = outFile.length(),
        )
    }

    companion object {
        private const val TAG = EngineContext.TAG
        private const val BUFFER = 256 * 1024
        private const val FLUTTER_VIEW = "io.flutter.embedding.android.FlutterView"

        /** MIME families accepted by name; `.cube` is matched by extension. */
        private val FAMILIES = listOf("video/", "audio/", "image/")

        /** Descriptions that may carry a `.cube` file (no registered MIME type). */
        private val GENERIC = listOf("application/octet-stream", "text/plain", "application/x-cube", "*/*")

        /** Whether a drag offering [description] carries anything the editor accepts. */
        internal fun offersAcceptable(description: ClipDescription?): Boolean {
            if (description == null) return false
            for (i in 0 until description.mimeTypeCount) {
                val type = description.getMimeType(i).lowercase()
                if (FAMILIES.any { type.startsWith(it) } || type in GENERIC) return true
            }
            return false
        }

        /** Whether one item ([mime] from the provider, [name]) is accepted. */
        internal fun acceptable(mime: String?, name: String, description: ClipDescription?): Boolean {
            val ext = name.substringAfterLast('.', "").lowercase()
            if (ext == "cube") return true
            val type = (mime ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
                ?: description?.takeIf { it.mimeTypeCount == 1 }?.getMimeType(0))?.lowercase() ?: return false
            return FAMILIES.any { type.startsWith(it) }
        }

        internal fun urisOf(clip: ClipData): List<Uri> {
            val out = LinkedHashSet<Uri>()
            for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(out::add)
            return out.toList()
        }

        /** A file name without separators or control characters, at most 120 characters. */
        internal fun sanitize(name: String): String {
            val cleaned = name.map { c -> if (c == '/' || c == '\\' || c == ':' || c.code < 0x20) '_' else c }
                .joinToString("").trim().trimStart('.')
            val safe = cleaned.ifEmpty { "drop" }
            if (safe.length <= 120) return safe
            val ext = safe.substringAfterLast('.', "")
            return if (ext.isNotEmpty() && ext.length < 10) safe.take(119 - ext.length) + "." + ext else safe.take(120)
        }

        /** [name] with an extension derived from [mime] when it has none. */
        private fun withExtension(name: String, mime: String?): String {
            if (name.contains('.') || mime == null) return name
            val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: return name
            return "$name.$ext"
        }

        private fun findFlutterView(root: View?): View? {
            if (root == null) return null
            if (root.javaClass.name == FLUTTER_VIEW) return root
            if (root is ViewGroup) {
                for (i in 0 until root.childCount) findFlutterView(root.getChildAt(i))?.let { return it }
            }
            return null
        }
    }
}
