// OWNER: AND-14
//
// URI grants and media access (ARCH §9.1, §9.2, §15 Media access; BUILD_PLAN AND-14). Called on
// danaview-io. Read-only: originals are never written, moved or deleted.
//
// - persistUriGrant: ContentResolver.takePersistableUriPermission(READ). Idempotent for a URI that
//   is already persisted. A URI that cannot be persisted (no persistable grant, e.g. a FileProvider
//   or a one-shot share URI) or an exhausted budget fails with `permissionDenied`; Dart then makes a
//   managed copy (ImportPolicy, ARCH §9.1).
// - releaseUriGrant: releasePersistableUriPermission(READ); releasing a grant that is not held
//   succeeds (garbage collection may run twice).
// - remainingGrantBudget: the system's per-app cap of persisted grants (512 on API 30+, 128 before)
//   minus persistedUriPermissions.size, never negative.
// - stat: `file://` or absolute path → File length / lastModified; `content://` → OpenableColumns.SIZE
//   plus Document.COLUMN_LAST_MODIFIED (ms) or MediaColumns.DATE_MODIFIED (s), the size falling back
//   to the descriptor's length. null when the item is gone; `permissionDenied` when access was
//   revoked (Dart: accessLost).
// - quickHash: the core algorithm (packages/danaview_editor_core fingerprint.dart computeQuickHash,
//   byte-identical to danaview_data's MediaIdentityService): sha1(head + tail + utf8(":<size>")),
//   head = the first min(size, 64 KiB) bytes, tail = the last 64 KiB only when size > 64 KiB, hex
//   lower case; an empty file hashes to "". Seekable descriptors read only head and tail; a pipe
//   (non-seekable provider) is streamed once keeping the last 64 KiB.

package com.vecvel.danaview.editor.engine.platform

import android.content.ContentResolver
import android.content.Intent
import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import com.vecvel.danaview.editor.engine.core.Completion
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import com.vecvel.danaview.editor.engine.core.fail
import com.vecvel.danaview.editor.engine.core.succeed
import com.vecvel.danaview.editor.engine.media.MediaSources
import com.vecvel.danaview.editor.engine.pigeon.MediaRefMsg
import com.vecvel.danaview.editor.engine.pigeon.MediaStatMsg
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.security.MessageDigest

/** URI grants and media access (ARCH §9, §15; AND-14). Called on danaview-io. */
class MediaAccess(private val ctx: EngineContext) {
    private val resolver: ContentResolver get() = ctx.appContext.contentResolver

    /** Persists read access to the content [uri]. */
    fun persistUriGrant(uri: String, done: Completion<Unit>) = run(done) {
        val parsed = Uri.parse(uri)
        if (resolver.persistedUriPermissions.any { it.uri == parsed && it.isReadPermission }) return@run
        if (remainingBudget() <= 0) throw EngineException(EngineErrorCode.permissionDenied, "persisted grant budget exhausted")
        try {
            resolver.takePersistableUriPermission(parsed, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (e: SecurityException) {
            throw EngineException(EngineErrorCode.permissionDenied, "grant not persistable", cause = e)
        }
    }

    /** Releases a persisted grant of [uri]. */
    fun releaseUriGrant(uri: String, done: Completion<Unit>) = run(done) {
        try {
            resolver.releasePersistableUriPermission(Uri.parse(uri), Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: SecurityException) {
            // Not held (already released, or never persisted): nothing to do.
        }
    }

    /** Persisted grants still available. */
    fun remainingGrantBudget(done: Completion<Long>) = run(done) { remainingBudget().toLong() }

    /** Size and modification time; null when missing, `permissionDenied` when access was lost. */
    fun stat(media: MediaRefMsg, done: Completion<MediaStatMsg?>) = run(done) { statOf(media.uri) }

    /** quickHash of the media (the fingerprint of ARCH §9). */
    fun quickHash(media: MediaRefMsg, done: Completion<String>) = run(done) { hashOf(media.uri) }

    // ---- implementation (synchronous; also used by tests) ----

    /** The persisted-grant cap of this OS version (ARCH §15). */
    internal val grantLimit: Int get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) 512 else 128

    internal fun remainingBudget(): Int = (grantLimit - resolver.persistedUriPermissions.size).coerceAtLeast(0)

    internal fun statOf(uri: String): MediaStatMsg? {
        val file = MediaSources.localFile(uri)
        if (file != null) {
            if (!file.exists()) return null
            if (!file.canRead()) throw EngineException(EngineErrorCode.permissionDenied, "file not readable")
            return MediaStatMsg(sizeBytes = file.length(), modifiedMs = file.lastModified().takeIf { it > 0 })
        }
        val parsed = Uri.parse(uri)
        var size: Long? = null
        var modified: Long? = null
        try {
            resolver.query(parsed, null, null, null, null)?.use { c ->
                if (!c.moveToFirst()) return null
                size = c.longOrNull(OpenableColumns.SIZE)?.takeIf { it >= 0 }
                modified = c.longOrNull(DocumentsContract.Document.COLUMN_LAST_MODIFIED)?.takeIf { it > 0 }
                    ?: c.longOrNull(MediaStore.MediaColumns.DATE_MODIFIED)?.takeIf { it > 0 }?.let { it * 1000 }
            }
        } catch (e: SecurityException) {
            throw EngineException(EngineErrorCode.permissionDenied, "access revoked", cause = e)
        } catch (e: IllegalArgumentException) {
            // Unknown or removed document: decided by opening it below.
        } catch (e: UnsupportedOperationException) {
            // A provider without query support: size from the descriptor below.
        }
        if (size == null) {
            size = try {
                lengthOf(parsed) ?: return null
            } catch (e: FileNotFoundException) {
                return null
            }
        }
        return MediaStatMsg(sizeBytes = size!!, modifiedMs = modified)
    }

    internal fun hashOf(uri: String): String {
        val file = MediaSources.localFile(uri)
        if (file != null) {
            if (!file.isFile) throw EngineException(EngineErrorCode.mediaOffline, "file not found")
            return try {
                RandomAccessFile(file, "r").use { raf -> hashSeekable(raf.channel) }
            } catch (e: FileNotFoundException) {
                throw EngineException(EngineErrorCode.permissionDenied, "file not readable", cause = e)
            }
        }
        openDescriptor(Uri.parse(uri)).use { afd ->
            // Not closed on its own: the descriptor belongs to afd, which closes it.
            val input = FileInputStream(afd.fileDescriptor)
            val channel = input.channel
            val seekable = try {
                channel.position(afd.startOffset)
                true
            } catch (_: IOException) {
                false
            }
            if (seekable) {
                val total = channel.size()
                val length = if (afd.declaredLength >= 0) afd.declaredLength else total - afd.startOffset
                if (length >= 0 && afd.startOffset + length <= total) return hashSeekable(channel, afd.startOffset, length)
                channel.position(afd.startOffset)
            }
            // A pipe (or a provider that misreports sizes): read it once.
            return hashStream(input)
        }
    }

    private fun openDescriptor(uri: Uri): AssetFileDescriptor = try {
        resolver.openAssetFileDescriptor(uri, "r") ?: throw EngineException(EngineErrorCode.mediaOffline, "content not available")
    } catch (e: FileNotFoundException) {
        throw EngineException(EngineErrorCode.mediaOffline, "content not found", cause = e)
    } catch (e: SecurityException) {
        throw EngineException(EngineErrorCode.permissionDenied, "access revoked", cause = e)
    } catch (e: IllegalArgumentException) {
        throw EngineException(EngineErrorCode.mediaOffline, "content not found", cause = e)
    }

    /** The length of [uri] from its descriptor, counting the bytes when the provider does not know it. */
    private fun lengthOf(uri: Uri): Long? {
        val afd = try {
            resolver.openAssetFileDescriptor(uri, "r") ?: return null
        } catch (e: SecurityException) {
            throw EngineException(EngineErrorCode.permissionDenied, "access revoked", cause = e)
        } catch (e: IllegalArgumentException) {
            return null
        }
        afd.use {
            if (it.length != AssetFileDescriptor.UNKNOWN_LENGTH) return it.length
            return it.createInputStream().use { input ->
                val buffer = ByteArray(BUFFER)
                var total = 0L
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    total += n
                }
                total
            }
        }
    }

    private fun <T> run(done: Completion<T>, block: () -> T) {
        val value = try {
            block()
        } catch (e: Throwable) {
            return done.fail(e)
        }
        done.succeed(value)
    }

    companion object {
        /** Bytes hashed from each end (core quickHashChunkBytes). */
        const val CHUNK = 64 * 1024
        private const val BUFFER = 256 * 1024

        /** quickHash of a seekable channel (reads at most 128 KiB). */
        internal fun hashSeekable(channel: FileChannel, offset: Long = 0, length: Long = channel.size() - offset): String {
            val size = length
            if (size == 0L) return ""
            val head = readAt(channel, offset, minOf(size, CHUNK.toLong()).toInt())
            val tail = if (size > CHUNK) readAt(channel, offset + size - CHUNK, CHUNK) else ByteArray(0)
            return digest(head, tail, size)
        }

        /** quickHash of a stream read once (keeps the first and the last 64 KiB). */
        internal fun hashStream(input: InputStream): String {
            val head = ByteArray(CHUNK)
            var headLen = 0
            val ring = ByteArray(CHUNK)
            var ringPos = 0
            var total = 0L
            val buffer = ByteArray(BUFFER)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                var i = 0
                if (headLen < CHUNK) {
                    val take = minOf(CHUNK - headLen, n)
                    System.arraycopy(buffer, 0, head, headLen, take)
                    headLen += take
                }
                // Ring of the last CHUNK bytes.
                if (n >= CHUNK) {
                    System.arraycopy(buffer, n - CHUNK, ring, 0, CHUNK)
                    ringPos = 0
                } else {
                    while (i < n) {
                        val take = minOf(CHUNK - ringPos, n - i)
                        System.arraycopy(buffer, i, ring, ringPos, take)
                        ringPos = (ringPos + take) % CHUNK
                        i += take
                    }
                }
                total += n
            }
            if (total == 0L) return ""
            val tail = if (total > CHUNK) {
                ByteArray(CHUNK).also { out ->
                    System.arraycopy(ring, ringPos, out, 0, CHUNK - ringPos)
                    System.arraycopy(ring, 0, out, CHUNK - ringPos, ringPos)
                }
            } else {
                ByteArray(0)
            }
            return digest(head.copyOf(headLen), tail, total)
        }

        private fun digest(head: ByteArray, tail: ByteArray, size: Long): String {
            val sha1 = MessageDigest.getInstance("SHA-1")
            sha1.update(head)
            sha1.update(tail)
            sha1.update(":$size".toByteArray(Charsets.UTF_8))
            return sha1.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
        }

        private fun readAt(channel: FileChannel, position: Long, count: Int): ByteArray {
            val buffer = ByteBuffer.allocate(count)
            var pos = position
            while (buffer.hasRemaining()) {
                val n = channel.read(buffer, pos)
                if (n < 0) throw IOException("unexpected end of file")
                pos += n
            }
            return buffer.array()
        }

        private fun Cursor.longOrNull(column: String): Long? {
            val i = getColumnIndex(column)
            if (i < 0 || isNull(i)) return null
            return try {
                getLong(i)
            } catch (_: RuntimeException) {
                null
            }
        }
    }
}
