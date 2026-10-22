// OWNER: AND-11 (QA-05 D8, Android half)
//
// Engine files that the system deleted under an export. Everything the engine writes for a running
// export lives below the Dart cache root (`<cache>/danaview/editor`: the generated images under
// `engine/`, the output and intermediates under `work/`), and Android's installd purges app caches
// when the volume runs low (QA-05 D8: at 199 MB free it removed the whole tree mid-export). The
// engine never deletes those files while a job runs, so an export that fails because one of them is
// missing (ENOENT / FileNotFoundException naming a path below the cache root, anywhere in the cause
// chain) lost them to the system. That is a storage failure, not a broken source (`mediaOffline`)
// or an unknown one: `diskFull` when the volume is low right now ([isLow]), else `io` (the files went
// for another reason, e.g. the user cleared the cache). The Pigeon/Dart codes have no "temporary
// files lost" code; `diskFull` is what Dart shows as "Not enough space to export". A missing file
// outside the cache root (the user's media) keeps ExportErrors' mapping.
//
// Messages never carry paths (ARCH §20.1).

package com.vecvel.danaview.editor.engine.export

import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineErrors
import com.vecvel.danaview.editor.engine.core.EngineException
import java.io.File
import java.io.FileNotFoundException

/** Classification of engine files lost under a job (file header). Pure (JVM-tested). */
object StorageLoss {
    /** Android's low-storage rule (DeviceStorageMonitorService defaults): 5 % of the volume, at most 500 MiB. */
    const val LOW_PERCENT = 5L
    const val LOW_MAX_BYTES = 500L * 1024 * 1024

    /** Whether [availableBytes] of a [totalBytes] volume is low by Android's rule. */
    fun isLow(availableBytes: Long, totalBytes: Long): Boolean {
        if (availableBytes < 0 || totalBytes <= 0) return false
        return availableBytes < minOf(totalBytes / 100 * LOW_PERCENT, LOW_MAX_BYTES)
    }

    /** Whether [error]'s cause chain reports a missing file below [cacheRoot]. */
    fun lostBelow(error: Throwable, cacheRoot: File): Boolean {
        val chain = generateSequence(error) { it.cause }.take(MAX_CAUSES).toList()
        // A FileNotFoundException also reports refused opens (EACCES) and full volumes (ENOSPC); those are not losses.
        if (chain.any { EngineErrors.isNoSpace(it) || EngineErrors.isPermissionDenied(it) }) return false
        val missing = chain.any { it is FileNotFoundException || it.message.orEmpty().contains("ENOENT") }
        if (!missing) return false
        val roots = rootSpellings(cacheRoot)
        return chain.any { t -> val m = t.message.orEmpty(); roots.any { r -> names(m, r) } }
    }

    /** The failure of an export that lost engine files: `diskFull` when [low], else `io`. */
    fun failure(low: Boolean, cause: Throwable? = null): EngineException =
        if (low) {
            EngineException(EngineErrorCode.diskFull, "not enough space: the system removed the export's temporary files", retryable = true, cause = cause)
        } else {
            EngineException(EngineErrorCode.io, "the export's temporary files were removed", retryable = true, cause = cause)
        }

    /**
     * The storage failure for [error] when it lost files below [cacheRoot] ([low] is asked only
     * then), or null. Cancellation, interruption and an already-classified `diskFull` stay as they are.
     */
    fun classify(error: Throwable, cacheRoot: File, low: () -> Boolean): EngineException? {
        if (error is EngineException && error.code in KEPT) return null
        if (!lostBelow(error, cacheRoot)) return null
        return failure(low(), error)
    }

    private val KEPT = setOf(EngineErrorCode.cancelled, EngineErrorCode.interrupted, EngineErrorCode.diskFull)

    private const val MAX_CAUSES = 16

    private fun rootSpellings(root: File): List<String> {
        val out = linkedSetOf(root.path.trimEnd('/', '\\'), root.invariantSeparatorsPath.trimEnd('/'))
        try {
            out += root.canonicalFile.path.trimEnd('/', '\\')
        } catch (_: java.io.IOException) {
        } catch (_: SecurityException) {
        }
        return out.filter { it.isNotEmpty() }
    }

    /** Whether [message] names a path below [root] (the root followed by a separator). */
    private fun names(message: String, root: String): Boolean {
        var i = message.indexOf(root)
        while (i >= 0) {
            val next = message.getOrNull(i + root.length)
            if (next == '/' || next == '\\') return true
            i = message.indexOf(root, i + 1)
        }
        return false
    }
}
