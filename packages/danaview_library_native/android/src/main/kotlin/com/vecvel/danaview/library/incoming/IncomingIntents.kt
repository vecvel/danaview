// OWNER: HOM-21A
//
// The Android half of incoming intents that needs the platform but not Flutter (instrumented tests
// drive it with real Intents): reading an Intent defensively into an IntentSnapshot, marking a
// claimed Intent as handled so the 1.1 path in MainActivity skips it, the private-storage check for
// file:// URIs, keeping a persistable read grant while a batch is outstanding, and describing each
// item (display name, MIME type, size) through the same queries as the pickers (HOM-20A).
//
// The bytes are not copied here: the batch carries the URIs and Dart's import copies them at once
// with PickerHostApi.copyToFile (HOM-20A's streamed, resumable copier), in this process, while the
// Activity holds the sender's read grant. A text share (EXTRA_TEXT, no stream) is written to
// <cacheDir>/danaview-incoming/<batchId>/ and passed as a file:// URI; that directory goes away on
// acknowledge and stale ones (24 h) on the next start.

package com.vecvel.danaview.library.incoming

import android.content.ClipData
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Parcelable
import android.webkit.MimeTypeMap
import com.vecvel.danaview.library.pickers.AndroidPickers
import com.vecvel.danaview.library.pickers.PickerRequests
import com.vecvel.danaview.library.pigeon.IncomingBatchMsg
import com.vecvel.danaview.library.pigeon.IncomingItemMsg
import com.vecvel.danaview.library.pigeon.PickedSourceMsg
import java.io.File
import java.io.IOException
import java.util.UUID

class IncomingIntents(context: Context) {
    private val app = context.applicationContext
    private val resolver: ContentResolver = app.contentResolver
    private val pickers = AndroidPickers(app)

    /** Where text shares are written; one directory per batch. */
    val textRoot: File get() = File(app.cacheDir, TEXT_DIR)

    // ---------------------------------------------------------------------------------------------
    // Reading and claiming an Intent (main thread)

    /** The routing decision for [intent]; never throws (a malformed intent is Ignore). */
    fun route(intent: Intent?): Pair<IntentSnapshot, IncomingRoute> {
        val s = snapshot(intent)
        val route = try {
            IncomingRouting.route(s, ::providerType, ::allowFile)
        } catch (e: RuntimeException) {
            IncomingRoute.Ignore
        }
        return s to route
    }

    private fun providerType(uri: String): String? = resolver.getType(Uri.parse(uri))

    /**
     * Marks [intent] (the Activity's own object) as handled: MainActivity's 1.1 handler only acts on
     * VIEW and SEND, so it skips it, and nothing else reads its URIs. Main thread, before
     * MainActivity's handler runs (the plugin is attached inside super.onCreate and called first in
     * super.onNewIntent).
     */
    fun markHandled(intent: Intent) {
        try {
            intent.action = ACTION_HANDLED
            intent.setDataAndType(null, null)
            intent.clipData = null
            intent.removeExtra(Intent.EXTRA_STREAM)
            intent.removeExtra(Intent.EXTRA_TEXT)
        } catch (e: RuntimeException) {
            // A broken extras bundle: the action change above is what MainActivity reads.
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Describing a claimed intent (incoming thread)

    /**
     * The batch of a claimed [route]: each item described (name, type, size), names numbered on
     * clashes, a text share written to a file. Persistable grants are kept when the sender offered
     * them ([persistable]); [kept] gets each URI whose grant was taken. Null when nothing is left.
     */
    fun describe(route: IncomingRoute.Incoming, persistable: Boolean, nowMs: Long, kept: (String) -> Unit): IncomingBatchMsg? {
        val batchId = UUID.randomUUID().toString()
        val items = ArrayList<IncomingItemMsg>()
        for (c in route.items) {
            val item = try {
                describeItem(c)
            } catch (e: RuntimeException) {
                // An item the provider refuses still goes to Dart: its copy fails there with a message.
                IncomingItemMsg(c.uri, PickerRequests.displayName(null, Uri.parse(c.uri).lastPathSegment, null), c.mimeType, null)
            }
            if (persistable && IncomingRouting.scheme(c.uri) == "content" && takeGrant(c.uri)) kept(c.uri)
            items.add(item)
        }
        route.text?.let { text ->
            val file = writeText(batchId, IncomingRouting.textFileName(route.subject, nowMs), text) ?: return null
            items.add(IncomingItemMsg(Uri.fromFile(file).toString(), file.name, "text/plain", file.length()))
        }
        if (items.isEmpty()) return null
        val names = PickerRequests.uniqueNames(items.map { it.displayName ?: "Imported item" })
        val named = items.mapIndexed { i, it -> if (it.displayName == names[i]) it else it.copy(displayName = names[i]) }
        return IncomingBatchMsg(batchId, route.action, named)
    }

    private fun describeItem(c: IncomingCandidate): IncomingItemMsg {
        val uri = Uri.parse(c.uri)
        if (IncomingRouting.scheme(c.uri) == "file") {
            val file = File(uri.path ?: "")
            val type = IncomingRouting.typeFromName(file.name) ?: mimeOfName(file.name) ?: c.mimeType
            val ext = type?.let { MimeTypeMap.getSingleton().getExtensionFromMimeType(it) }
            return IncomingItemMsg(
                uri = c.uri,
                displayName = PickerRequests.displayName(file.name, null, ext),
                mimeType = type,
                sizeBytes = file.length().takeIf { file.isFile },
            )
        }
        val picked = pickers.describe(uri, PickedSourceMsg.FILES)
        val type = IncomingRouting.concreteType(picked.mimeType) ?: c.mimeType ?: IncomingRouting.typeFromName(picked.displayName)
        return IncomingItemMsg(uri = c.uri, displayName = picked.displayName, mimeType = type, sizeBytes = picked.sizeBytes)
    }

    private fun mimeOfName(name: String): String? =
        name.substringAfterLast('.', "").lowercase().takeIf { it.isNotEmpty() }?.let { MimeTypeMap.getSingleton().getMimeTypeFromExtension(it) }

    private fun writeText(batchId: String, name: String, text: String): File? = try {
        val dir = File(textRoot, batchId)
        if (!dir.mkdirs() && !dir.isDirectory) throw IOException("no text directory")
        val file = File(dir, name)
        file.outputStream().use { out ->
            out.write(text.toByteArray(Charsets.UTF_8))
            out.fd.sync()
        }
        file
    } catch (e: IOException) {
        null
    }

    // ---------------------------------------------------------------------------------------------
    // Grants and cleanup

    // Grants kept by this class, with the time they were taken, so a batch never acknowledged
    // (process death) gives its grants back on a later start. Other persisted grants of the app
    // (linked folders) are never touched.
    private val keptGrants get() = app.getSharedPreferences(GRANTS_PREFS, Context.MODE_PRIVATE)

    /** Keeps the read grant of [uri] beyond this Activity; false when the sender gave none to keep. */
    private fun takeGrant(uri: String): Boolean = try {
        resolver.takePersistableUriPermission(Uri.parse(uri), Intent.FLAG_GRANT_READ_URI_PERMISSION)
        keptGrants.edit().putLong(uri, System.currentTimeMillis()).apply()
        true
    } catch (e: SecurityException) {
        false
    } catch (e: RuntimeException) {
        false
    }

    /** Gives up a grant [takeGrant] kept. */
    fun releaseGrant(uri: String) {
        try {
            resolver.releasePersistableUriPermission(Uri.parse(uri), Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (e: RuntimeException) {
            // Already gone.
        }
        keptGrants.edit().remove(uri).apply()
    }

    /** Deletes the text directory of [batchId] (if it has one). */
    fun deleteBatchFiles(batchId: String) {
        if (batchId.isEmpty() || batchId.contains('/') || batchId.contains("..")) return
        File(textRoot, batchId).deleteRecursively()
    }

    /** Deletes text directories older than [maxAgeMs] (a batch Dart never acknowledged). */
    fun sweep(nowMs: Long, maxAgeMs: Long = STALE_MS) {
        textRoot.listFiles()?.forEach { if (nowMs - it.lastModified() > maxAgeMs) it.deleteRecursively() }
        val stale = keptGrants.all.filter { (_, at) -> at !is Long || nowMs - at > maxAgeMs }.keys
        stale.forEach(::releaseGrant)
    }

    // ---------------------------------------------------------------------------------------------
    // file:// safety

    /**
     * Whether a file:// [uri] from another app may be read: an absolute path outside the app's
     * private storage (a sender could otherwise make Danaview import its own private files). On
     * Android 7+ other apps can't send file:// URIs without crashing (FileUriExposedException), so
     * these come from old or misbehaving senders; the copy reads them with the app's own access.
     */
    fun allowFile(uri: String): Boolean = try {
        val path = Uri.parse(uri).path
        if (path.isNullOrEmpty() || !path.startsWith("/")) {
            false
        } else {
            val canonical = File(path).canonicalPath
            !IncomingRouting.isInside(canonical, privateRoots())
        }
    } catch (e: IOException) {
        false
    } catch (e: RuntimeException) {
        false
    }

    private fun privateRoots(): List<String> {
        val roots = LinkedHashSet<String>()
        fun add(f: File?) {
            if (f == null) return
            roots.add(f.absolutePath)
            runCatching { roots.add(f.canonicalPath) }
        }
        add(File(app.applicationInfo.dataDir))
        add(app.filesDir)
        add(app.cacheDir)
        add(app.noBackupFilesDir)
        if (Build.VERSION.SDK_INT >= 24) add(File(app.createDeviceProtectedStorageContext().applicationInfo.dataDir))
        // The /data/data/<package> alias of /data/user/0/<package>.
        add(File("/data/data/${app.packageName}"))
        add(File("/data/user/0/${app.packageName}"))
        return roots.toList()
    }

    companion object {
        /** The action a claimed Intent is given once the plugin took it (see [markHandled]). */
        const val ACTION_HANDLED = "com.vecvel.danaview.library.action.INCOMING_HANDLED"
        const val TEXT_DIR = "danaview-incoming"
        const val STALE_MS = 24L * 60 * 60 * 1000
        const val GRANTS_PREFS = "danaview_library_incoming_grants"

        /** Reads [intent] without trusting it: any part that fails to read is left out. */
        fun snapshot(intent: Intent?): IntentSnapshot {
            if (intent == null) return IntentSnapshot(action = null)
            val action = runCatching { intent.action }.getOrNull()
            val type = runCatching { intent.type }.getOrNull()
            val data = runCatching { intent.data?.toString() }.getOrNull()
            val flags = runCatching { intent.flags }.getOrDefault(0)
            val clip = runCatching { intent.clipData }.getOrNull()
            val clipUris = ArrayList<String>()
            var clipText: String? = null
            if (clip != null) {
                for (i in 0 until runCatching { clip.itemCount }.getOrDefault(0)) {
                    val item: ClipData.Item = runCatching { clip.getItemAt(i) }.getOrNull() ?: continue
                    runCatching { item.uri?.toString() }.getOrNull()?.let { clipUris.add(it) }
                    if (clipText == null) clipText = runCatching { item.text?.toString() }.getOrNull()
                }
            }
            val streams = ArrayList<String>()
            when (action) {
                Intent.ACTION_SEND -> streamExtra(intent)?.let { streams.add(it) }
                Intent.ACTION_SEND_MULTIPLE -> streams.addAll(streamListExtra(intent))
            }
            val text = runCatching { intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() }.getOrNull() ?: clipText
            val subject = runCatching { intent.getStringExtra(Intent.EXTRA_SUBJECT) }.getOrNull()
                ?: runCatching { intent.getCharSequenceExtra(Intent.EXTRA_TITLE)?.toString() }.getOrNull()
            return IntentSnapshot(
                action = action,
                type = type,
                data = data,
                streams = streams,
                clipUris = clipUris,
                text = text,
                subject = subject,
                fromHistory = flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0,
                persistableGrant = flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0,
            )
        }

        // EXTRA_STREAM is a Uri; some senders put a String. A wrong type or a bad Parcel reads as null.
        @Suppress("DEPRECATION")
        private fun streamExtra(intent: Intent): String? = try {
            when (val v = intent.extras?.get(Intent.EXTRA_STREAM)) {
                is Uri -> v.toString()
                is String -> v
                else -> null
            }
        } catch (e: RuntimeException) {
            null
        }

        @Suppress("DEPRECATION")
        private fun streamListExtra(intent: Intent): List<String> = try {
            when (val v = intent.extras?.get(Intent.EXTRA_STREAM)) {
                is ArrayList<*> -> v.mapNotNull { e -> (e as? Uri)?.toString() ?: (e as? String) }
                is Array<*> -> v.mapNotNull { e -> (e as? Uri)?.toString() ?: (e as? String) }
                is Uri -> listOf(v.toString())
                is Parcelable -> emptyList()
                else -> emptyList()
            }
        } catch (e: RuntimeException) {
            emptyList()
        }
    }
}
