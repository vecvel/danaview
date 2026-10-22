// OWNER: HOM-20A
//
// The pure, Flutter-free and Android-free helpers of the Android import pickers (ARCH v1.2 §5.6,
// V2-116, rule 27; BUILD_PLAN HOM-20A), JVM-tested (src/test/.../pickers/): the picker's media
// filter and selection limit, the SAF document type list, display-name fallbacks, the copy
// registry (busy ids, cancel flags) and the streamed, resumable copy into the import's part file
// (the same contract as HOM-20's PickerCore.streamCopy on Apple: truncate the destination to the
// resume offset, append, fsync before every progress report so each report is a durable
// checkpoint, at most 4 reports a second). Nothing here logs (rule 30) or opens a socket (rule 21).

package com.vecvel.danaview.library.pickers

import com.vecvel.danaview.library.glue.LibraryErrorCode
import com.vecvel.danaview.library.pigeon.PhotoMediaFilterMsg
import java.io.EOFException
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.RandomAccessFile
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/** A typed picker failure: [code] becomes the Pigeon error code, [message] has no names or paths. */
class PickerFailure(val code: LibraryErrorCode, message: String) : Exception(message) {
    companion object {
        fun notFound(m: String) = PickerFailure(LibraryErrorCode.notFound, m)
        fun cancelled(m: String = "copy cancelled") = PickerFailure(LibraryErrorCode.cancelled, m)
        fun io(m: String) = PickerFailure(LibraryErrorCode.ioError, m)
        fun invalid(m: String) = PickerFailure(LibraryErrorCode.invalidArgument, m)
        fun busy(m: String) = PickerFailure(LibraryErrorCode.busy, m)
        fun permission(m: String) = PickerFailure(LibraryErrorCode.permissionDenied, m)
    }
}

/** Which media the photo picker shows (androidx PickVisualMedia's ImageAndVideo / ImageOnly / VideoOnly). */
enum class VisualKind { IMAGE_AND_VIDEO, IMAGE_ONLY, VIDEO_ONLY }

object PickerRequests {
    fun visualKind(filter: PhotoMediaFilterMsg): VisualKind = when (filter) {
        PhotoMediaFilterMsg.ALL -> VisualKind.IMAGE_AND_VIDEO
        PhotoMediaFilterMsg.PHOTOS -> VisualKind.IMAGE_ONLY
        PhotoMediaFilterMsg.VIDEOS -> VisualKind.VIDEO_ONLY
    }

    /** The MIME types of the document fallback for [kind] (ACTION_OPEN_DOCUMENT). */
    fun visualMimeTypes(kind: VisualKind): List<String> = when (kind) {
        VisualKind.IMAGE_AND_VIDEO -> listOf("image/*", "video/*")
        VisualKind.IMAGE_ONLY -> listOf("image/*")
        VisualKind.VIDEO_ONLY -> listOf("video/*")
    }

    /**
     * How many items the photo picker may return for a [limit] (0: no limit) given the system
     * picker's own maximum ([systemMax], null without a system picker): 1 means single selection.
     */
    fun maxItems(limit: Long, systemMax: Int?): Int {
        val cap = systemMax ?: Int.MAX_VALUE
        if (limit == 1L) return 1
        val wanted = if (limit <= 0L || limit > Int.MAX_VALUE) Int.MAX_VALUE else limit.toInt()
        return maxOf(2, minOf(wanted, cap))
    }

    /** [items] cut to [limit] (0: all): fallback pickers can't enforce a limit themselves. */
    fun <T> limited(items: List<T>, limit: Long): List<T> = if (limit > 0 && items.size > limit) items.take(limit.toInt()) else items

    /**
     * The ACTION_OPEN_DOCUMENT `type` and EXTRA_MIME_TYPES for [mimeTypes] (empty: any type). One
     * type goes in `type`; several go in the extra with `* / *` as the type.
     */
    fun documentTypes(mimeTypes: List<String>): Pair<String, Array<String>?> {
        val clean = mimeTypes.map { it.trim().lowercase() }.filter { it.isNotEmpty() && it.contains('/') }.distinct()
        return when (clean.size) {
            0 -> "*/*" to null
            1 -> clean[0] to null
            else -> "*/*" to clean.toTypedArray()
        }
    }

    /**
     * A display name for a picked item: the provider's [reported] name, else the URI's last
     * segment, else "Imported item"; given the extension of [extension] (from the MIME type) when
     * the name has none.
     */
    fun displayName(reported: String?, lastSegment: String?, extension: String?): String {
        val base = reported?.trim()?.takeIf { it.isNotEmpty() }
            ?: lastSegment?.substringAfterLast('/')?.substringAfterLast(':')?.trim()?.takeIf { it.isNotEmpty() }
            ?: "Imported item"
        val safe = base.replace('/', '_').replace('\\', '_').replace("\u0000", "")
        val hasExt = safe.substringAfterLast('.', "").let { it.isNotEmpty() && it.length <= 10 && safe.lastIndexOf('.') > 0 }
        return if (!hasExt && !extension.isNullOrEmpty()) "$safe.$extension" else safe
    }
}

/** Running copies by request id: start (busy when the id runs), cancel flags, finish. Thread-safe. */
class CopyRegistry {
    private val running = ConcurrentHashMap<String, AtomicBoolean>()

    /** Registers [id]; false when a copy with this id is already running. */
    fun start(id: String): Boolean = running.putIfAbsent(id, AtomicBoolean(false)) == null

    /** Flags [id] as cancelled; false for an unknown id. */
    fun cancel(id: String): Boolean = running[id]?.let { it.set(true); true } ?: false

    fun isCancelled(id: String): Boolean = running[id]?.get() ?: false

    fun finish(id: String) {
        running.remove(id)
    }

    fun cancelAll() = running.values.forEach { it.set(true) }
}

/** The streamed, resumable copy (see the file header). */
object StreamCopy {
    const val CHUNK_BYTES = 1 shl 20
    const val PROGRESS_EVERY_BYTES = 4L shl 20
    const val PROGRESS_MIN_INTERVAL_MS = 250L

    /**
     * The offset a copy actually resumes from: [resumeFrom] clamped to the bytes the destination
     * has ([have]), and 0 when that is past a known source size ([total]).
     */
    fun effectiveOffset(resumeFrom: Long, have: Long, total: Long?): Long {
        var offset = minOf(resumeFrom, maxOf(have, 0))
        if (total != null && offset > total) offset = 0
        return maxOf(offset, 0)
    }

    /** Skips exactly [n] bytes of [input] (EOFException when it ends first). */
    fun skipFully(input: InputStream, n: Long) {
        var left = n
        val scratch = ByteArray(64 * 1024)
        while (left > 0) {
            val skipped = input.skip(left)
            if (skipped > 0) {
                left -= skipped
                continue
            }
            val read = input.read(scratch, 0, minOf(scratch.size.toLong(), left).toInt())
            if (read < 0) throw EOFException("source ended before the resume offset")
            left -= read
        }
    }

    /**
     * Copies [input] (positioned at its start, opened read-only by the caller) into [destination]
     * from [resumeFrom]; [total] is the source size when known. Calls [progress] with the bytes in
     * the destination (fsynced first) and [total]. Returns (bytes in the destination, total or that).
     */
    fun copy(
        input: InputStream,
        destination: File,
        resumeFrom: Long,
        total: Long?,
        isCancelled: () -> Boolean,
        progress: (Long, Long?) -> Unit,
        chunkBytes: Int = CHUNK_BYTES,
        progressEvery: Long = PROGRESS_EVERY_BYTES,
        minIntervalMs: Long = PROGRESS_MIN_INTERVAL_MS,
        clock: () -> Long = System::currentTimeMillis,
    ): Pair<Long, Long> {
        if (resumeFrom < 0) throw PickerFailure.invalid("negative offset")
        val parent = destination.absoluteFile.parentFile
        if (parent == null || !parent.isDirectory) throw PickerFailure.io("destination directory missing")
        val have = if (destination.isFile) destination.length() else 0L
        val offset = effectiveOffset(resumeFrom, have, total)
        val out = try {
            RandomAccessFile(destination, "rw")
        } catch (e: IOException) {
            throw PickerFailure.io("destination can't be opened")
        }
        out.use { raf ->
            try {
                raf.setLength(offset)
                raf.seek(offset)
            } catch (e: IOException) {
                throw PickerFailure.io("destination can't be truncated")
            }
            try {
                skipFully(input, offset)
            } catch (e: IOException) {
                throw PickerFailure.io("source seek failed")
            }
            var copied = offset
            var sinceProgress = 0L
            var lastReport = clock()
            val buffer = ByteArray(chunkBytes)
            while (true) {
                if (isCancelled()) throw PickerFailure.cancelled()
                val n = try {
                    input.read(buffer)
                } catch (e: IOException) {
                    throw PickerFailure.io("source read failed")
                }
                if (n < 0) break
                if (n == 0) continue
                try {
                    raf.write(buffer, 0, n)
                } catch (e: IOException) {
                    throw PickerFailure.io("destination write failed")
                }
                copied += n
                sinceProgress += n
                val now = clock()
                if (sinceProgress >= progressEvery && now - lastReport >= minIntervalMs) {
                    sinceProgress = 0
                    lastReport = now
                    sync(raf)
                    progress(copied, total)
                }
            }
            sync(raf)
            progress(copied, total)
            return copied to (total ?: copied)
        }
    }

    private fun sync(raf: RandomAccessFile) {
        try {
            raf.fd.sync()
        } catch (e: IOException) {
            throw PickerFailure.io("destination sync failed")
        }
    }
}
