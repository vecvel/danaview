// OWNER: ENG-08
//
// Engine roots and directories (ARCH §8.1, §15, §20.1). The engine only ever writes below the roots
// Dart hands it through `EngineHostApi.initialize` (`<cache>/danaview/editor` and
// `<support>/danaview/editor`) and the speech tree next to the editor tree (`<support>/danaview/speech`,
// where speech-audio jobs write). Nothing here is derived from Context directories: the Dart
// `StoreRoots` are the single source of truth.

package com.vecvel.danaview.editor.engine.core

import java.io.File

/**
 * The validated engine roots. Create with [fromDart]. All `File`s are absolute and normalized.
 *
 * Cache (`<cache>/danaview/editor/`): [thumbs] 300 MB, [waves] 64 MB, [proxies], [sprites], [looks],
 * [engineAssets] (generated spacer), [work] (wiped at launch with exemptions, AND-03), [workPicks],
 * [workDrops]. Support (`<support>/danaview/editor/`): [projects], [media] (managed copies), [derived]
 * (reversed renditions). Speech: [speechRoot].
 */
class Paths private constructor(val cacheRoot: File, val supportRoot: File) {
    /** `<support>/danaview/speech` (AI tree, D-20); speech-audio jobs write under it. */
    val speechRoot: File = File(supportRoot.parentFile ?: supportRoot, "speech")

    val thumbs: File get() = File(cacheRoot, "thumbs")
    val waves: File get() = File(cacheRoot, "waves")
    val proxies: File get() = File(cacheRoot, "proxies")
    val sprites: File get() = File(cacheRoot, "sprites")
    val looks: File get() = File(cacheRoot, "looks")
    val engineAssets: File get() = File(cacheRoot, "engine")
    val work: File get() = File(cacheRoot, "work")
    val workPicks: File get() = File(work, "picks")
    val workDrops: File get() = File(work, "drops")
    val projects: File get() = File(supportRoot, "projects")
    val media: File get() = File(supportRoot, "media")
    val derived: File get() = File(supportRoot, "derived")

    /** The roots the engine may write below. */
    val writableRoots: List<File> get() = listOf(cacheRoot, supportRoot, speechRoot)

    /** Whether [path] is an absolute path inside one of [writableRoots] (no `..` escapes). */
    fun isWritable(path: String): Boolean {
        val file = normalize(path) ?: return false
        return writableRoots.any { isInside(file, it) }
    }

    /** Whether [path] is inside the editor roots or the speech root (D-44 backup exclusion). */
    fun isEditorOrSpeechPath(path: String): Boolean = isWritable(path)

    /**
     * [path] as a File when it is writable, else an [EngineException] (`permissionDenied`; the
     * engine never writes outside the Dart-supplied roots, ARCH §20.1).
     */
    fun requireWritable(path: String, name: String): File {
        val file = normalize(path) ?: throw EngineErrors.invalidArgument(name, "not an absolute path")
        if (writableRoots.none { isInside(file, it) }) {
            throw EngineException(EngineErrorCode.permissionDenied, "$name is outside the engine roots")
        }
        return file
    }

    /** Creates the root directories (idempotent). Returns false when one could not be created. */
    fun ensureRoots(): Boolean = listOf(cacheRoot, supportRoot, work).all { it.isDirectory || it.mkdirs() }

    override fun equals(other: Any?): Boolean =
        other is Paths && other.cacheRoot == cacheRoot && other.supportRoot == supportRoot

    override fun hashCode(): Int = cacheRoot.hashCode() * 31 + supportRoot.hashCode()

    override fun toString(): String = "Paths(<cache root>, <support root>)"

    companion object {
        /**
         * Validates the Dart roots: both non-empty, absolute, without `..` segments, and distinct
         * (neither inside the other). Throws an [EngineException] (`internal`, a Dart bug) otherwise.
         */
        fun fromDart(cacheRoot: String, supportRoot: String): Paths {
            val cache = normalize(cacheRoot) ?: throw EngineErrors.invalidArgument("cacheRoot", "not an absolute path")
            val support = normalize(supportRoot) ?: throw EngineErrors.invalidArgument("supportRoot", "not an absolute path")
            if (isInside(cache, support) || isInside(support, cache)) {
                throw EngineErrors.invalidArgument("roots", "cacheRoot and supportRoot overlap")
            }
            return Paths(cache, support)
        }

        /** An absolute, normalized File for [path] (a plain path or a `file://` URI), or null. */
        fun normalize(path: String): File? {
            val raw = if (path.startsWith("file://")) path.removePrefix("file://") else path
            if (raw.isEmpty() || raw.indexOf('\u0000') >= 0) return null
            val unix = raw.replace('\\', '/')
            if (!unix.startsWith("/") && !File(raw).isAbsolute) return null
            val segments = unix.split('/').filter { it.isNotEmpty() && it != "." }
            if (segments.any { it == ".." }) return null
            val joined = segments.joinToString("/")
            return File(if (unix.startsWith("/")) "/$joined" else joined)
        }

        /** Whether [file] equals [root] or lies below it (component-wise, so `/a/bc` is not inside `/a/b`). */
        fun isInside(file: File, root: File): Boolean {
            val f = file.invariantSeparatorsPath.trimEnd('/')
            val r = root.invariantSeparatorsPath.trimEnd('/')
            return f == r || f.startsWith("$r/")
        }
    }
}
