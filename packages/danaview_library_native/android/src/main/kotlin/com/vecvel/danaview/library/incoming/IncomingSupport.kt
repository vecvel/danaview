// OWNER: HOM-21A
//
// The pure (Android-free, JVM-tested) half of Android incoming intents (BUILD_PLAN HOM-21A; ARCH
// v1.2 §5.6, INT-104):
//
// - IntentSnapshot: what an ACTION_VIEW / ACTION_SEND / ACTION_SEND_MULTIPLE intent carried, read
//   defensively by IncomingIntents.snapshot (a malformed intent becomes an empty snapshot).
// - IncomingRouting.route: who handles it.
//     * VIEW of one content:// or file:// document, text or image  -> the incoming bridge (import +
//       viewer, HOM-21).
//     * VIEW / SEND of one video or audio item, VIEW of any other scheme (http, https, rtsp,
//       danaview, ...) and VIEW of an unknown type -> the 1.1 player path, untouched (P-7, P-8):
//       the intent is left as it is for MainActivity's "danaview/media_intent" channel.
//     * SEND of one non-video item (any type, including unknown ones), SEND of text only
//       (EXTRA_TEXT) and every SEND_MULTIPLE (videos included: a share of several items imports them,
//       as the iOS Share Extension does) -> the incoming bridge.
//     * other actions, or a claimed action without one usable item -> nothing (Ignore).
//     * a document, text or image as a file:// URI inside the app's private storage -> Refused
//       (claimed so that neither path opens it; nothing delivered).
//   Items are content:// or file:// URIs only (other schemes are dropped), de-duplicated, at most
//   MAX_ITEMS per batch; file:// paths inside the app's private storage are refused.
// - IncomingQueue: batches waiting for Dart. A batch stays pending until takePending returns it or
//   Dart acknowledges it; the `incoming` event is only a nudge (Dart may not be listening for it),
//   so a batch is never lost and the Dart wrapper drops a batch id it already delivered.
//
// Nothing here logs a name, a path or a URI (rule 30).

package com.vecvel.danaview.library.incoming

import com.vecvel.danaview.library.pigeon.IncomingActionMsg
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/** The parts of an incoming intent the routing reads. Lists keep the intent's order. */
data class IntentSnapshot(
    val action: String?,
    /** The intent's MIME type (the type the manifest filter matched; may be a wildcard). */
    val type: String? = null,
    /** Intent.getData() as a string. */
    val data: String? = null,
    /** EXTRA_STREAM: one URI for SEND, the list for SEND_MULTIPLE. */
    val streams: List<String> = emptyList(),
    /** ClipData item URIs. */
    val clipUris: List<String> = emptyList(),
    /** EXTRA_TEXT (else the first ClipData text). */
    val text: String? = null,
    /** EXTRA_SUBJECT, else EXTRA_TITLE: names a shared text. */
    val subject: String? = null,
    /** FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY: a relaunch from Recents re-delivers an old intent. */
    val fromHistory: Boolean = false,
    /** FLAG_GRANT_PERSISTABLE_URI_PERMISSION: the sender lets us keep the read grant. */
    val persistableGrant: Boolean = false,
) {
    companion object {
        const val ACTION_VIEW = "android.intent.action.VIEW"
        const val ACTION_SEND = "android.intent.action.SEND"
        const val ACTION_SEND_MULTIPLE = "android.intent.action.SEND_MULTIPLE"
    }
}

/** What one incoming item is, for routing. */
enum class IncomingKind { VIDEO, AUDIO, DOCUMENT, IMAGE, TEXT, UNKNOWN }

/** One URI of a claimed intent and the type the routing saw for it (null: unknown). */
data class IncomingCandidate(val uri: String, val mimeType: String?)

sealed class IncomingRoute {
    /** Leave the intent to the 1.1 player path (MainActivity). */
    object Player : IncomingRoute()

    /** Nobody handles it (not an incoming action, or nothing usable in it). */
    object Ignore : IncomingRoute()

    /**
     * Ours, but refused: a document or image as a file:// URI inside the app's private storage.
     * The intent is marked handled (so the 1.1 path doesn't open it either) and nothing is delivered.
     */
    object Refused : IncomingRoute()

    /** The incoming bridge: [items] (URIs) or, for a text share, [text]. */
    data class Incoming(
        val action: IncomingActionMsg,
        val items: List<IncomingCandidate>,
        val text: String? = null,
        val subject: String? = null,
        val dropped: Int = 0,
    ) : IncomingRoute()
}

object IncomingRouting {
    /** At most this many items per batch; the rest are dropped (counted). */
    const val MAX_ITEMS = 500

    /** A shared text longer than this is cut (Binder already limits an intent to about 1 MB). */
    const val MAX_TEXT_CHARS = 1_000_000

    /**
     * The document MIME types of INT-104's VIEW filter (besides text/<any> and image/<any>). The
     * manifest (android/app/src/main/AndroidManifest.xml, "EXTENDED: INT-104/HOM-21A") lists the same.
     */
    val DOCUMENT_TYPES = listOf(
        "application/pdf",
        "application/msword",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.ms-excel",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.ms-powerpoint",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/vnd.oasis.opendocument.text",
        "application/vnd.oasis.opendocument.spreadsheet",
        "application/vnd.oasis.opendocument.presentation",
        "application/rtf",
    )

    // Extension fallback when neither the intent nor the provider names a type (file:// URIs,
    // providers answering null or application/octet-stream). Lower case, without the dot.
    private val EXTENSION_TYPES = mapOf(
        "pdf" to "application/pdf",
        "doc" to "application/msword",
        "docx" to "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls" to "application/vnd.ms-excel",
        "xlsx" to "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt" to "application/vnd.ms-powerpoint",
        "pptx" to "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "odt" to "application/vnd.oasis.opendocument.text",
        "ods" to "application/vnd.oasis.opendocument.spreadsheet",
        "odp" to "application/vnd.oasis.opendocument.presentation",
        "rtf" to "application/rtf",
        "txt" to "text/plain",
        "csv" to "text/csv",
        "md" to "text/markdown",
        "json" to "application/json",
        "jpg" to "image/jpeg",
        "jpeg" to "image/jpeg",
        "png" to "image/png",
        "gif" to "image/gif",
        "webp" to "image/webp",
        "heic" to "image/heic",
        "heif" to "image/heif",
        "avif" to "image/avif",
        "bmp" to "image/bmp",
        "dng" to "image/x-adobe-dng",
        "mp4" to "video/mp4",
        "m4v" to "video/x-m4v",
        "mov" to "video/quicktime",
        "mkv" to "video/x-matroska",
        "webm" to "video/webm",
        "avi" to "video/x-msvideo",
        "3gp" to "video/3gpp",
        "ts" to "video/mp2t",
        "mp3" to "audio/mpeg",
        "m4a" to "audio/mp4",
        "aac" to "audio/aac",
        "wav" to "audio/wav",
        "flac" to "audio/flac",
        "ogg" to "audio/ogg",
        "opus" to "audio/opus",
    )

    /** A real MIME type ("type/subtype", no wildcard, not octet-stream), lower case; else null. */
    fun concreteType(mime: String?): String? {
        val m = mime?.trim()?.lowercase(Locale.ROOT)?.substringBefore(';')?.trim() ?: return null
        val slash = m.indexOf('/')
        if (slash <= 0 || slash == m.length - 1 || m.contains('*')) return null
        if (m == "application/octet-stream") return null
        return m
    }

    /** The MIME type of a file name's extension (the table above), else null. */
    fun typeFromName(name: String?): String? {
        val n = name?.substringAfterLast('/')?.trim() ?: return null
        val dot = n.lastIndexOf('.')
        if (dot <= 0 || dot == n.length - 1) return null
        return EXTENSION_TYPES[n.substring(dot + 1).lowercase(Locale.ROOT)]
    }

    /** The kind of a MIME type (wildcards such as "video/<any>" count by their top level). */
    fun kind(mime: String?): IncomingKind {
        val m = mime?.trim()?.lowercase(Locale.ROOT)?.substringBefore(';') ?: return IncomingKind.UNKNOWN
        return when {
            m.startsWith("video/") -> IncomingKind.VIDEO
            m.startsWith("audio/") -> IncomingKind.AUDIO
            m.startsWith("image/") -> IncomingKind.IMAGE
            m.startsWith("text/") -> IncomingKind.TEXT
            m in DOCUMENT_TYPES -> IncomingKind.DOCUMENT
            else -> IncomingKind.UNKNOWN
        }
    }

    /** The URI scheme in lower case ("" when there is none). */
    fun scheme(uri: String): String {
        val colon = uri.indexOf(':')
        if (colon <= 0) return ""
        val s = uri.substring(0, colon)
        return if (s.all { it.isLetterOrDigit() || it == '+' || it == '-' || it == '.' }) s.lowercase(Locale.ROOT) else ""
    }

    private fun isLocal(uri: String) = scheme(uri).let { it == "content" || it == "file" }

    /**
     * The type of one item: the provider's ([resolveType], content:// only), else the intent's
     * [intentType] when it is concrete, else the name's extension.
     */
    private fun itemType(uri: String, intentType: String?, resolveType: (String) -> String?): String? =
        (if (scheme(uri) == "content") concreteType(runCatching { resolveType(uri) }.getOrNull()) else null)
            ?: concreteType(intentType)
            ?: typeFromName(uri.substringBefore('?').substringBefore('#'))

    /**
     * Routes [s]. [resolveType] asks the provider for a content:// URI's type (it may throw);
     * [allowFile] says whether a file:// URI may be read (false for the app's private storage).
     */
    fun route(s: IntentSnapshot, resolveType: (String) -> String?, allowFile: (String) -> Boolean): IncomingRoute {
        when (s.action) {
            IntentSnapshot.ACTION_VIEW -> {
                val data = s.data?.trim()?.takeIf { it.isNotEmpty() } ?: return IncomingRoute.Ignore
                // http(s), rtsp, danaview:// and the rest stay on the 1.1 path (P-7, P-8).
                if (!isLocal(data)) return IncomingRoute.Player
                // VIEW's type is the one the filter matched; the provider and the name only fill a gap.
                val type = concreteType(s.type) ?: itemType(data, s.type, resolveType)
                val kind = kind(type ?: s.type)
                return when (kind) {
                    IncomingKind.DOCUMENT, IncomingKind.IMAGE, IncomingKind.TEXT -> {
                        if (scheme(data) == "file" && !allowFile(data)) return IncomingRoute.Refused
                        IncomingRoute.Incoming(IncomingActionMsg.VIEW, listOf(IncomingCandidate(data, type)))
                    }
                    // Video, audio and unknown types: exactly as in 1.1.
                    else -> IncomingRoute.Player
                }
            }
            IntentSnapshot.ACTION_SEND -> {
                val uri = (s.streams + s.clipUris + listOfNotNull(s.data)).firstOrNull { it.isNotBlank() }?.trim()
                if (uri == null) {
                    val text = s.text?.takeIf { it.isNotBlank() } ?: return IncomingRoute.Ignore
                    return IncomingRoute.Incoming(
                        IncomingActionMsg.SEND,
                        emptyList(),
                        text = if (text.length > MAX_TEXT_CHARS) text.substring(0, MAX_TEXT_CHARS) else text,
                        subject = s.subject,
                    )
                }
                if (!isLocal(uri)) return IncomingRoute.Ignore
                val type = itemType(uri, s.type, resolveType)
                val kind = kind(type ?: s.type)
                if (kind == IncomingKind.VIDEO || kind == IncomingKind.AUDIO) return IncomingRoute.Player
                if (scheme(uri) == "file" && !allowFile(uri)) return IncomingRoute.Refused
                return IncomingRoute.Incoming(IncomingActionMsg.SEND, listOf(IncomingCandidate(uri, type)))
            }
            IntentSnapshot.ACTION_SEND_MULTIPLE -> {
                // EXTRA_STREAM is the contract; ClipData mirrors it (and is all some senders fill).
                val all = (s.streams.ifEmpty { s.clipUris }).map { it.trim() }.filter { it.isNotEmpty() }.distinct()
                var dropped = 0
                val items = ArrayList<IncomingCandidate>()
                for (uri in all) {
                    if (!isLocal(uri) || (scheme(uri) == "file" && !allowFile(uri))) {
                        dropped++
                        continue
                    }
                    if (items.size >= MAX_ITEMS) {
                        dropped++
                        continue
                    }
                    // Every item is claimed, so no provider is asked here (main thread); the
                    // metadata pass on the incoming thread asks each one.
                    items.add(IncomingCandidate(uri, itemType(uri, s.type) { null }))
                }
                if (items.isEmpty()) return IncomingRoute.Ignore
                return IncomingRoute.Incoming(IncomingActionMsg.SEND_MULTIPLE, items, dropped = dropped)
            }
            else -> return IncomingRoute.Ignore
        }
    }

    /** The most UTF-8 bytes of a shared text's name before ".txt" (as CopyNaming's 200 cap; the
     * library's 255-byte entry limit leaves room for " (999).txt"). */
    const val TEXT_NAME_MAX_BYTES = 200

    /**
     * The file name of a shared text (0dc39697): the sender's subject made safe for a file name
     * (characters invalid on Android, Windows or macOS - / \ : * ? " < > | and control characters -
     * become spaces, whitespace collapsed, leading/trailing dots and spaces trimmed, at most
     * [TEXT_NAME_MAX_BYTES] UTF-8 bytes cut on a character boundary), else
     * "Shared text yyyy-MM-dd HHmm" in local time ([zone]); always ending in ".txt". Clashes with the
     * library's names become "Name (2).txt" when the import commits (uniqueName).
     */
    fun textFileName(subject: String?, nowMs: Long, zone: TimeZone = TimeZone.getDefault()): String {
        val cleaned = subject?.let { safeTextBase(it) }
        val base = cleaned ?: ("Shared text " + SimpleDateFormat("yyyy-MM-dd HHmm", Locale.US).apply { timeZone = zone }.format(Date(nowMs)))
        return if (base.lowercase(Locale.ROOT).endsWith(".txt")) base else "$base.txt"
    }

    /** [subject] as a safe base name, or null when nothing usable is left. */
    internal fun safeTextBase(subject: String): String? {
        var s = subject
            .replace(Regex("[\\u0000-\\u001f\\u007f-\\u009f\\u2028\\u2029/\\\\:*?\"<>|]"), " ")
            .replace(Regex("\\s+"), " ")
            .trim(' ', '.')
        s = cutUtf8(s, TEXT_NAME_MAX_BYTES).trim(' ', '.')
        return s.takeIf { it.isNotEmpty() }
    }

    /** The longest prefix of [s] of at most [maxBytes] UTF-8 bytes, never splitting a code point. */
    internal fun cutUtf8(s: String, maxBytes: Int): String {
        var bytes = 0
        var i = 0
        while (i < s.length) {
            val cp = s.codePointAt(i)
            val n = if (cp < 0x80) 1 else if (cp < 0x800) 2 else if (cp < 0x10000) 3 else 4
            if (bytes + n > maxBytes) break
            bytes += n
            i += Character.charCount(cp)
        }
        return s.substring(0, i)
    }

    /**
     * True when [path] (canonical) is inside one of [privateRoots] (canonical): a file:// URI there
     * would make the app import its own private data, so it is refused.
     */
    fun isInside(path: String, privateRoots: List<String>): Boolean = privateRoots.any { root ->
        val r = root.trimEnd('/')
        r.isNotEmpty() && (path == r || path.startsWith("$r/"))
    }
}

/**
 * Batches waiting for Dart (main thread). [add] queues; [takePending] hands each pending batch out
 * once; [acknowledge] forgets a batch (taken or not) and returns it so its grants and files can be
 * released. Unknown ids are ignored.
 */
class IncomingQueue<T>(private val idOf: (T) -> String) {
    private val pending = LinkedHashMap<String, T>()
    private val taken = LinkedHashMap<String, T>()

    fun add(batch: T) {
        val id = idOf(batch)
        if (!taken.containsKey(id)) pending[id] = batch
    }

    fun takePending(): List<T> {
        val out = pending.values.toList()
        pending.clear()
        out.forEach { taken[idOf(it)] = it }
        return out
    }

    fun acknowledge(id: String): T? = pending.remove(id) ?: taken.remove(id)

    val pendingCount: Int get() = pending.size
    val outstandingCount: Int get() = pending.size + taken.size
}
