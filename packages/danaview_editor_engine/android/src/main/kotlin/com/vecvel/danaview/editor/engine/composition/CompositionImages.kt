// OWNER: AND-08 (regeneration: QA-05 D8, Android half)
//
// The generated images a composition needs (ARCH §13.3 "Sequence stack"): the 2×2 transparent
// clock band, canvas-size transparent gap fills (AND-01 V-N18/V-N25: never `addGap`), the
// canvas-size opaque background and the white source of solid layers. They are written once per
// size/colour as PNG into the engine's generated-assets directory (`Paths.engineAssets`, under the
// Dart cache root) and referenced by `file://` URI.
//
// The cache root is the system's to purge: under storage pressure installd deletes app caches,
// mid-export included (QA-05 D8, op #75: `engine/dv_opaque_*.png` and `dv_transparent_*.png` gone
// five seconds before the image asset loader opened one). A generated image's name carries
// everything needed to draw it again ([Generated]), so a missing one is never an error:
// [PngCompositionImages.png] rewrites it whenever a composition is built, and the image asset loader
// of every Transformer run over a composition (GeneratedImageAssetLoaderFactory) rewrites it when it
// is opened, or, when it cannot be written (no space), hands Media3 the same pixels from memory.

package com.vecvel.danaview.editor.engine.composition

import android.graphics.Bitmap
import android.util.Log
import androidx.core.graphics.createBitmap
import com.vecvel.danaview.editor.engine.core.EngineContext
import java.io.File
import java.io.IOException

/** URIs of generated images (file header). */
interface CompositionImages {
    /** A fully transparent [w] × [h] image. */
    fun transparent(w: Int, h: Int): String

    /** An opaque [w] × [h] image of [argb] (alpha forced to FF). */
    fun opaque(argb: Int, w: Int, h: Int): String

    companion object {
        /** Clock band edge (ARCH: one 2×2 transparent image item). */
        const val CLOCK_BAND_SIZE = 2

        /** Edge of the white source of solid layers (scaled to `base` by LayerPlaceEffect). */
        const val SOLID_SOURCE_SIZE = 16
    }
}

/**
 * One generated image as its file name describes it: `dv_transparent_<w>x<h>.png` (colour 0) or
 * `dv_opaque_<argb hex>_<w>x<h>.png` (alpha FF). Pure (JVM-tested).
 */
data class Generated(val name: String, val w: Int, val h: Int, val color: Int) {
    companion object {
        private val transparentName = Regex("""dv_transparent_(\d{1,5})x(\d{1,5})\.png""")
        private val opaqueName = Regex("""dv_opaque_(ff[0-9a-f]{6})_(\d{1,5})x(\d{1,5})\.png""")

        /** The name of a transparent [w] × [h] image. */
        fun transparentName(w: Int, h: Int): String = "dv_transparent_${w}x$h.png"

        /** The name of an opaque [w] × [h] image of [color] (alpha already FF). */
        fun opaqueName(color: Int, w: Int, h: Int): String = "dv_opaque_${Integer.toHexString(color)}_${w}x$h.png"

        /** The image [name] describes, or null when it is not a generated image's name. */
        fun parse(name: String): Generated? {
            transparentName.matchEntire(name)?.let { m ->
                val (w, h) = m.destructured
                return of(name, w, h, 0)
            }
            opaqueName.matchEntire(name)?.let { m ->
                val (hex, w, h) = m.destructured
                return of(name, w, h, hex.toLong(16).toInt())
            }
            return null
        }

        private fun of(name: String, w: String, h: String, color: Int): Generated? {
            val width = w.toInt()
            val height = h.toInt()
            if (width <= 0 || height <= 0 || width > MAX_EDGE || height > MAX_EDGE) return null
            return Generated(name, width, height, color)
        }

        /** Largest edge a generated image may have (canvas sizes stay far below it). */
        const val MAX_EDGE = 16_384
    }
}

/** [CompositionImages] writing PNGs into [dir] (created on demand; atomic rename; file header). */
class PngCompositionImages(private val dir: File) : CompositionImages {
    override fun transparent(w: Int, h: Int): String = png(Generated(Generated.transparentName(w, h), w, h, 0))

    override fun opaque(argb: Int, w: Int, h: Int): String {
        val color = argb or 0xFF000000.toInt()
        return png(Generated(Generated.opaqueName(color, w, h), w, h, color))
    }

    /**
     * The generated image [uri] names: a `file://` URI of a file directly in this directory whose
     * name [Generated.parse] accepts, in the form [png] returns (`file://` + absolute path). Null for
     * anything else (user media, other directories).
     */
    fun generated(uri: String?): Generated? {
        if (uri == null || !uri.startsWith(FILE_SCHEME)) return null
        val file = File(uri.removePrefix(FILE_SCHEME))
        val parent = file.parentFile ?: return null
        if (parent.invariantSeparatorsPath.trimEnd('/') != dir.invariantSeparatorsPath.trimEnd('/')) return null
        return Generated.parse(file.name)
    }

    /** The file of [g] in this directory. */
    fun fileOf(g: Generated): File = File(dir, g.name)

    /**
     * Writes [g] again when its file is missing (the system purged the cache). Returns whether the
     * file is there afterwards; a failed write (no space, the directory cannot be created) is logged
     * and answered false, never thrown.
     */
    fun restore(g: Generated): Boolean {
        if (fileOf(g).isFile) return true
        return try {
            write(g)
            Log.i(EngineContext.TAG, "generated image ${g.w}x${g.h} was missing; written again")
            true
        } catch (e: IOException) {
            Log.w(EngineContext.TAG, "generated image ${g.w}x${g.h} is missing and cannot be written (${e.javaClass.simpleName})")
            false
        } catch (e: IllegalStateException) {
            Log.w(EngineContext.TAG, "generated image ${g.w}x${g.h} is missing and cannot be written (${e.javaClass.simpleName})")
            false
        }
    }

    /** The pixels of [g] (ARGB_8888, the same values its PNG decodes to). The caller owns the bitmap. */
    fun bitmap(g: Generated): Bitmap {
        val bmp = createBitmap(g.w, g.h, Bitmap.Config.ARGB_8888)
        bmp.eraseColor(g.color)
        return bmp
    }

    private fun png(g: Generated): String {
        val file = fileOf(g)
        if (!file.isFile) write(g)
        return "file://" + file.absolutePath
    }

    /** Writes [g] through a unique temporary file and an atomic rename. Throws on failure. */
    private fun write(g: Generated) = synchronized(LOCK) {
        val file = fileOf(g)
        if (file.isFile) return@synchronized
        if (!dir.isDirectory && !dir.mkdirs() && !dir.isDirectory) throw IOException("cannot create the generated-images directory")
        val tmp = File.createTempFile(g.name, ".tmp", dir)
        try {
            val bmp = bitmap(g)
            try {
                tmp.outputStream().use { if (!bmp.compress(Bitmap.CompressFormat.PNG, 100, it)) throw IOException("PNG encoding failed") }
            } finally {
                bmp.recycle()
            }
            if (!tmp.renameTo(file)) check(file.isFile) { "cannot write a generated image" }
        } finally {
            tmp.delete()
        }
    }

    private companion object {
        const val FILE_SCHEME = "file://"

        /** One writer per process: several instances (export, render preview) share a directory. */
        val LOCK = Any()
    }
}
