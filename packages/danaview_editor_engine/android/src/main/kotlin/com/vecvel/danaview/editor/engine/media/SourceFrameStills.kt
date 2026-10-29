// OWNER: AND-06 (held source frames: android-r9)
//
// Stills of exact source frames for Media3Composition's held MEDIA items (CompositionMapper: a
// layer whose map runs past its source end holds the last source frame, as live playback does,
// ARCH §11.5). The frame is extracted the way FreezeFrameJob extracts a freeze still (ExactFrames:
// the rule frame, FrameExtractor EXACT, verified, software-decoder retry; upright and SDR) and
// written once as PNG under [dir] (a name derived from the source URI and the frame PTS, through a
// temporary file and an atomic rename), so the export's portrait retry and later render passes of
// the same source reuse it. Blocking; never call on the main thread. Never logs URIs or paths.

package com.vecvel.danaview.editor.engine.media

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import com.vecvel.danaview.editor.engine.composition.Media3Composition
import com.vecvel.danaview.editor.engine.core.EngineContext
import com.vecvel.danaview.editor.engine.core.EngineErrorCode
import com.vecvel.danaview.editor.engine.core.EngineException
import java.io.File
import java.io.IOException
import java.security.MessageDigest

/** PNG stills of exact source frames under [dir] (file header). */
class SourceFrameStills(private val context: Context, private val dir: File) : Media3Composition.FrameStills {
    override fun still(uri: String, ptsUs: Long): String {
        val file = File(dir, nameOf(uri, ptsUs))
        synchronized(LOCK) {
            if (!file.isFile) write(uri, ptsUs, file)
        }
        return "file://" + file.absolutePath
    }

    private fun write(uri: String, ptsUs: Long, file: File) {
        if (!dir.isDirectory && !dir.mkdirs() && !dir.isDirectory) throw EngineException(EngineErrorCode.io, "cannot create the held-frame directory")
        val frame = ExactFrames.extract(context, uri, ptsUs, emptyList())
        val bitmap = frame.bitmap
        try {
            val tmp = File.createTempFile(file.name, ".tmp", dir)
            try {
                tmp.outputStream().use { if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) throw IOException("PNG encoding failed") }
                if (!tmp.renameTo(file) && !file.isFile) throw IOException("cannot move the held frame into place")
            } finally {
                tmp.delete()
            }
            Log.i(EngineContext.TAG, "held source frame still written: ${bitmap.width}x${bitmap.height}")
        } catch (e: IOException) {
            throw EngineException(EngineErrorCode.io, "cannot write a held source frame", retryable = true, cause = e)
        } finally {
            bitmap.recycle()
        }
    }

    companion object {
        /** Directory of the stills under the engine's generated-assets directory (`Paths.engineAssets`). */
        const val DIR = "held"

        /** File name of the still of [uri] at [ptsUs]: `dv_held_<sha-256 prefix>_<pts>.png`. */
        fun nameOf(uri: String, ptsUs: Long): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(uri.toByteArray(Charsets.UTF_8))
            val hex = digest.take(12).joinToString("") { "%02x".format(it) }
            return "dv_held_${hex}_$ptsUs.png"
        }

        /** One writer per process: export and render previews share the directory. */
        private val LOCK = Any()
    }
}
