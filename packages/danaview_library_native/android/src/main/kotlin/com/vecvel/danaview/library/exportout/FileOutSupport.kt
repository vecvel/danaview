// OWNER: HOM-22A
//
// The Flutter-free and Android-free core of getting files out on Android (ARCH v1.2 §8 "Getting
// files out", rule 26, V2-117, V2-118; BUILD_PLAN HOM-22A; the owner-approved answers 9-11 of
// a5c4c4d), shared by exportout/, share/ and openin/ and JVM-tested:
//
// * OutFailure and OutFile: the failures (codes are LibraryErrorCode names) and one file handed out.
// * FileOut: safe names (as HOM-22's FileOutCore.swift), "Name (2).ext" numbering, photo / video /
//   other by MIME type then extension, the MIME type of a file, the share intent's common type and
//   the MediaStore folder of each save-out destination.
// * TempCopyStore: share and "Open in another app" never hand out a library file. Each request
//   gets its own batch directory `<cacheDir>/danaview-out/<UUID>/` holding create-new copies named
//   as the receiver should see them (clashes "Name (2).ext"), made read-only; a batch that fails
//   half-way is removed. Batches are NOT removed when the reply comes (Android has no reliable
//   "receiver finished" signal): batches older than 24 h are swept when the plugin starts and
//   before each new batch. Only this directory is served by the plugin's FileProvider
//   (res/xml/library_file_paths.xml), never the library.
//
// Sources are only read. Nothing here logs; failure messages carry no names or paths (rule 30).

package com.vecvel.danaview.library.exportout

import com.vecvel.danaview.library.glue.LibraryErrorCode
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID

/** A typed file-out failure: [code] becomes the Pigeon error code, [message] has no names or paths. */
class OutFailure(val code: LibraryErrorCode, message: String) : Exception(message) {
    companion object {
        fun notFound(m: String) = OutFailure(LibraryErrorCode.notFound, m)
        fun io(m: String) = OutFailure(LibraryErrorCode.ioError, m)
        fun invalid(m: String) = OutFailure(LibraryErrorCode.invalidArgument, m)
        fun busy(m: String) = OutFailure(LibraryErrorCode.busy, m)
        fun denied(m: String) = OutFailure(LibraryErrorCode.permissionDenied, m)
        fun unsupported(m: String) = OutFailure(LibraryErrorCode.notSupportedOnDevice, m)
    }
}

/** One app file handed out: an absolute [path] shown to the receiver as [displayName]. */
data class OutFile(val path: String, val displayName: String, val mimeType: String?)

/** What a file is, for Save to Photos. */
enum class OutMediaKind { PHOTO, VIDEO, OTHER }

object FileOut {
    private val imageExt = mapOf(
        "jpg" to "image/jpeg", "jpeg" to "image/jpeg", "png" to "image/png", "heic" to "image/heic", "heif" to "image/heif",
        "gif" to "image/gif", "webp" to "image/webp", "bmp" to "image/bmp", "avif" to "image/avif", "dng" to "image/x-adobe-dng",
        "tif" to "image/tiff", "tiff" to "image/tiff",
    )
    private val videoExt = mapOf(
        "mp4" to "video/mp4", "m4v" to "video/x-m4v", "mov" to "video/quicktime", "3gp" to "video/3gpp", "webm" to "video/webm",
        "mkv" to "video/x-matroska", "avi" to "video/x-msvideo", "ts" to "video/mp2t", "mts" to "video/mp2t", "m2ts" to "video/mp2t",
    )
    private val otherExt = mapOf(
        "pdf" to "application/pdf", "txt" to "text/plain", "zip" to "application/zip", "mp3" to "audio/mpeg", "m4a" to "audio/mp4",
        "wav" to "audio/wav", "json" to "application/json", "csv" to "text/csv", "srt" to "application/x-subrip",
    )

    /** [name] safe as one path component (separators and control characters -> `_`, no leading dots, <= 255 UTF-8 bytes keeping the extension). */
    fun safeName(name: String, fallback: String = "file"): String {
        val sb = StringBuilder()
        for (ch in name) sb.append(if (ch == '/' || ch == '\\' || ch == ':' || ch.isISOControl()) '_' else ch)
        var cleaned = sb.toString().trimStart('.').trim()
        if (cleaned.isEmpty()) return fallback
        if (cleaned.toByteArray(Charsets.UTF_8).size <= 255) return cleaned
        val dot = cleaned.lastIndexOf('.')
        val ext = if (dot > 0) cleaned.substring(dot) else ""
        var base = if (dot > 0) cleaned.substring(0, dot) else cleaned
        while (base.isNotEmpty() && (base + ext).toByteArray(Charsets.UTF_8).size > 255) base = base.dropLast(1)
        cleaned = base + ext
        return if (base.isEmpty()) fallback else cleaned
    }

    /** `Name.ext` for n = 1, `Name (n).ext` after. */
    fun numbered(name: String, n: Int): String {
        if (n <= 1) return name
        val dot = name.lastIndexOf('.')
        return if (dot > 0) "${name.substring(0, dot)} ($n)${name.substring(dot)}" else "$name ($n)"
    }

    /** The first numbered form of [name] that [taken] says is free (case-insensitive callers pass a lowercased set). */
    fun unique(name: String, taken: (String) -> Boolean): String {
        var n = 1
        while (true) {
            val candidate = numbered(name, n)
            if (!taken(candidate)) return candidate
            n++
            if (n > 10_000) throw OutFailure.io("no free name")
        }
    }

    private fun ext(name: String): String = name.substringAfterLast('.', "").lowercase()

    /** The MIME type of a file: the given one, else by extension, else `application/octet-stream`. */
    fun mimeType(given: String?, name: String): String =
        given?.trim()?.lowercase()?.takeIf { it.contains('/') && !it.contains('*') }
            ?: ext(name).let { imageExt[it] ?: videoExt[it] ?: otherExt[it] }
            ?: "application/octet-stream"

    /** Photo, video or neither, from the MIME type, then the extension. */
    fun mediaKind(file: OutFile): OutMediaKind {
        val m = file.mimeType?.lowercase()
        if (m != null && m.startsWith("image/")) return OutMediaKind.PHOTO
        if (m != null && m.startsWith("video/")) return OutMediaKind.VIDEO
        val e = ext(file.displayName).ifEmpty { ext(file.path) }
        return when {
            e in imageExt -> OutMediaKind.PHOTO
            e in videoExt -> OutMediaKind.VIDEO
            else -> OutMediaKind.OTHER
        }
    }

    /** The type of a share intent for [mimeTypes]: the one type, `image/*` etc. for one family, else `*/*`. */
    fun commonType(mimeTypes: List<String>): String {
        val distinct = mimeTypes.map { it.lowercase() }.distinct()
        if (distinct.size == 1) return distinct[0]
        val families = distinct.map { it.substringBefore('/') }.distinct()
        return if (families.size == 1 && families[0].isNotEmpty()) "${families[0]}/*" else "*/*"
    }

    /** The MediaStore RELATIVE_PATH a save to Downloads with [subdirectory] lands in (`Download/Danaview/`). */
    fun downloadsPath(subdirectory: String?): String {
        val parts = (subdirectory ?: "").split('/', '\\').map { safeName(it, "") }.filter { it.isNotEmpty() && it != ".." }
        return (listOf("Download") + parts).joinToString("/") + "/"
    }

    /** The MediaStore RELATIVE_PATH of Save to Photos for [kind] (`Pictures/Danaview/`, `Movies/Danaview/`). */
    fun photosPath(kind: OutMediaKind): String = if (kind == OutMediaKind.VIDEO) "Movies/Danaview/" else "Pictures/Danaview/"

    /** Checks every file is a readable regular file. */
    fun validate(files: List<OutFile>) {
        if (files.isEmpty()) throw OutFailure.invalid("no files")
        for (f in files) {
            if (f.path.isEmpty() || !File(f.path).isAbsolute) throw OutFailure.invalid("path is not absolute")
            if (f.displayName.isEmpty()) throw OutFailure.invalid("empty display name")
            val file = File(f.path)
            if (!file.isFile) throw OutFailure.notFound("no such file")
            if (!file.canRead()) throw OutFailure.denied("file not readable")
        }
    }

    /** Streams [source] into [out] (the caller's own new destination); the source is only read. */
    fun copyInto(source: File, out: java.io.OutputStream) {
        FileInputStream(source).use { input -> input.copyTo(out, 1 shl 20) }
    }
}

/** One request's read-only copies. */
data class TempBatch(val directory: File, val files: List<File>)

/** Temporary read-only copies for share and "Open in" (see the file header). */
class TempCopyStore(cacheDir: File, private val clock: () -> Long = System::currentTimeMillis) {
    /** `<cacheDir>/danaview-out/` (the FileProvider's only path). */
    val root = File(cacheDir, DIR)

    /** Copies [files] into a new batch, each under its safe, batch-unique display name, read-only. A failed batch is removed. */
    fun makeBatch(files: List<OutFile>): TempBatch {
        FileOut.validate(files)
        sweepStale()
        val dir = File(root, UUID.randomUUID().toString())
        if (!dir.mkdirs()) throw OutFailure.io("could not create the batch directory")
        try {
            val used = HashSet<String>()
            val out = ArrayList<File>()
            for (f in files) {
                val name = FileOut.unique(FileOut.safeName(f.displayName)) { it.lowercase() in used }
                used += name.lowercase()
                val dest = File(dir, name)
                if (!dest.createNewFile()) throw OutFailure.io("copy exists")
                FileOutputStream(dest).use { stream -> FileOut.copyInto(File(f.path), stream); stream.fd.sync() }
                if (!dest.setReadOnly()) throw OutFailure.io("could not make the copy read-only")
                out += dest
            }
            return TempBatch(dir, out)
        } catch (t: Throwable) {
            removeDir(dir)
            throw when (t) {
                is OutFailure -> t
                is IOException -> OutFailure.io("temporary copy failed")
                else -> t
            }
        }
    }

    /** Removes [batch] (its copies are read-only, the directory is not). */
    fun remove(batch: TempBatch) = removeDir(batch.directory)

    /** The batch directories on disk. */
    fun batches(): List<File> = root.listFiles()?.filter { it.isDirectory } ?: emptyList()

    /** Removes batches last modified more than [ageMs] ago; returns how many. */
    fun sweepStale(ageMs: Long = STALE_AGE_MS): Int {
        val now = clock()
        var n = 0
        for (dir in batches()) {
            if (now - dir.lastModified() > ageMs) {
                removeDir(dir)
                n++
            }
        }
        return n
    }

    private fun removeDir(dir: File) {
        // Read-only files must be made writable first where the platform refuses (Windows hosts).
        dir.walkBottomUp().forEach { f ->
            if (!f.delete()) {
                f.setWritable(true)
                f.delete()
            }
        }
    }

    companion object {
        const val DIR = "danaview-out"
        const val STALE_AGE_MS = 24L * 60 * 60 * 1000
    }
}
